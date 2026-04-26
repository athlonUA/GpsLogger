import Foundation
import CoreLocation

enum Config {
    /// Simulator-friendly fallback for `apiBaseURL`. The iOS Simulator
    /// shares the Mac's network stack, so `http://localhost:3000` reaches
    /// the docker-compose backend without any configuration.
    static let defaultApiBaseURL = URL(string: "http://localhost:3000")!

    /// UserDefaults key holding the runtime-configurable backend URL.
    /// Stored as a raw string so it can be edited via `defaults write` for
    /// quick re-pointing during development without a rebuild.
    static let apiBaseURLKey = "apiBaseURL"

    /// Info.plist key populated at build time from the gitignored
    /// `GpsLogger.xcconfig` (`API_BASE_URL = http://<LAN-IP>:3000`). This
    /// is the path that keeps personal LAN IPs out of git while producing
    /// a self-contained physical-device build.
    static let apiBaseURLInfoKey = "API_BASE_URL"

    /// Effective backend URL. Resolution order:
    ///   1. Runtime override via `UserDefaults` (for re-pointing the app
    ///      between hosts without rebuilding — `defaults write` the key
    ///      above from the Simulator or via a dev hook on device).
    ///   2. Build-time value from `Info.plist["API_BASE_URL"]`, populated
    ///      by `$(API_BASE_URL)` substitution from the gitignored xcconfig.
    ///      This is what the on-device build relies on in normal operation.
    ///   3. Simulator fallback `defaultApiBaseURL` (localhost:3000).
    /// Read at every call site so the UserDefaults override takes effect
    /// on the next sync tick without a restart.
    static var apiBaseURL: URL {
        if let raw = UserDefaults.standard.string(forKey: apiBaseURLKey),
           let url = URL(string: raw),
           url.scheme != nil {
            return url
        }
        if let raw = Bundle.main.object(forInfoDictionaryKey: apiBaseURLInfoKey) as? String,
           !raw.isEmpty,
           let url = URL(string: raw),
           url.scheme != nil {
            return url
        }
        return defaultApiBaseURL
    }

    /// Sync timer interval. Spec allows 30–60s.
    static let syncIntervalSeconds: TimeInterval = 30

    /// Max points uploaded per request.
    static let syncBatchSize = 100

    /// Minimum distance between saved points, in meters.
    static let minDistanceMeters: CLLocationDistance = 10

    /// Primary quality signal: discard any fix whose reported horizontal
    /// accuracy is worse than this. 25 m is the tightened ceiling
    /// (1.2.9) — empirical data across four days and two devices showed
    /// the previous 50 m ceiling was letting through a long tail of
    /// 30–50 m fixes, especially on iPhone 8 under Mediterranean tree
    /// canopy (259 persisted accepts with HA > 30 m in a single hour
    /// vs 1 on iPhone 13 Pro Max). Those fixes were distorting the
    /// rendered trace by up to half a city block without improving
    /// completeness in any measurable way. 25 m produces near-lossless
    /// behavior on a clean GNSS device (iPhone 13 Pro Max sits at
    /// p90 = 14 m) and honest gaps-instead-of-lies on iPhone 8 under
    /// canopy, which is the correct trade for a visualization-focused
    /// tracker. Still movement-type agnostic.
    static let maxHorizontalAccuracyMeters: CLLocationDistance = 25

    /// Extremely relaxed speed ceiling, used **only** to catch teleport-class
    /// glitches (impossible physics), never to gate normal movement.
    /// 500 km/h ≈ 138.9 m/s comfortably covers any real surface transport:
    ///   - walking / running: ~5 km/h
    ///   - urban driving:     ~50 km/h
    ///   - highway:           ~130 km/h
    ///   - high-speed rail:   ~300–350 km/h (Shinkansen, TGV, AVE)
    ///   - maglev:            ~430 km/h (Shanghai)
    /// Anything above 500 km/h on a phone implies a hardware or fusion glitch,
    /// not real movement. Intentionally chosen *not* to match any transport
    /// mode so it cannot produce false negatives against legitimate users.
    static let maxPlausibleSpeedMps: CLLocationSpeed = 500.0 * 1000.0 / 3600.0

    /// A new point farther than this from the last accepted point is
    /// treated as *suspicious* and held back one tick for A → B → C
    /// spike resolution (see `LocationFilter`).
    ///
    /// Walking / cycling default: **250 m** (1.2.9, tightened from the
    /// blanket 750 m). On 2026-04-18, iPhone 8 under canopy produced
    /// two genuine multipath jumps of 410 m that the old threshold let
    /// through. 250 m catches them while still exceeding any legitimate
    /// sample delta observed in the dataset (max < 50 m for walking,
    /// < 100 m for cycling).
    ///
    /// For automotive / rail, the threshold widens to
    /// `spikeJumpMetersAutomotive` — see that constant for rationale.
    /// Mode selection is driven by `MotionClassifier`; `LocationTracker`
    /// calls `LocationFilter.setAutomotive(_:)` on every mode change.
    static let spikeJumpMeters: CLLocationDistance = 250

    /// Wider spike-jump threshold applied under
    /// `MotionClassifier.Mode == .automotive`. Sized so normal
    /// high-speed transport never triggers buffering:
    ///   - 350 km/h ≈ 97 m/s → 5 s sample delta ≈ 485 m (< 750)
    ///   - 130 km/h ≈ 36 m/s → 5 s sample delta ≈ 180 m (< 750)
    /// Only genuine teleports on a motorway cross 750 m between samples.
    /// Pedestrian / cyclist traces never reach this mode so the loose
    /// threshold is not in effect for them.
    static let spikeJumpMetersAutomotive: CLLocationDistance = 750

    /// Companion to `spikeJumpMeters`: if — after a suspicious point was
    /// buffered — the *next* fix lands within this radius of the last
    /// accepted point, the buffered one is confirmed as a spike and dropped
    /// (classic A → B(far) → C(near A) return pattern). Scaled proportionally
    /// to `spikeJumpMeters` so fast travel can't accidentally satisfy it.
    static let spikeReturnMeters: CLLocationDistance = 100

    /// Maximum age for a fix held in `LocationFilter.pending`. The spike
    /// buffer holds a single "suspicious" fix waiting for the next fix to
    /// confirm or reject it. If the app is backgrounded or CoreLocation
    /// goes quiet for longer than this, the pending point is stale — the
    /// A → B → C temporal pattern is broken — and we drop it silently so
    /// a returning fix isn't compared against hours-old state. 30 s covers
    /// normal delivery gaps (1 Hz cadence under `kCLDistanceFilterNone`,
    /// 1.2.7, low signal, brief backgrounding) while catching any long
    /// pause.
    static let pendingTimeoutSeconds: TimeInterval = 30

    /// Stationary detection — how long a candidate cluster must persist before
    /// we declare the user stationary and stop recording further points.
    /// 150 s (2.5 min) is long enough that genuine short stops (traffic lights,
    /// pedestrian crossings) never trigger it, but short enough that sitting
    /// indoors gets suppressed quickly.
    static let stationaryWindowSeconds: TimeInterval = 150

    /// Radius of the stationary cluster. While the user is not yet classified
    /// as stationary, each new accepted fix must fall within this distance of
    /// the candidate anchor to extend the cluster. A fix outside this radius
    /// resets the candidate to itself (i.e., restarts the clock). 20 m is
    /// comfortably above typical indoor GPS jitter (~5–15 m) while still
    /// rejecting true walking.
    static let stationaryRadiusMeters: CLLocationDistance = 20

    /// Exit threshold — once stationary, a new fix farther than this from the
    /// cluster center resumes normal recording. Strictly greater than
    /// `stationaryRadiusMeters` so a single borderline jitter point can't
    /// toggle the mode. 30 m adds ~10 m of hysteresis.
    static let stationaryResumeMeters: CLLocationDistance = 30

    /// Maximum age of a CLLocation fix relative to wall-clock time. CoreLocation
    /// may deliver cached locations after a signal gap — Apple's documentation
    /// explicitly recommends checking fix age. 10 s is generous enough to never
    /// reject fresh fixes (normal delivery latency is 0.5–2 s) while catching
    /// any cached replay from a previous signal window.
    static let maxFixAgeSeconds: TimeInterval = 10

    /// How long no-fix-seen counts as "lost the user" for the
    /// `StationaryDetector`. Used only by the gap-reset guard in
    /// `StationaryDetector.consume`: if the inter-sample gap exceeds
    /// this, the candidate anchor is treated as stale and the returning
    /// fix starts a fresh cluster instead of inheriting the old window.
    ///
    /// This is a separate knob from `kalmanResetGapSeconds` (10 s) on
    /// purpose. The two subsystems model different things:
    ///
    ///   | threshold                      | what it protects against           |
    ///   | ------------------------------ | ---------------------------------- |
    ///   | `kalmanResetGapSeconds = 10 s` | stale velocity prior (Kalman state |
    ///   |                                | decays fast — 10 s with no         |
    ///   |                                | evidence already makes `v` a poor  |
    ///   |                                | predictor, so we re-seed)          |
    ///   | `resumeGapSeconds      = 60 s` | stale cluster anchor (a candidate  |
    ///   |                                | is only valid while we actually    |
    ///   |                                | keep seeing points near it; after  |
    ///   |                                | 60 s of silence we don't know      |
    ///   |                                | what the user did)                 |
    ///
    /// There used to be a third gap-aware threshold in `LocationFilter`
    /// (1.2.2 three-tier `poorResumeAccuracy` gate with 60 s / 120 s
    /// tiers) which was removed in 1.2.9 — empirical data showed the
    /// middle tier fired only in one deadlocked session the 1.2.6
    /// relaxation was then added to escape, and zero times in any
    /// iPhone 13 Pro Max history. A single 25 m accuracy ceiling
    /// (`maxHorizontalAccuracyMeters`) supersedes it.
    static let resumeGapSeconds: TimeInterval = 60

    /// Process-noise acceleration standard deviation (m/s²) for the
    /// 2D constant-velocity Kalman filter applied to accepted fixes.
    /// This is the σ_a parameter in the DWNA model: it models the
    /// unmodelled acceleration a real walker / cyclist / motorist can
    /// produce between samples.
    ///
    /// 2.0 m/s² is chosen as a multi-modal default:
    ///   - walking:  peak ~0.5 m/s² during starts/stops
    ///   - cycling:  peak ~1.5 m/s² on acceleration from stop
    ///   - vehicles: typical-driving peak ~2–3 m/s² (not emergency braking)
    /// Higher σ_a gives a more agile filter (trusts measurements more,
    /// smooths less); lower σ_a gives heavier smoothing at the cost of
    /// lag on real acceleration. The chosen value is biased slightly
    /// toward agility so sharp turns and cyclist starts are not
    /// visibly delayed on the rendered track.
    static let kalmanProcessAccelStdDev: Double = 2.0

    /// Reset the Kalman state whenever the inter-sample gap exceeds
    /// this. After a gap of 10 s the cached velocity estimate is no
    /// longer a useful prior — the user's real motion during the gap
    /// is unknown — so it is safer to anchor fresh on the returning
    /// fix than to predict across the blackout. 10 s comfortably
    /// covers any legitimate delivery latency at our typical ~1 Hz
    /// cadence while catching real signal-loss windows.
    static let kalmanResetGapSeconds: TimeInterval = 10

    /// Initial velocity-axis variance (m²/s²) assigned on the first
    /// fix of a new Kalman window. 100 = σ_v of 10 m/s, which is wide
    /// enough to cover the span from stationary through vehicle speeds
    /// so the filter's velocity estimate adapts quickly from the
    /// zero-initialized prior. Too small would hold the zero prior for
    /// several samples; too large would amplify measurement noise into
    /// a spurious initial velocity.
    static let kalmanInitialVelocityVariance: Double = 100.0

    /// Identifier for the `BGAppRefreshTask` that wakes the app in
    /// background so `SyncService` can drain the local upload queue when
    /// the foreground `Timer` is suspended. Must match an entry in the
    /// `BGTaskSchedulerPermittedIdentifiers` Info.plist array (populated
    /// from `project.yml`) and the argument passed to
    /// `BGTaskScheduler.shared.register(forTaskWithIdentifier:)`. By
    /// convention we prefix with the bundle identifier.
    static let backgroundRefreshTaskId = "com.gpslogger.personal.refresh"

    /// Earliest-begin delay for the next `BGAppRefreshTaskRequest`. iOS
    /// applies an internal floor around 15 min for BGAppRefresh regardless
    /// of what the client requests; anything sooner is silently clamped.
    /// 15 min is a practical compromise — frequent enough that a suspended
    /// phone still ships points within an acceptable window, infrequent
    /// enough to stay inside iOS's energy budget.
    static let backgroundRefreshMinInterval: TimeInterval = 15 * 60

    /// Info.plist key for the optional API key. Populated at build time
    /// from `$(API_KEY)` in the gitignored xcconfig, the same mechanism
    /// used for `API_BASE_URL`. When set, SyncService sends it as a
    /// `Bearer` token on every POST.
    static let apiKeyInfoKey = "API_KEY"

    /// Effective API key. Empty string means unauthenticated (LAN-only use).
    static var apiKey: String {
        if let raw = Bundle.main.object(forInfoDictionaryKey: apiKeyInfoKey) as? String,
           !raw.isEmpty {
            return raw
        }
        return ""
    }

    // MARK: - Wi-Fi-only sync policy

    /// Per-request URLSession timeout. Short enough that a broken backend
    /// doesn't park the radio on for minutes, long enough that a healthy
    /// LAN round-trip completes comfortably.
    static let syncRequestTimeoutSeconds: TimeInterval = 15

    /// Build the `URLSessionConfiguration` used by `SyncService`. This is
    /// the **OS-level** half of the Wi-Fi-only policy — even if a higher
    /// layer misses a check, the system itself will refuse to carry the
    /// traffic. The flags disable:
    ///   - `allowsCellularAccess` — LTE/5G.
    ///   - `allowsExpensiveNetworkAccess` — iOS classes personal hotspot
    ///     and tethered-phone-as-modem as "expensive"; we don't want to
    ///     drain a peer's cellular either.
    ///   - `allowsConstrainedNetworkAccess` — Low Data Mode networks.
    /// Complemented by `NWPathMonitor` pre-checks in `SyncService` so we
    /// don't even create a task when the current path is disallowed.
    static func makeSyncSessionConfiguration() -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.default
        cfg.allowsCellularAccess = false
        cfg.allowsExpensiveNetworkAccess = false
        cfg.allowsConstrainedNetworkAccess = false
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = syncRequestTimeoutSeconds
        cfg.timeoutIntervalForResource = syncRequestTimeoutSeconds
        return cfg
    }

    // MARK: - Auto Wake (significant-location-change kill switch)

    /// UserDefaults key holding the user's Auto Wake preference.
    /// Boolean. Absent / `false` ⇒ the OS-level
    /// `startMonitoringSignificantLocationChanges()` subscription is
    /// **never** registered; iOS cannot relaunch the app from a
    /// terminated state via SLC. `true` ⇒ the subscription is armed
    /// during normal launch flow so iOS can wake the app after a
    /// significant displacement. Default `false` is deliberate: SLC
    /// is an explicit opt-in, not a feature that should run silently.
    static let autoWakeEnabledKey = "autoWakeEnabled"

    /// Effective Auto Wake setting. Read every time we need to decide
    /// whether to arm or disarm the wake subscription, so a runtime
    /// flip via the hidden settings sheet is reflected immediately
    /// without depending on cached property state.
    ///
    /// **Mutation must go through `LocationTracker.setAutoWakeEnabled`.**
    /// That method writes UserDefaults *and* runs the matching
    /// start/stop call on the wake-monitor `CLLocationManager`. Writing
    /// the key directly (e.g. via `defaults write`) only persists the
    /// preference; the OS-level SLC subscription would not change until
    /// the next launch when `LocationTracker.init` reads the value
    /// during `applyAutoWakeSetting()`. The hidden UI never bypasses
    /// the tracker, so this is only a footgun for ad-hoc shell users.
    static var autoWakeEnabled: Bool {
        UserDefaults.standard.bool(forKey: autoWakeEnabledKey)
    }

    // MARK: - Diagnostics

    /// UserDefaults key that gates the `fix_diagnostics` observability
    /// channel (see below).
    static let syncDiagnosticsEnabledKey = "syncDiagnosticsEnabled"

    /// Whether to write raw-fix diagnostic rows to the local SQLite store
    /// **and** upload them to the backend. `false` by default: the channel
    /// existed to tune the 1.2.x filter thresholds, and with tracking
    /// quality now stable it is pure overhead — ~95% of both local writes
    /// and uplink bytes on a typical walk come from this one table.
    ///
    /// Flip at runtime without a rebuild when a new tuning campaign
    /// starts (e.g. cycling / automotive filter work):
    ///     `defaults write com.gpslogger.personal syncDiagnosticsEnabled -bool YES`
    /// …then kill + relaunch so `LocationTracker` and `SyncService` both
    /// pick up the change. Leaves the table definition intact so any rows
    /// written before the flag is flipped off continue to drain normally,
    /// and any rows written while it's on are not lost if the user flips
    /// it off mid-session.
    static var syncDiagnosticsEnabled: Bool {
        UserDefaults.standard.bool(forKey: syncDiagnosticsEnabledKey)
    }
}
