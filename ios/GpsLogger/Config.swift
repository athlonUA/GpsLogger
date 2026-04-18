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
    /// accuracy is worse than this. 50 m is a practical ceiling — indoor /
    /// urban-canyon fixes worse than this are almost always unusable, while
    /// legitimate outdoor fixes are normally well under 30 m. This single
    /// rule is the most reliable defense against GPS noise and is
    /// movement-type agnostic (works identically for walking, driving, trains).
    static let maxHorizontalAccuracyMeters: CLLocationDistance = 50

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

    /// A new point farther than this from the last accepted point is treated
    /// as *suspicious* and held back one tick, waiting for the next fix to
    /// confirm or reject it (A → B → C spike pattern, see `LocationFilter`).
    ///
    /// Intentionally sized so normal movement **never** triggers buffering,
    /// including high-speed rail:
    ///   - 350 km/h ≈ 97 m/s → 5 s sample delta ≈ 485 m (< 750 m)
    ///   - 130 km/h ≈ 36 m/s → 5 s sample delta ≈ 180 m (< 750 m)
    /// Only genuine teleports (several hundred meters into an unrelated
    /// street, with no real motion to explain them) cross this threshold.
    static let spikeJumpMeters: CLLocationDistance = 750

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

    /// After a gap longer than this between accepted fixes, the accuracy
    /// threshold tightens to `resumeMaxAccuracyMeters`. 60 s covers normal
    /// sample intervals; longer gaps indicate signal loss (indoor, background,
    /// tunnel) where the first returning fixes are disproportionately likely
    /// to be multipath-degraded.
    static let resumeGapSeconds: TimeInterval = 60

    /// Tighter accuracy ceiling applied to the first fix after a gap exceeding
    /// `resumeGapSeconds`. 20 m is achievable for outdoor GNSS within 5–15 s
    /// of reacquisition, filtering the worst multipath convergence fixes.
    static let resumeMaxAccuracyMeters: CLLocationDistance = 20

    /// Deadlock-escape threshold for the gap-aware accuracy gate. The gate
    /// tightens from 50 m to 20 m once `dt > resumeGapSeconds`, which is the
    /// correct defense against multipath convergence after a short indoor /
    /// tunnel gap. Under *sustained* marginal signal, the gate was observed in
    /// production (v1.2.5, 2026-04-16 session) to self-reinforce: every
    /// rejection pushed `dt` further, every new fix still landed in the
    /// 20–50 m band, and the gate never released — producing a 17-minute
    /// accepted-fix blackout despite the chip delivering one CLLocation
    /// sample every ~5 s.
    ///
    /// This constant bounds the worst case. Once `dt` exceeds it, the gate
    /// falls back to the normal 50 m ceiling so at least some movement data
    /// is recorded. 120 s is large enough to still filter the vast majority
    /// of real post-indoor multipath (which typically converges in 30–90 s)
    /// yet small enough that a user who keeps walking through marginal
    /// signal will see fixes reappear within two minutes, not seventeen.
    static let resumeRelaxSeconds: TimeInterval = 120

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
}
