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
    /// normal delivery gaps (walking with `distanceFilter = 10`, low
    /// signal, brief backgrounding) while catching any long pause.
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
}
