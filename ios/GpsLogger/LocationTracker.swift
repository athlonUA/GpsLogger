import Foundation
import CoreLocation
import Combine
import UIKit

/// Thin wrapper around CLLocationManager.
///
/// - No timers. Points are stored purely in response to CoreLocation callbacks.
/// - Raw CLLocation samples pass through `LocationFilter` first (validity,
///   source discrimination, accuracy, speed, spike buffer — see
///   `LocationFilter.swift`), then through `KalmanSmoother` (2D constant-
///   velocity KF that averages per-sample HA noise against a motion prior),
///   then through `StationaryDetector`, which suppresses stationary-jitter
///   clusters. `LocationFilter` still owns outlier rejection; the smoother
///   only shapes accepted coordinates and never synthesizes a fix from
///   nothing.
/// - Always-on: `start()` is invoked once during container bootstrap and the
///   tracker runs for the full app lifetime. There is no user-facing Stop;
///   CoreLocation only ceases when the OS terminates the process.
/// - Device identity is owned by `SyncService` and stamped on the upload
///   payload, not on individual rows — it's a property of the install, not
///   of each fix.
/// - **Multi-modal `activityType`**: the hint passed to CoreLocation is
///   swapped at runtime from `.fitness` to `.automotiveNavigation` based on
///   `MotionClassifier`'s reading of the phone's inertial sensors. Walking
///   and cycling use `.fitness`, motorized transport (car, bus, train) uses
///   `.automotiveNavigation`, and the default on startup — before CoreMotion
///   has had time to classify — is `.fitness`. See `MotionClassifier.swift`.
/// - **Two-manager design** (1.2.11). The tracker owns two
///   `CLLocationManager` instances with strictly separated roles:
///     1. `manager` drives `startUpdatingLocation()` and is the *only*
///        path into the persist pipeline.
///     2. `wakeMonitor` is dedicated to
///        `startMonitoringSignificantLocationChanges()`. Its sole purpose
///        is to let iOS relaunch the process from a terminated state if
///        the user has stopped opening the app. Its delegate callbacks
///        are intentional no-ops — SLC is **only a wake trigger**, never
///        a tracking source.
///   The relaunch flow runs through
///   `AppContainer.bootstrap(launchedForLocation:)` → `tracker.start(launchedForLocation:)`
///   startup path; there is no second startup branch keyed on SLC.
///   By the time the wake event is delivered, the regular update
///   stream is either already running (.fullTracking) or the home-zone
///   evaluation has decided to keep us in `.deferred` (1.2.13).
/// - **Auto Wake kill switch** (1.2.12). The wake-monitor subscription
///   is **off by default**, gated behind `Config.autoWakeEnabled`
///   (UserDefaults). The hidden settings sheet — reached via 10 taps
///   on the unsynced-points counter in `ContentView` — calls
///   `setAutoWakeEnabled(_:)`, which persists the choice and runs the
///   matching `startMonitoringSignificantLocationChanges()` /
///   `stopMonitoringSignificantLocationChanges()` call so the disable
///   is a real OS-level effect, not just a UI flag. Disable is
///   re-enforced on every launch via the init-time
///   `applyAutoWakeSetting()` call, which both arms (if the user
///   previously opted in) and disarms (defensively, in case an older
///   app version left an SLC subscription registered with the OS).
///   This keeps the always-on regular tracking unchanged: opening the
///   app still starts `manager.startUpdatingLocation()` regardless of
///   the Auto Wake setting.
/// - **Home-zone unification** (1.2.13). A single mechanism — distance
///   from the persisted `Config.lastAnchor` against
///   `Config.homeZoneRadiusMeters` — answers the question "is this
///   point real movement or is the user still where I last saw them?"
///   in three places:
///
///     1. **Cold start under SLC-launch context.** When iOS launches
///        the process because of a significant-location-change event
///        (`launchedForLocation == true`) and the user has opted into
///        Auto Wake, the tracker enters `.deferred` mode instead of
///        running `startUpdatingLocation()` unconditionally. The
///        regular GPS stream stays off until the wake-monitor
///        delivers a SLC fix proving displacement greater than the
///        home-zone radius. Saves the overnight blue-pill blink
///        (and the phantom one-off points it produced) on a phone
///        that iOS re-launches several times a night because of
///        cellular tower handoffs while the user sleeps.
///     2. **Wake-monitor delegate while in `.deferred`.** A SLC fix
///        within the home zone is logged and ignored; iOS will
///        re-suspend the process. A SLC fix outside the home zone
///        promotes mode to `.fullTracking` and starts the regular
///        update stream.
///     3. **`maybePersist` pre-pipeline gate.** Even in
///        `.fullTracking`, any accepted fix landing inside the home
///        zone is suppressed before it reaches the smoother /
///        stationary detector / `points` insert. This guards
///        against the indoor-jitter phantoms documented on
///        2026-04-26 (a 19-minute LocationFilter-rejected window
///        followed by two fixes 33–44 m from the evening's last
///        accepted point — both inside the 100 m home zone). Without
///        the gate, `StationaryDetector`'s gap-reset rule treats
///        the returning fix as a fresh anchor and writes it.
///
///   The persisted anchor is updated by `persist(_:)` after every
///   successful SQLite insert, so the home zone naturally follows
///   the user across days without explicit "set my home" UI: the
///   anchor is wherever the last persisted point landed. Anchor
///   freshness is bounded by `Config.anchorMaxAgeSeconds` (24 h);
///   stale anchors short-circuit all three call sites back to the
///   pre-1.2.13 always-on behavior.
final class LocationTracker: NSObject, ObservableObject {

    /// Conditions that prevent the tracker from recording a complete
    /// trace. Surfaced through `@Published var impairments` so the UI
    /// can show a banner; the user acts on them by opening Settings.
    enum TrackingImpairment: String, Hashable, CaseIterable {
        /// Location permission denied or revoked — no fixes at all.
        /// Happens when the user declines `requestAlwaysAuthorization` or
        /// flips the app to "Never" in Settings after granting it.
        case permissionDenied
        /// Only `authorizedWhenInUse`. Foreground tracking works, but iOS
        /// silently stops delivering updates once the app is backgrounded
        /// even though `allowsBackgroundLocationUpdates = true`. The
        /// trace will have gaps. User needs to upgrade to Always.
        case backgroundRequiresAlways
        /// Motion & Fitness permission denied. `MotionClassifier` cannot
        /// classify modes; `activityType` stays on whatever hint was last
        /// applied (default `.fitness`), so vehicle fusion bias never
        /// engages. Not a data-loss condition, just a quality degradation.
        case motionPermissionDenied
        /// iOS 14+ "Precise Location" toggle is off (`accuracyAuthorization
        /// == .reducedAccuracy`). Apple reports horizontal accuracy on the
        /// 1–20 km scale in this mode, which our 50 m filter ceiling rejects
        /// unconditionally — the trace silently stays empty with no error.
        /// Surface the condition so the user can flip the toggle in
        /// Settings > Privacy > Location > GpsLogger > Precise Location.
        case reducedAccuracy
        /// "Background App Refresh" is disabled (either globally or for
        /// this app). Without it, `startMonitoringSignificantLocationChanges`
        /// cannot relaunch the app from a terminated state — the #1 cause
        /// of "nothing recorded after the app was force-quit" scenarios.
        /// Orthogonal to location permission: an Always-authorized app
        /// with BG refresh off still records in foreground and in
        /// suspended background, but loses the terminated-state recovery
        /// path entirely.
        case backgroundRefreshDenied

        /// Short user-facing blurb for the impairment banner.
        var shortMessage: String {
            switch self {
            case .permissionDenied:
                return "Location permission denied — open Settings to allow."
            case .backgroundRequiresAlways:
                return "Background tracking needs Always permission."
            case .motionPermissionDenied:
                return "Motion sensing off — vehicle mode will not engage."
            case .reducedAccuracy:
                return "Precise Location is off — fixes are too coarse to record. Enable in Settings."
            case .backgroundRefreshDenied:
                return "Background App Refresh is off — tracking can't resume after force-quit."
            }
        }

        /// Pure mapping from `CLAccuracyAuthorization` to an impairment.
        /// Extracted so the logic is unit-testable in isolation without
        /// mocking `CLLocationManager` itself.
        @available(iOS 14.0, *)
        static func impairment(for accuracy: CLAccuracyAuthorization) -> TrackingImpairment? {
            switch accuracy {
            case .fullAccuracy: return nil
            case .reducedAccuracy: return .reducedAccuracy
            @unknown default: return nil
            }
        }

        /// Pure mapping from `UIBackgroundRefreshStatus` to an impairment.
        /// `.restricted` is treated the same as `.denied` because both
        /// produce the same observable symptom — SLC-driven relaunch will
        /// not fire — and the user's recovery path (Settings) is identical.
        static func impairment(for refresh: UIBackgroundRefreshStatus) -> TrackingImpairment? {
            switch refresh {
            case .available: return nil
            case .denied, .restricted: return .backgroundRefreshDenied
            @unknown default: return .backgroundRefreshDenied
            }
        }
    }

    /// Two-state runtime classifier governing whether the regular
    /// GPS stream (`manager.startUpdatingLocation()`) is engaged.
    ///
    /// - `.fullTracking` — the regular stream is running. Fixes flow
    ///   through filter → smoother → stationary → persist. This is
    ///   the steady state during any user-initiated app launch and
    ///   any post-promotion period after a confirmed displacement.
    /// - `.deferred` — the regular stream is **not** running. Only
    ///   the wake-monitor SLC subscription is armed (assuming
    ///   `Config.autoWakeEnabled`); the process otherwise consumes
    ///   no GPS power. Reachable only via SLC-launch into a fresh
    ///   home-zone anchor (see `start(launchedForLocation:)`). Exits
    ///   on three triggers — wake-monitor SLC fix outside the home
    ///   zone, scenePhase becoming `.active` (user opened the app),
    ///   or an authorization-state change to `.authorizedAlways`
    ///   that wasn't already armed.
    ///
    /// The transition is one-way per session: once we promote to
    /// `.fullTracking`, we do not drop back to `.deferred` mid-run.
    /// (Any future "auto-suspend after long stationary" feature
    /// would need to reason about how often it can flip and what
    /// the user-visible cost of the GPS warm-up is — outside the
    /// scope of 1.2.13.)
    enum TrackingMode: String, Equatable {
        case fullTracking
        case deferred
    }

    @Published private(set) var isTracking = false
    @Published private(set) var authStatus: CLAuthorizationStatus
    @Published private(set) var motionMode: MotionClassifier.Mode = .unknown
    @Published private(set) var impairments: Set<TrackingImpairment> = []

    /// Current runtime mode. Starts at `.fullTracking` for the
    /// pre-1.2.13 always-on default; `start(launchedForLocation:)`
    /// may downgrade to `.deferred` when SLC-launched into a fresh
    /// home zone with Auto Wake enabled.
    @Published private(set) var mode: TrackingMode = .fullTracking

    /// Mirror of `Config.autoWakeEnabled` for SwiftUI bindings. Mutated
    /// only by `setAutoWakeEnabled(_:)` so the persisted UserDefaults
    /// value, the OS-level SLC subscription, and the on-screen toggle
    /// stay in lockstep. Read on the main thread (the Toggle in
    /// `AutoWakeSettingsView` reads it through a `Binding(get:set:)`
    /// pair).
    @Published private(set) var autoWakeEnabled: Bool

    private let manager = CLLocationManager()

    /// Dedicated low-power CLLocationManager for the
    /// `startMonitoringSignificantLocationChanges()` subscription. Kept
    /// separate from `manager` so SLC fixes do **not** flow through the
    /// tracking pipeline (filter → smoother → stationary → persist).
    ///
    /// As of 1.2.12 the subscription is **off by default** and only
    /// armed when the user explicitly opts into Auto Wake via the
    /// hidden settings sheet. `applyAutoWakeSetting()` is the single
    /// point that calls `start...` / `stop...` on this manager: it
    /// runs from `init()` (so an upgrade from an older version that
    /// left an OS-level subscription behind is actively disarmed),
    /// from `handleAuthorizationState(.authorizedAlways)` (re-arms
    /// after an auth grant if the user had Auto Wake on), and from
    /// `setAutoWakeEnabled(_:)` (the toggle's side effect). The OS
    /// retains SLC subscriptions across launches, so calling
    /// `stop...` here is what makes the OFF state a real
    /// system-level disable — not just a UI flag.
    ///
    /// `internal` (not `private`) so `WakeMonitorRoutingTests` can
    /// route synthetic CLLocations through this manager's delegate
    /// path and assert no persistence occurs.
    let wakeMonitor = CLLocationManager()

    private let database: Database
    private let appState: AppState

    private var filter = LocationFilter()
    private var smoother = KalmanSmoother()
    private var stationary = StationaryDetector()
    private let classifier = MotionClassifier()

    /// Consecutive-discard counter. Resets on any `.accept`,
    /// `.spikeReplaced`, or `.committedPending` decision; `.buffered` is
    /// neither accept nor reject and does not disturb the counter. Used
    /// only for observability — when the counter crosses the log
    /// threshold we print a WARN line so long rejection streaks are
    /// visible in Console.app without needing a Postgres query. The
    /// filter itself does not branch on this value.
    private var discardStreak = 0
    /// Emit a WARN every N consecutive discards. 20 at ~1 s cadence is
    /// ~20 s of sustained rejection — rare enough under normal operation
    /// to catch real deadlocks, coarse enough not to spam the log on
    /// legitimate short signal dips.
    private static let discardStreakLogThreshold = 20

    /// Private serial queue for all database writes triggered by
    /// CoreLocation callbacks. CoreLocation delivers to the main queue;
    /// `Database.insert` / `Database.logDiagnostic` go through a
    /// synchronous `sqlite3_step`. Running them on main would block UI.
    /// A private serial queue preserves insert order (important so rows
    /// arrive in the DB in the same order the fixes arrived) while
    /// decoupling from the main thread.
    private let persistQueue = DispatchQueue(
        label: "gpslogger.tracker.persist",
        qos: .utility
    )

    init(database: Database, appState: AppState) {
        self.database = database
        self.appState = appState
        self.authStatus = manager.authorizationStatus
        // Seed the published mirror from the persisted preference so a
        // returning user with Auto Wake previously enabled sees the
        // toggle pre-flipped on the next launch.
        self.autoWakeEnabled = Config.autoWakeEnabled
        super.init()

        manager.delegate = self
        // `BestForNavigation` is one step above `Best`: CoreLocation's
        // fusion engine consumes accelerometer / gyroscope / barometer
        // data more aggressively, and under partial-sky conditions
        // (urban canyon, tree canopy) the reported horizontalAccuracy
        // drops measurably — HA=32 m buckets collapse toward 10–16 m.
        // Apple's docs recommend this mode only "when navigating" or
        // "while the device is plugged in" because of the additional
        // battery draw; we run it permanently because our product goal
        // is continuous high-fidelity tracking and the user has
        // explicitly accepted the battery cost.
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        // Startup default: pedestrian hint. `MotionClassifier` will flip
        // this to `.automotiveNavigation` once it detects a motor vehicle
        // with medium/high confidence. The previous hard-coded
        // `.automotiveNavigation` was a semantic mismatch for walkers and
        // biased the fusion engine toward vehicle motion models in
        // degraded-signal environments.
        manager.activityType = .fitness
        // `kCLDistanceFilterNone` means CoreLocation delivers every
        // computed fix (~1 Hz in normal conditions) rather than only
        // those more than `minDistanceMeters` from the last delivered
        // sample. The denser stream gives the downstream `KalmanSmoother`
        // 5–7× more observations to average against, which is the main
        // lever for driving per-sample jitter below the HA ceiling.
        // The `minDistanceMeters` gate still applies inside
        // `LocationFilter` for what gets persisted, so the `points`
        // table row rate is unchanged by this flip; only the smoother's
        // input density changes.
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true

        // Wake monitor: minimum config. `desiredAccuracy`,
        // `distanceFilter`, `activityType`, and
        // `pausesLocationUpdatesAutomatically` do not influence SLC —
        // the system delivers cellular-triangulation fixes at its own
        // cadence regardless. Setting `allowsBackgroundLocationUpdates`
        // is a defensive no-op (SLC delivery does not require it, but
        // some Apple Forum reports show the property defending against
        // edge cases on older OS revisions). The delegate is shared
        // with `manager`; `LocationTracker` identity-checks the source
        // in every callback so wake-monitor events can be routed to
        // the no-op path without disturbing the tracking pipeline.
        wakeMonitor.delegate = self
        wakeMonitor.allowsBackgroundLocationUpdates = true

        // Apply the persisted Auto Wake state immediately. With the
        // default OFF, this issues `stopMonitoringSignificantLocationChanges()`
        // — which is what makes a clean install (or an upgrade from a
        // pre-1.2.12 version where SLC was always armed) start with no
        // OS-level wake subscription, instead of silently inheriting
        // the previous state. With ON, this issues `start...` so the
        // wake path is armed as early as possible (CoreLocation no-ops
        // the call until Always auth is granted, at which point
        // `handleAuthorizationState(.authorizedAlways)` re-runs this
        // helper and the subscription becomes effective).
        applyAutoWakeSetting()

        classifier.onModeChange = { [weak self] mode in
            self?.apply(mode: mode)
        }
        classifier.onUnavailable = { [weak self] reason in
            // Both reasons (hardware absent, permission denied) are
            // surfaced identically from the tracker's point of view:
            // the app cannot auto-switch activityType, stay on .fitness.
            _ = reason
            self?.addImpairment(.motionPermissionDenied)
        }
        classifier.start()

        // Observe Background App Refresh toggle (global or per-app).
        // `UIApplication.shared.backgroundRefreshStatus` reflects both
        // Settings > General > Background App Refresh (system switch)
        // and the per-app row; disabling either one breaks SLC's
        // terminated-state relaunch path. The notification fires on
        // every user change and on the first launch following one, so a
        // single subscription handles both live toggling and a cold
        // start after the user previously turned the setting off.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(backgroundRefreshStatusDidChange),
            name: UIApplication.backgroundRefreshStatusDidChangeNotification,
            object: nil
        )
        updateBackgroundRefreshImpairment()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func addImpairment(_ imp: TrackingImpairment) {
        DispatchQueue.main.async { [weak self] in
            self?.impairments.insert(imp)
        }
    }

    private func removeImpairment(_ imp: TrackingImpairment) {
        DispatchQueue.main.async { [weak self] in
            self?.impairments.remove(imp)
        }
    }

    /// Re-evaluate the Precise Location (iOS 14+) impairment against the
    /// manager's current `accuracyAuthorization`. Called from every
    /// authorization transition because the accuracy toggle can change
    /// independently of the auth state — iOS 14+ lets a user leave
    /// "Always" on while flipping "Precise Location" off, which would
    /// otherwise look like a grant from the permission-status point of
    /// view but silently reject 100% of fixes at the 50 m ceiling.
    private func updateAccuracyImpairment() {
        if #available(iOS 14.0, *) {
            if TrackingImpairment.impairment(for: manager.accuracyAuthorization) == .reducedAccuracy {
                addImpairment(.reducedAccuracy)
            } else {
                removeImpairment(.reducedAccuracy)
            }
        }
    }

    /// Re-evaluate the Background App Refresh impairment. Must touch
    /// `UIApplication.shared` on the main thread — we dispatch here so
    /// callers (notification callback, init) don't have to reason about
    /// thread affinity.
    private func updateBackgroundRefreshImpairment() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let status = UIApplication.shared.backgroundRefreshStatus
            if TrackingImpairment.impairment(for: status) == .backgroundRefreshDenied {
                self.impairments.insert(.backgroundRefreshDenied)
            } else {
                self.impairments.remove(.backgroundRefreshDenied)
            }
        }
    }

    @objc private func backgroundRefreshStatusDidChange() {
        updateBackgroundRefreshImpairment()
    }

    /// Cached SLC-launch context, captured at `start(launchedForLocation:)`
    /// time and consulted by `handleAuthorizationState` to make the
    /// `.fullTracking` vs `.deferred` decision when an authorization
    /// grant is what actually triggers the `beginUpdates` call.
    /// Defaults to `false` so any code path that constructs a
    /// LocationTracker without going through `start(launchedForLocation:)`
    /// (e.g. unit tests that just instantiate and exercise the
    /// delegate) treats it as a regular foreground session.
    private var launchedForLocation: Bool = false

    /// Kick off tracking. Called once from `AppContainer.bootstrap`
    /// at launch. The actual state transitions (notDetermined → requested →
    /// granted / denied / downgraded) are all handled in
    /// `locationManagerDidChangeAuthorization`, which is also where
    /// `beginUpdates` is invoked on any grant path.
    ///
    /// **`launchedForLocation`** is `true` when iOS spawned this
    /// process specifically to deliver a SLC event (i.e.
    /// `application(_:didFinishLaunchingWithOptions:)` saw
    /// `launchOptions[.location] != nil`). When that's the case
    /// **and** Auto Wake is enabled **and** a fresh home-zone anchor
    /// is on disk, we enter `.deferred` mode — the regular GPS
    /// stream stays off until the wake-monitor confirms displacement
    /// out of the home zone. Any other launch path (manual tap,
    /// BGAppRefresh, no anchor, stale anchor, Auto Wake off)
    /// proceeds with the pre-1.2.13 always-on `.fullTracking`
    /// behavior — full symmetry with the conscious-launch UX.
    func start(launchedForLocation: Bool) {
        self.launchedForLocation = launchedForLocation
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            handleAuthorizationState(manager.authorizationStatus)
        case .denied, .restricted:
            addImpairment(.permissionDenied)
        @unknown default:
            break
        }
    }

    /// Pure decision predicate for the deferred-mode entry, kept
    /// separate from `start(launchedForLocation:)` so unit tests can
    /// exercise the matrix (SLC-launch yes/no × Auto Wake yes/no ×
    /// anchor fresh / stale / missing) without spinning up a
    /// CLLocationManager. All four pre-conditions must be true:
    ///
    ///   1. iOS launched us specifically for a location event.
    ///   2. The user has opted into Auto Wake — without the SLC
    ///      subscription armed, deferred mode would never receive a
    ///      promotion signal and the app would stay silent forever.
    ///   3. A persistent anchor exists on disk — without one, we
    ///      have no reference point against which to evaluate the
    ///      next SLC fix's distance.
    ///   4. That anchor is fresh (within
    ///      `Config.anchorMaxAgeSeconds`). A stale anchor (from a
    ///      trip a week ago, say) is not safe to silence today's
    ///      first fix against.
    ///
    /// Made `internal` so `HomeZoneTests` can assert the matrix
    /// without going through `start`.
    func shouldEnterDeferredMode() -> Bool {
        guard launchedForLocation,
              Config.autoWakeEnabled,
              let anchor = Config.lastAnchor(),
              anchor.isFresh()
        else { return false }
        return true
    }

    /// Exit `.deferred` mode and start the regular GPS stream. Called
    /// from three sites:
    ///   - SwiftUI's `scenePhase = .active` observer in
    ///     `GpsLoggerApp` — user opened the app manually, so they
    ///     expect tracking to engage immediately.
    ///   - The wake-monitor delegate — a SLC fix outside the home
    ///     zone confirmed real displacement.
    ///   - `handleAuthorizationState(.authorizedAlways)` after a
    ///     fresh permission grant, in case the auth-state path is
    ///     the one bringing us out of deferred.
    ///
    /// Idempotent: calling on a tracker already in `.fullTracking`
    /// is a no-op (re-issuing `startUpdatingLocation` on a running
    /// manager is also idempotent per Apple's contract).
    func exitDeferredIfNeeded() {
        guard mode == .deferred else { return }
        mode = .fullTracking
        // Reset filter / smoother / stationary anchors so the first
        // accepted fix on the resumed stream is treated as a fresh
        // baseline — we have no reason to compare it against
        // anything that was running pre-deferred.
        filter.reset()
        smoother.reset()
        stationary.reset()
        beginUpdates()
    }

    private func beginUpdates() {
        manager.startUpdatingLocation()
        DispatchQueue.main.async { [weak self] in
            self?.isTracking = true
        }
    }

    private func stopUpdates() {
        manager.stopUpdatingLocation()
        // Intentionally do **not** call
        // `wakeMonitor.stopMonitoringSignificantLocationChanges()` here.
        // The wake subscription is the only thing that lets iOS relaunch
        // a terminated app for a user who forgot to open it; throwing it
        // away on every authorization revocation or transient stop just
        // burns the recovery path. iOS already ceases SLC delivery when
        // permission is revoked, so leaving the subscription armed is
        // safe — the OS handles disarming for us and re-arms it the
        // next time `applyAutoWakeSetting()` runs after a grant.
        DispatchQueue.main.async { [weak self] in
            self?.isTracking = false
        }
    }

    /// Bidirectional, idempotent. Aligns the OS-level SLC subscription
    /// on `wakeMonitor` with the persisted `Config.autoWakeEnabled`
    /// preference. ON ⇒ start, OFF ⇒ stop. Called from three sites:
    ///
    ///   - `init()` — defensively disarms any subscription left by a
    ///     pre-1.2.12 build where SLC was armed unconditionally, and
    ///     arms the subscription pre-emptively if the user previously
    ///     opted in. With Always auth not yet granted, the call is a
    ///     no-op until grant.
    ///   - `handleAuthorizationState(.authorizedAlways)` — re-arms
    ///     after a fresh grant or a re-grant following denial, so the
    ///     subscription becomes effective the moment the OS will
    ///     accept it.
    ///   - `setAutoWakeEnabled(_:)` — the toggle's side effect. Apple
    ///     guarantees `stopMonitoringSignificantLocationChanges()` is
    ///     a real OS-level halt: the subscription is removed from the
    ///     system database, so iOS will not relaunch this app on
    ///     significant displacement until `start...` is called again.
    ///
    /// Re-calling start on an already-armed manager and stop on a
    /// never-armed manager are both documented no-ops, so the three
    /// call sites do not need to coordinate.
    private func applyAutoWakeSetting() {
        if Config.autoWakeEnabled {
            wakeMonitor.startMonitoringSignificantLocationChanges()
        } else {
            wakeMonitor.stopMonitoringSignificantLocationChanges()
        }
    }

    /// Decide whether a wake-monitor SLC fix proves displacement out
    /// of the home zone large enough to exit `.deferred` mode and
    /// engage the regular GPS stream.
    ///
    /// Read like this: we are dozing. iOS just nudged us awake to
    /// say "the user moved significantly, you might want to record
    /// it." We compare that fix against where we last saw the user.
    /// If it's still inside the home-zone radius, the SLC was almost
    /// certainly a cellular-tower-handoff or Wi-Fi-fingerprint shift
    /// rather than real movement (the very pattern we observed all
    /// of 2026-04-26 night), and we stay quiet. iOS will re-suspend
    /// us shortly. If it's clearly outside the radius, the user has
    /// really gone somewhere and we promote.
    ///
    /// Stale anchor or no anchor: defensive promote. If we don't
    /// have a fresh reference point, we cannot prove the fix is
    /// "still home", so the safe default is full-tracking — exactly
    /// the pre-1.2.13 behavior.
    ///
    /// Made `internal` so unit tests can drive the decision without
    /// staging a real CLLocationManager.
    func evaluateWakeFixForDeferredExit(_ fix: CLLocation) {
        guard let anchor = Config.lastAnchor(), anchor.isFresh() else {
            // No reference point — promote to be safe.
            exitDeferredIfNeeded()
            return
        }
        let displacement = fix.distance(from: anchor.location)
        if displacement > Config.homeZoneRadiusMeters {
            #if DEBUG
            print("[tracker] deferred → fullTracking: SLC fix \(Int(displacement))m from anchor")
            #endif
            exitDeferredIfNeeded()
        } else {
            #if DEBUG
            print("[tracker] deferred kept: SLC fix \(Int(displacement))m from anchor (≤ \(Int(Config.homeZoneRadiusMeters)))")
            #endif
        }
    }

    /// Test-only escape hatch. Production code never calls this:
    /// `mode` is supposed to be governed exclusively by
    /// `start(launchedForLocation:)`, the wake-monitor branch in
    /// `didUpdateLocations`, and `exitDeferredIfNeeded`. This helper
    /// exists so unit tests can stage the `.deferred` state without
    /// reproducing the entire SLC-launch lifecycle (which would
    /// require a real CLLocationManager grant + UserDefaults setup
    /// + scene phase plumbing). Annotated with the suffix so any
    /// production-code caller is immediately obvious in code review.
    func forceDeferredModeForTesting() {
        mode = .deferred
    }

    /// Test-only accessor for the regular tracking-manager instance.
    /// Mirrors the existing `wakeMonitor` accessor pattern (which is
    /// `internal` so `WakeMonitorRoutingTests` can route synthetic
    /// fixes through the wake delegate path). `HomeZoneTests` needs
    /// the regular-manager handle so it can drive the
    /// `manager === self.manager` branch of `didUpdateLocations`,
    /// which is where the home-zone pre-check sits.
    func testingTrackingManager() -> CLLocationManager {
        manager
    }

    /// Test-only: drive `handleAuthorizationState(_:)` directly,
    /// since the production path (CLLocationManager delegate
    /// callback) requires real authorization state that the test
    /// bundle cannot provide. Used by `HomeZoneTests` to verify the
    /// mode-decision logic + the single-evaluation contract for
    /// `launchedForLocation` (cleared after every grant evaluation).
    func handleAuthorizationStateForTesting(_ status: CLAuthorizationStatus) {
        handleAuthorizationState(status)
    }

    /// Test-only read of the SLC-launch flag. Production code never
    /// inspects it directly — `shouldEnterDeferredMode()` is the
    /// single decision boundary. Tests use this to assert the
    /// single-evaluation contract: the flag must be `false` after
    /// any `handleAuthorizationState(.authorizedAlways)` /
    /// `.authorizedWhenInUse` call.
    var launchedForLocationFlagForTesting: Bool {
        launchedForLocation
    }

    /// Toggle the Auto Wake (SLC-based relaunch) feature. Persists the
    /// user's choice in `UserDefaults` so the next launch picks it up
    /// via `Config.autoWakeEnabled`, updates the published mirror
    /// driving the UI, and immediately arms or disarms the OS-level
    /// SLC subscription via `applyAutoWakeSetting()`. The OFF path is
    /// what gives the kill switch its teeth: it produces a real
    /// `stopMonitoringSignificantLocationChanges()` call, not just a
    /// UI flag — iOS will not wake the app from significant
    /// displacement until the user toggles back on.
    ///
    /// Has no side effect on regular tracking, sync, points, or
    /// device identity. Must be called on the main thread (the only
    /// caller is the SwiftUI Toggle binding in `AutoWakeSettingsView`).
    func setAutoWakeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Config.autoWakeEnabledKey)
        autoWakeEnabled = enabled
        applyAutoWakeSetting()
    }

    /// Single place that reacts to every authorization state change. Keeps
    /// filter/stationary state in sync (a re-grant after denial resets the
    /// internal anchors so stale state doesn't bleed into the new session)
    /// and translates Apple's five-valued enum into at-most-one impairment.
    ///
    /// **Single-evaluation contract for `launchedForLocation`** (1.2.13).
    /// The flag captures the SLC-launch context at app boot; it is
    /// only meaningful for the **first** authorization-grant call after
    /// launch. Subsequent grant calls (revoke + re-grant, downgrade +
    /// upgrade) must NOT be treated as SLC-launches — by then the user
    /// has been alive in some mode for a while and a fresh deferred
    /// entry would surprise them. The flag is therefore cleared after
    /// every grant evaluation here, so any subsequent
    /// `handleAuthorizationState(.authorizedAlways)` always lands in
    /// `.fullTracking` regardless of how the original launch happened.
    private func handleAuthorizationState(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways:
            // Full permission. Clear any prior impairment that depended on
            // location auth, and start/resume the update stream.
            removeImpairment(.permissionDenied)
            removeImpairment(.backgroundRequiresAlways)
            // Apply the Auto Wake state with the OS now ready to
            // accept SLC. If the user has opted in (and SLC was
            // pre-issued in init while auth was still pending), this
            // re-issue is what activates the subscription per Apple's
            // contract. If the user has opted out, this is a defensive
            // stop — same effect as init's call, kept for symmetry so
            // every authoritative state transition leaves the wake
            // subscription in a known state.
            applyAutoWakeSetting()
            if !isTracking {
                // Decide: full pipeline or `.deferred` quiet wait?
                // The deferred path is reachable only when iOS
                // launched us specifically for a SLC event AND Auto
                // Wake is on AND we have a fresh home-zone anchor —
                // any other launch context (user tap, no anchor,
                // stale anchor, Auto Wake off) goes straight to
                // `.fullTracking` so the conscious-launch UX is
                // bit-for-bit identical to the pre-1.2.13 behavior.
                if shouldEnterDeferredMode() {
                    mode = .deferred
                    // Do **not** call beginUpdates(). The wake-monitor
                    // is already armed by applyAutoWakeSetting() above
                    // and will deliver the first SLC fix when iOS
                    // decides to. exitDeferredIfNeeded() takes us out
                    // when that fix is far enough or when the user
                    // opens the app.
                } else {
                    // Re-grant after a previous denial (or any other
                    // non-deferred path): drop stale filter anchors so
                    // the first accepted fix becomes a fresh baseline
                    // instead of being compared against an hours-old
                    // last-accepted position.
                    mode = .fullTracking
                    filter.reset()
                    smoother.reset()
                    stationary.reset()
                    beginUpdates()
                }
            } else if mode == .deferred {
                // Defensive: isTracking == true together with mode ==
                // .deferred is a state-machine inconsistency, reachable
                // only via test helpers or an iOS callback ordering we
                // didn't anticipate. Promote to fullTracking to put the
                // tracker back into a coherent state.
                exitDeferredIfNeeded()
            }
            // Single-evaluation contract: see the function-level
            // docstring. After this branch the flag has fulfilled its
            // purpose and any subsequent grant must not re-trigger the
            // deferred path.
            launchedForLocation = false
        case .authorizedWhenInUse:
            // Foreground-only. iOS silently stops delivering updates once
            // the app is backgrounded, even with
            // `allowsBackgroundLocationUpdates = true`. Surface this so
            // the user is aware their trace will have gaps.
            removeImpairment(.permissionDenied)
            addImpairment(.backgroundRequiresAlways)
            if !isTracking {
                // WhenInUse cannot drive deferred — Apple documents
                // SLC as requiring `.authorizedAlways`, so the
                // wake-monitor will never deliver a promotion signal
                // under WhenInUse. Always go straight to fullTracking
                // here, with a fresh filter baseline.
                mode = .fullTracking
                filter.reset()
                smoother.reset()
                stationary.reset()
                beginUpdates()
            } else if mode == .deferred {
                // Reachable only after an `.authorizedAlways → .authorizedWhenInUse`
                // downgrade while we were sitting in deferred. The
                // wake-monitor will go silent under WhenInUse, so
                // we'd otherwise be stuck. Defensive promote.
                exitDeferredIfNeeded()
            }
            // Same single-evaluation contract as the .authorizedAlways
            // branch — clear the SLC-launch flag once the first grant
            // evaluation has happened.
            launchedForLocation = false
        case .denied, .restricted:
            // Tracking can no longer proceed. Stop cleanly so we aren't
            // hanging on to the CLLocationManager stream, and surface the
            // impairment so the UI can show a banner.
            if isTracking {
                stopUpdates()
            }
            addImpairment(.permissionDenied)
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    /// Map a `MotionClassifier.Mode` to the `CLActivityType` hint used by
    /// CoreLocation's fusion engine, and apply it if it actually changes.
    /// Called on the main queue because `MotionClassifier` delivers
    /// updates there.
    ///
    /// Mapping rationale:
    /// - `.pedestrian` / `.cycling` → `.fitness` (Apple's documented hint
    ///   for walking/running/cycling).
    /// - `.automotive` → `.automotiveNavigation` (correct for car, bus,
    ///   and train — CoreMotion does not distinguish between them).
    /// - `.unknown` is intentionally left as a no-op: if CoreMotion can't
    ///   classify (stationary, low confidence, permission denied), we
    ///   keep whatever hint was last applied instead of flapping back to
    ///   the default on every ambiguous reading.
    private func apply(mode: MotionClassifier.Mode) {
        DispatchQueue.main.async { [weak self] in
            self?.motionMode = mode
        }

        // 1.2.9: widen the spike-jump threshold when motion is motorized.
        // Pedestrian / cycling default is 250 m; automotive is 750 m to
        // accommodate legitimate high-speed sample deltas. `.unknown`
        // leaves the current threshold untouched for the same reason
        // `activityType` stays put — low-confidence readings shouldn't
        // flap the filter back to its default mid-trip.
        switch mode {
        case .pedestrian, .cycling:
            filter.setAutomotive(false)
        case .automotive:
            filter.setAutomotive(true)
        case .unknown:
            break
        }

        let target: CLActivityType?
        switch mode {
        case .pedestrian, .cycling:
            target = .fitness
        case .automotive:
            target = .automotiveNavigation
        case .unknown:
            target = nil
        }

        guard let target = target, manager.activityType != target else { return }
        manager.activityType = target
        #if DEBUG
        print("[tracker] activityType -> \(target.rawValue) (\(mode))")
        #endif
    }

    private func persist(_ loc: CLLocation) {
        // Snapshot the CLLocation fields before hopping queues. CLLocation
        // is a reference type; capturing it across a queue boundary is
        // fine, but capturing only the primitives keeps the closure small
        // and avoids retaining the whole object in the background queue.
        let lat = loc.coordinate.latitude
        let lon = loc.coordinate.longitude
        let timestamp = loc.timestamp
        persistQueue.async { [database, appState] in
            // `insert` returns false on any prepare/step failure. Skipping
            // the counter bump when the row didn't land is what prevents
            // the in-memory `unsyncedCount` from drifting off the actual
            // DB row count on disk-full / WAL contention / schema errors.
            let ok = database.insert(
                latitude: lat,
                longitude: lon,
                createdAt: timestamp
            )
            if ok {
                DispatchQueue.main.async {
                    appState.unsyncedCount += 1
                }
                // Update the home-zone anchor to reflect the new
                // most-recent persisted point. UserDefaults writes
                // are atomic per-key and thread-safe; doing this on
                // the persist queue keeps the work off main and
                // co-located with the SQLite insert it follows. The
                // anchor naturally tracks the user across the day:
                // walking → anchor moves with each accepted fix;
                // arrived somewhere → anchor freezes at the last fix
                // before stationary suppression kicks in; left that
                // place → anchor moves again.
                Config.updateLastAnchor(
                    latitude: lat,
                    longitude: lon,
                    timestamp: timestamp
                )
            }
        }
    }

    /// Persist with a final stationary-jitter gate. Every accept path from
    /// `LocationFilter` funnels through here so stationary suppression is
    /// applied uniformly to direct accepts, spike replacements, and
    /// committed-pending emissions.
    ///
    /// Pipeline order is deliberate:
    ///   1. `smoother.consume` — averages the accepted-fix stream against
    ///      a constant-velocity motion prior. Downstream stages see
    ///      smoothed coordinates, so stationary-cluster detection and
    ///      the persisted `points` row both benefit.
    ///   2. `stationary.consume` — uses the smoothed coordinate for its
    ///      distance-to-anchor math. Smoothed positions cluster more
    ///      tightly than raw ones, which *improves* stationary detection
    ///      rather than hurting it (less jitter → fewer spurious
    ///      cluster-breaks).
    ///
    /// Returns the stationary detector's decision so the caller can
    /// include it in the `fix_diagnostics` tag (1.2.9) — otherwise
    /// stationary suppressions were invisible in post-hoc queries and
    /// the detector could not be tuned against real data.
    @discardableResult
    private func maybePersist(_ loc: CLLocation) -> StationaryDetector.Decision {
        // Home-zone pre-check (1.2.13). Any fix landing within the
        // home-zone radius of a fresh persisted anchor is suppressed
        // before reaching the smoother / stationary detector. This is
        // the gate that kills the indoor-jitter phantom-points pattern
        // documented on 2026-04-26: a 19-minute LocationFilter-rejected
        // window followed by two fixes 33 m and 44 m from the
        // evening's last accepted point. Both well inside the 100 m
        // home zone — both should never have been written.
        //
        // Without this gate, the surviving fixes hit
        // `StationaryDetector.consume` after the gap-reset path
        // promoted the returning fix to a fresh candidate anchor,
        // producing the phantom rows. The pre-check makes that path
        // unreachable while we're sitting in a known place.
        //
        // Stale anchor (>24 h) or no anchor → behave exactly like
        // pre-1.2.13: every accepted fix flows through smoother +
        // stationary detector unchanged. So a returning user from a
        // long trip immediately starts collecting data again at the
        // new location.
        if let anchor = Config.lastAnchor(),
           anchor.isFresh(),
           loc.distance(from: anchor.location) <= Config.homeZoneRadiusMeters {
            #if DEBUG
            let d = Int(loc.distance(from: anchor.location))
            print("[tracker] suppress home-zone @ \(loc.coordinate.latitude),\(loc.coordinate.longitude) (\(d)m from anchor)")
            #endif
            return .suppress
        }

        let smoothed = smoother.consume(loc)
        let decision = stationary.consume(smoothed)
        switch decision {
        case .accept:
            persist(smoothed)
        case .suppress:
            #if DEBUG
            print("[tracker] suppress stationary @ \(smoothed.coordinate.latitude),\(smoothed.coordinate.longitude)")
            #endif
        }
        return decision
    }

    private func logDiscard(_ reason: LocationFilter.Reason, _ loc: CLLocation) {
        #if DEBUG
        let coord = "\(loc.coordinate.latitude),\(loc.coordinate.longitude)"
        switch reason {
        case .invalidFix:
            print("[tracker] discard invalid @ \(coord)")
        case .nonGpsSource:
            print("[tracker] discard nonGps speed=\(loc.speed) vAcc=\(loc.verticalAccuracy) @ \(coord)")
        case .poorAccuracy(let m):
            print("[tracker] discard accuracy=\(Int(m))m @ \(coord)")
        case .staleTimestamp:
            print("[tracker] discard stale @ \(coord)")
        case .implausibleSpeed(let mps):
            print("[tracker] discard speed=\(Int(mps * 3.6))kmh @ \(coord)")
        case .tooClose:
            break // extremely chatty, and redundant with distanceFilter
        case .staleDelivery:
            let age = Int(Date().timeIntervalSince(loc.timestamp))
            print("[tracker] discard stale delivery age=\(age)s @ \(coord)")
        }
        #endif
    }
}

extension LocationTracker: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Both managers share the app's authorization state, so iOS
        // fires this on each instance. Respond once via the primary
        // tracking manager; the wakeMonitor's redundant callback
        // would just re-run the same idempotent body and is safe to
        // ignore.
        guard manager === self.manager else { return }
        let status = manager.authorizationStatus
        DispatchQueue.main.async { [weak self] in
            self?.authStatus = status
        }
        handleAuthorizationState(status)
        // iOS 14+ fires `didChangeAuthorization` for accuracy-only changes
        // too (the user left Always on but toggled Precise Location off
        // / on mid-session). Re-evaluate the accuracy impairment on every
        // transition so the banner reflects the current state without
        // waiting for a fix to come in and get rejected.
        updateAccuracyImpairment()
    }

    /// iOS is documented to stop calling this when
    /// `pausesLocationUpdatesAutomatically = false`, but production
    /// reports on the Apple Developer Forums show it still firing on
    /// rare device / OS combinations (post-update scenarios, specific
    /// hardware). The callback is informational; our response is to
    /// re-issue `startUpdatingLocation()` so the stream resumes without
    /// waiting for the next system event. Idempotent — re-calling
    /// `startUpdatingLocation` on an already-running manager is a no-op.
    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        // SLC has no pause/resume semantics; only the regular update
        // stream can pause. Ignore any spurious wake-monitor callback.
        guard manager === self.manager else { return }
        #if DEBUG
        print("[tracker] locationManagerDidPauseLocationUpdates — re-issuing startUpdatingLocation()")
        #endif
        // Unconditional so release builds also surface the event in
        // Console.app, since a silent pause is exactly the class of
        // problem this handler exists to catch.
        print("[tracker] WARN: CoreLocation paused updates despite pausesAutomatically=false — re-starting")
        manager.startUpdatingLocation()
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        guard manager === self.manager else { return }
        #if DEBUG
        print("[tracker] locationManagerDidResumeLocationUpdates")
        #endif
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // SLC events from `wakeMonitor` are intentional no-ops as far
        // as the persist pipeline is concerned. They never enter
        // filter → smoother → stationary → persist; their job —
        // relaunching the process via `UIApplicationLaunchOptionsLocationKey`
        // — is already done by the time this delegate fires.
        //
        // The one purpose they DO serve (1.2.13) is to drive the
        // exit from `.deferred` mode. When we boot via SLC into a
        // fresh home zone, the regular update stream is intentionally
        // left off. The wake-monitor's first fix is what tells us
        // where we actually are; if it's outside the home zone, the
        // user has genuinely moved and we promote to `.fullTracking`.
        guard manager === self.manager else {
            if mode == .deferred, let fix = locations.last {
                evaluateWakeFixForDeferredExit(fix)
            }
            #if DEBUG
            if let last = locations.last {
                print("[tracker] SLC wake event x\(locations.count) @ \(last.coordinate.latitude),\(last.coordinate.longitude) — mode=\(mode.rawValue)")
            }
            #endif
            return
        }

        // Apple documents `locations` as already sorted ascending by
        // timestamp, and the spike-buffer + chronology logic in
        // `LocationFilter` depends on that ordering. Sort defensively
        // anyway so a future iOS change in array semantics cannot silently
        // corrupt filter state — the array is almost always 1–3 elements
        // in live tracking (larger only after signal recovery or app-wake
        // from suspended state), so the cost is negligible.
        for loc in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            let decision = filter.consume(loc)

            // Run the downstream pipeline first (smoother → stationary →
            // persist) so the fix_diagnostics row can reflect both the
            // filter verdict AND the stationary verdict. The previous
            // arrangement wrote the diagnostic before the pipeline ran and
            // therefore could not distinguish an accept-that-got-persisted
            // from an accept-that-stationary-suppressed. 1.2.9 adds the
            // stationary-suppress suffix to the tag — see `diagnosticTag`.
            var stationarySuppressed = false
            switch decision {
            case .accept(let accepted):
                stationarySuppressed = maybePersist(accepted) == .suppress

            case .buffered:
                break // waiting for next fix to confirm

            case .discard(let reason):
                logDiscard(reason, loc)

            case .spikeReplaced(let dropped, let accepted):
                #if DEBUG
                print("[tracker] discard spike @ \(dropped.coordinate.latitude),\(dropped.coordinate.longitude)")
                #endif
                if let accepted = accepted {
                    stationarySuppressed = maybePersist(accepted) == .suppress
                }

            case .committedPending(let pending, let alsoAccept):
                let pendingDecision = maybePersist(pending)
                var alsoDecision: StationaryDetector.Decision = .accept
                if let alsoAccept = alsoAccept {
                    alsoDecision = maybePersist(alsoAccept)
                }
                // A compound-emission fix collapses to one diagnostic
                // row; flag `stationarySuppress` if either emission
                // suppressed. Rare enough (`committedPending` is itself
                // uncommon) that the minor granularity loss is fine.
                stationarySuppressed = pendingDecision == .suppress
                    || alsoDecision == .suppress
            }

            // Update the consecutive-discard observability counter. Any
            // non-discard decision resets it; `.buffered` is intentionally
            // a no-op so that a single held-back spike doesn't spuriously
            // reset a real streak. The counter is for logging only.
            switch decision {
            case .accept, .spikeReplaced, .committedPending:
                discardStreak = 0
            case .buffered:
                break
            case .discard:
                discardStreak += 1
            }

            // Unconditional (not DEBUG-only) so sustained deadlocks in
            // release builds show up in Console.app without needing
            // the Postgres fix_diagnostics query. Triggered on every
            // multiple of the threshold so the spam is bounded.
            if case .discard = decision,
               discardStreak > 0,
               discardStreak % Self.discardStreakLogThreshold == 0 {
                print("[tracker] WARN: \(discardStreak) consecutive discards, latest=\(diagnosticTag(decision, stationarySuppressed: false)) hAcc=\(Int(loc.horizontalAccuracy))m")
            }

            // Debug observability: snapshot every raw fix with its full
            // set of CLLocation fields plus the composed filter +
            // stationary verdict. Gated on `Config.syncDiagnosticsEnabled`
            // (default false) — the channel was scaffolding for the 1.2.x
            // filter tuning and is pure overhead in steady-state use
            // (~95% of disk writes and uplink bytes without it). When off,
            // we skip the entire snapshot + queue hop, not just the SQLite
            // write, so CoreLocation callbacks are as light as possible.
            // Flip the flag at runtime when a new tuning campaign starts;
            // see `Config.syncDiagnosticsEnabled`.
            if Config.syncDiagnosticsEnabled {
                let snapshot = FixDiagnostic(
                    fixTimestamp: loc.timestamp,
                    latitude: loc.coordinate.latitude,
                    longitude: loc.coordinate.longitude,
                    horizontalAccuracy: loc.horizontalAccuracy,
                    verticalAccuracy: loc.verticalAccuracy,
                    altitude: loc.altitude,
                    speed: loc.speed,
                    speedAccuracy: loc.speedAccuracy,
                    course: loc.course,
                    courseAccuracy: loc.courseAccuracy,
                    decision: diagnosticTag(decision, stationarySuppressed: stationarySuppressed)
                )
                persistQueue.async { [database] in
                    database.logDiagnostic(snapshot)
                }
            }
        }
    }

    /// Compose the `fix_diagnostics.decision` tag from the filter verdict
    /// and the downstream stationary detector's verdict (1.2.9). Used
    /// for observability only — never affects control flow.
    ///
    /// Tag format:
    ///   - Filter discards: `discard:<reason>` (stationary never consulted).
    ///   - Filter accepts (`accept` / `spikeReplaced` / `committedPending`
    ///     / `buffered`): base tag verbatim, plus `:stationarySuppress`
    ///     suffix if at least one emission to the stationary detector
    ///     was suppressed as jitter.
    ///
    /// The suffix is what lets post-hoc SQL distinguish "persisted to
    /// `points`" from "accepted by filter but dropped by stationary",
    /// which was previously indistinguishable.
    private func diagnosticTag(
        _ decision: LocationFilter.Decision,
        stationarySuppressed: Bool
    ) -> String {
        let base: String
        switch decision {
        case .accept: base = "accept"
        case .buffered: base = "buffered"
        case .spikeReplaced: base = "spikeReplaced"
        case .committedPending: base = "committedPending"
        case .discard(let reason):
            // Discards never reach the stationary stage; return straight away.
            switch reason {
            case .invalidFix: return "discard:invalidFix"
            case .nonGpsSource: return "discard:nonGpsSource"
            case .poorAccuracy: return "discard:poorAccuracy"
            case .staleTimestamp: return "discard:staleTimestamp"
            case .implausibleSpeed: return "discard:implausibleSpeed"
            case .tooClose: return "discard:tooClose"
            case .staleDelivery: return "discard:staleDelivery"
            }
        }
        return stationarySuppressed ? "\(base):stationarySuppress" : base
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Wake-monitor errors do not affect the tracking pipeline; log
        // them under DEBUG and return. We never call `stopUpdates()`
        // off a wake-monitor error, since doing so would pull down the
        // regular tracking stream that has nothing to do with the SLC
        // failure.
        guard manager === self.manager else {
            #if DEBUG
            print("[tracker] wakeMonitor error: \(error.localizedDescription) — ignoring")
            #endif
            return
        }
        // `CLError` carries a coded reason; the raw `error.localizedDescription`
        // throws useful context away. Handle the codes we care about and
        // log the rest under DEBUG.
        guard let clError = error as? CLError else {
            #if DEBUG
            print("[tracker] non-CL error: \(error.localizedDescription)")
            #endif
            return
        }
        switch clError.code {
        case .denied:
            // User revoked permission while we were running. CoreLocation
            // stops delivering updates. Mirror the state we'd set on an
            // authorization-change callback so UI impairment is consistent.
            stopUpdates()
            addImpairment(.permissionDenied)
        case .locationUnknown:
            // Transient — CoreLocation could not compute a fix right now.
            // It will retry automatically. Ignore.
            break
        case .network:
            #if DEBUG
            print("[tracker] CLError.network — CoreLocation will retry")
            #endif
        case .headingFailure, .rangingUnavailable, .rangingFailure:
            // We don't use heading or ranging APIs.
            break
        default:
            #if DEBUG
            print("[tracker] CLError code=\(clError.code.rawValue)")
            #endif
        }
    }
}
