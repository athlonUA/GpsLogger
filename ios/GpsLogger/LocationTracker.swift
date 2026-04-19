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

    @Published private(set) var isTracking = false
    @Published private(set) var authStatus: CLAuthorizationStatus
    @Published private(set) var motionMode: MotionClassifier.Mode = .unknown
    @Published private(set) var impairments: Set<TrackingImpairment> = []

    private let manager = CLLocationManager()
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

    /// Kick off tracking. Called once from `AppContainer` at launch.
    /// The actual state transitions (notDetermined → requested → granted /
    /// denied / downgraded) are all handled in
    /// `locationManagerDidChangeAuthorization`, which is also where
    /// `beginUpdates` is invoked on any grant path.
    func start() {
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

    private func beginUpdates() {
        manager.startUpdatingLocation()
        // Significant-location-changes is a secondary wake path. iOS can
        // suspend or kill the app under memory pressure even with
        // `.location` bg mode active; when that happens, regular
        // `didUpdateLocations` callbacks stop until `distanceFilter` is
        // crossed. SLC is cellular-triangulation powered (no extra GPS
        // radio cost), fires on ~500 m displacements, and critically
        // **relaunches the app** via `UIApplicationLaunchOptionsLocationKey`
        // even from terminated state. On relaunch, `AppContainer.init`
        // reconstructs the tracker and calls `start()` → `beginUpdates()`
        // → the regular update stream resumes. Defense in depth against
        // long background blackouts; no behavior change under normal
        // operation because SLC fixes flow through the same filter path
        // and either get accepted or correctly rejected on poor accuracy.
        manager.startMonitoringSignificantLocationChanges()
        DispatchQueue.main.async { [weak self] in
            self?.isTracking = true
        }
    }

    private func stopUpdates() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        DispatchQueue.main.async { [weak self] in
            self?.isTracking = false
        }
    }

    /// Single place that reacts to every authorization state change. Keeps
    /// filter/stationary state in sync (a re-grant after denial resets the
    /// internal anchors so stale state doesn't bleed into the new session)
    /// and translates Apple's five-valued enum into at-most-one impairment.
    private func handleAuthorizationState(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways:
            // Full permission. Clear any prior impairment that depended on
            // location auth, and start/resume the update stream.
            removeImpairment(.permissionDenied)
            removeImpairment(.backgroundRequiresAlways)
            if !isTracking {
                // Re-grant after a previous denial: drop stale filter
                // anchors so the first accepted fix becomes a fresh
                // baseline instead of being compared against an hours-old
                // last-accepted position.
                filter.reset()
                smoother.reset()
                stationary.reset()
                beginUpdates()
            }
        case .authorizedWhenInUse:
            // Foreground-only. iOS silently stops delivering updates once
            // the app is backgrounded, even with
            // `allowsBackgroundLocationUpdates = true`. Surface this so
            // the user is aware their trace will have gaps.
            removeImpairment(.permissionDenied)
            addImpairment(.backgroundRequiresAlways)
            if !isTracking {
                filter.reset()
                smoother.reset()
                stationary.reset()
                beginUpdates()
            }
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
        #if DEBUG
        print("[tracker] locationManagerDidResumeLocationUpdates")
        #endif
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
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
