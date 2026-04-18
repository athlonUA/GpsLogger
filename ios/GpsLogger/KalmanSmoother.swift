import Foundation
import CoreLocation

/// 2D constant-velocity Kalman filter over the accepted-fix stream.
///
/// Layered between `LocationFilter.accept` and `StationaryDetector.consume`,
/// so outlier rejection has already run by the time the smoother sees a
/// sample, and stationary decisions read post-smoothing coordinates. The
/// goal is purely cosmetic-but-measurable: at HA=32 m in partial-sky
/// conditions the bare chip output scatters by ±30 m around the true
/// position, producing visible zigzag on the map. Averaging consecutive
/// samples through a constant-velocity motion prior reduces per-sample
/// position variance roughly by √N across the sliding smoothing window
/// without distorting sharp turns the way a coordinate-space moving
/// average would.
///
/// State vector: `[x, y, vx, vy]` in meters / m·s⁻¹, expressed in a local
/// East-North-Up frame anchored at the first accepted fix (`origin`).
/// Working in local meters sidesteps the lat/cos-scaling arithmetic traps
/// of filtering in degrees and makes the process-noise covariance Q a
/// plain function of an acceleration standard deviation in SI units.
///
/// Motion model: constant velocity with discrete white-noise acceleration
/// (DWNA). Q is parameterized by `processAccelStdDev`, modelling the
/// unmodelled acceleration a real walker / cyclist / motorist can produce
/// between samples. The chosen default (~1 m/s²) is a conservative
/// multi-modal compromise: low enough to smooth HA-bucket quantization
/// noise on a steady walk, high enough that sharp turns and cyclist
/// starts/stops do not produce visible phase lag.
///
/// Measurement model: position only. The filter intentionally ignores
/// `CLLocation.speed` and `.course` — they are useful but noisy at low
/// speeds, and fusing them would require separate variance tuning per
/// transport mode. Velocity is retained implicitly through successive
/// position observations. Measurement noise R uses CLLocation's reported
/// `horizontalAccuracy` directly as σ — Apple's own quality estimate,
/// which the filter trusts as-is.
///
/// Reset policy:
///   - First fix: initialize state to the measurement, velocity to zero,
///     position covariance to σ²_m, velocity covariance to a conservative
///     large value so the first few updates can adapt quickly.
///   - `dt > resetGapSeconds`: re-initialize. After a long gap the
///     cached velocity estimate is meaningless (we have no evidence of
///     what the user did during the gap), so it is safer to anchor fresh
///     than to predict across minutes of unknown movement.
///   - `dt ≤ 0`: re-initialize defensively (out-of-order delivery should
///     have been caught upstream, but the filter must not divide by zero
///     or accumulate backwards in time).
///
/// Output `CLLocation`:
///   - `coordinate` = filtered lat/lon (converted back from ENU meters)
///   - `timestamp` = identical to input
///   - `altitude`, `verticalAccuracy`, `speed`, `course`, `speedAccuracy`,
///     `courseAccuracy` copied from input unchanged. These are not part
///     of the horizontal Kalman state; distorting them would desync them
///     from what the chip actually reported without providing any
///     horizontal quality benefit.
///   - `horizontalAccuracy` = RMS of the post-update position covariance
///     diagonal, so downstream consumers that reason about accuracy see
///     an honest improved quality estimate. After a few updates this is
///     strictly ≤ the input σ.
struct KalmanSmoother {
    /// ENU-frame origin, anchored at the first accepted fix (or the first
    /// fix after a reset). Remains fixed for the lifetime of one
    /// non-reset window so the local x/y math is self-consistent.
    private var origin: CLLocationCoordinate2D?
    /// Cached `cos(origin.latitude · π/180)`. `origin` is by contract
    /// constant across a non-reset window, so its cosine is too; caching
    /// here eliminates two `cos` calls per `consume` (ENU forward +
    /// inverse) without changing numerical behaviour. Set at reset time;
    /// read by `enuOffset` / `latLonFromENU`.
    private var originCosLat: Double = 1.0
    /// Timestamp of the last processed fix. Used for `dt` and the gap
    /// reset rule.
    private var lastTimestamp: Date?
    /// 4-element state vector `[x, y, vx, vy]`, flat layout.
    private var state: [Double] = [0, 0, 0, 0]
    /// 4×4 covariance matrix, row-major.
    private var covariance: [[Double]] = Self.identity(4)

    private let processAccelStdDev: Double
    private let resetGapSeconds: TimeInterval
    private let initialVelocityVariance: Double

    init(
        processAccelStdDev: Double = Config.kalmanProcessAccelStdDev,
        resetGapSeconds: TimeInterval = Config.kalmanResetGapSeconds,
        initialVelocityVariance: Double = Config.kalmanInitialVelocityVariance
    ) {
        self.processAccelStdDev = processAccelStdDev
        self.resetGapSeconds = resetGapSeconds
        self.initialVelocityVariance = initialVelocityVariance
    }

    mutating func reset() {
        origin = nil
        originCosLat = 1.0
        lastTimestamp = nil
        state = [0, 0, 0, 0]
        covariance = Self.identity(4)
    }

    /// Feed an accepted fix; returns the smoothed fix to persist.
    mutating func consume(_ loc: CLLocation) -> CLLocation {
        // `horizontalAccuracy` is CLLocation's 1-σ estimate. Clamp away
        // from zero so a chip reporting sub-meter accuracy does not
        // produce a singular measurement matrix (R = 0 → divide-by-zero
        // in the innovation covariance). 1 m is a reasonable floor; real
        // smartphone GNSS does not legitimately produce tighter fixes.
        let sigmaMeters = max(loc.horizontalAccuracy, 1.0)

        // Gap check must come before the first-fix branch: if the
        // previous state is stale beyond `resetGapSeconds`, we want to
        // fall through into initialization regardless of whether an
        // origin is already set.
        if let lastT = lastTimestamp {
            let dt = loc.timestamp.timeIntervalSince(lastT)
            if dt > resetGapSeconds || dt <= 0 {
                reset()
            }
        }

        // First fix (or first after reset): initialize state at the
        // measurement with zero velocity. Position covariance is the
        // measurement's own σ²; velocity covariance is intentionally
        // large so the first few updates can adapt quickly (low gain on
        // velocity would "hold" the zero prior for too long).
        guard let anchor = origin else {
            origin = loc.coordinate
            originCosLat = cos(loc.coordinate.latitude * .pi / 180.0)
            lastTimestamp = loc.timestamp
            state = [0, 0, 0, 0]
            covariance = [
                [sigmaMeters * sigmaMeters, 0, 0, 0],
                [0, sigmaMeters * sigmaMeters, 0, 0],
                [0, 0, initialVelocityVariance, 0],
                [0, 0, 0, initialVelocityVariance],
            ]
            return makeOutput(loc: loc, x: 0, y: 0, posVariance: sigmaMeters * sigmaMeters)
        }

        // `lastTimestamp` is guaranteed non-nil here because `origin` is
        // set: the two are written together at initialization and in
        // `reset`. Force-unwrap would be equally safe; this form keeps
        // the control flow linear.
        let lastT = lastTimestamp ?? loc.timestamp
        let dt = loc.timestamp.timeIntervalSince(lastT)

        let (measX, measY) = Self.enuOffset(
            origin: anchor,
            cosLat: originCosLat,
            coord: loc.coordinate
        )

        // ---- Predict ----
        // x_pred = F x
        let xPred: [Double] = [
            state[0] + state[2] * dt,
            state[1] + state[3] * dt,
            state[2],
            state[3],
        ]
        // P_pred = F P F^T + Q
        let F = Self.stateTransition(dt: dt)
        let pPred = Self.add(
            Self.mul(F, Self.mul(covariance, Self.transpose(F))),
            processNoise(dt: dt)
        )

        // ---- Update ----
        // Innovation y = z - H x_pred, where H picks the first two
        // state components (position).
        let innovX = measX - xPred[0]
        let innovY = measY - xPred[1]

        // S = H P_pred H^T + R. Since H selects rows 0 and 1, S is the
        // top-left 2×2 block of P_pred plus the diagonal R.
        let measVar = sigmaMeters * sigmaMeters
        let s00 = pPred[0][0] + measVar
        let s01 = pPred[0][1]
        let s10 = pPred[1][0]
        let s11 = pPred[1][1] + measVar
        let det = s00 * s11 - s01 * s10

        // Kalman gain K = P_pred H^T S^{-1}. P_pred H^T is the first two
        // columns of P_pred (a 4×2 matrix). Inlining avoids allocating
        // intermediate matrices for a tight hot path.
        let sInv00 = s11 / det
        let sInv01 = -s01 / det
        let sInv10 = -s10 / det
        let sInv11 = s00 / det
        var gain = [[Double]](repeating: [0, 0], count: 4)
        for i in 0..<4 {
            gain[i][0] = pPred[i][0] * sInv00 + pPred[i][1] * sInv10
            gain[i][1] = pPred[i][0] * sInv01 + pPred[i][1] * sInv11
        }

        // x_new = x_pred + K y
        var xNew = xPred
        for i in 0..<4 {
            xNew[i] += gain[i][0] * innovX + gain[i][1] * innovY
        }

        // P_new = (I - K H) P_pred. K H has only columns 0 and 1 populated,
        // so (I - K H) P_pred[i][j] = P_pred[i][j] - gain[i][0]·P_pred[0][j]
        //                                         - gain[i][1]·P_pred[1][j].
        var pNew = pPred
        for i in 0..<4 {
            for j in 0..<4 {
                pNew[i][j] = pPred[i][j]
                    - gain[i][0] * pPred[0][j]
                    - gain[i][1] * pPred[1][j]
            }
        }

        state = xNew
        covariance = pNew
        lastTimestamp = loc.timestamp

        // RMS of the position-variance diagonal is a fair scalar summary
        // of the post-update 2D uncertainty. After a few updates it is
        // strictly smaller than the input measurement variance — which
        // is the whole point of running the filter.
        let posVariance = (pNew[0][0] + pNew[1][1]) / 2.0
        return makeOutput(loc: loc, x: xNew[0], y: xNew[1], posVariance: posVariance)
    }

    // MARK: - Output construction

    /// Rebuild a `CLLocation` at filtered ENU coordinates, preserving
    /// the non-horizontal fields from the raw input.
    private func makeOutput(
        loc: CLLocation,
        x: Double,
        y: Double,
        posVariance: Double
    ) -> CLLocation {
        guard let anchor = origin else { return loc }
        let smoothed = Self.latLonFromENU(
            origin: anchor,
            cosLat: originCosLat,
            x: x,
            y: y
        )
        let smoothedAccuracy = sqrt(max(posVariance, 0))
        return CLLocation(
            coordinate: smoothed,
            altitude: loc.altitude,
            horizontalAccuracy: smoothedAccuracy,
            verticalAccuracy: loc.verticalAccuracy,
            course: loc.course,
            courseAccuracy: loc.courseAccuracy,
            speed: loc.speed,
            speedAccuracy: loc.speedAccuracy,
            timestamp: loc.timestamp
        )
    }

    // MARK: - Matrices

    /// State-transition matrix F for a 2D constant-velocity model over
    /// time step `dt`. Position is advanced by velocity·dt; velocity is
    /// assumed unchanged (any real acceleration flows into process noise).
    private static func stateTransition(dt: Double) -> [[Double]] {
        [
            [1, 0, dt, 0],
            [0, 1, 0, dt],
            [0, 0, 1,  0],
            [0, 0, 0,  1],
        ]
    }

    /// Process-noise covariance Q for the DWNA constant-velocity model.
    /// Derivation: integrating continuous white acceleration of variance
    /// σ_a² over `dt` yields a block-diagonal Q with position variance
    /// σ_a²·dt⁴/4, velocity variance σ_a²·dt², and position-velocity
    /// cross-covariance σ_a²·dt³/2 in both x and y axes.
    private func processNoise(dt: Double) -> [[Double]] {
        let sa2 = processAccelStdDev * processAccelStdDev
        let dt2 = dt * dt
        let dt3 = dt2 * dt
        let dt4 = dt3 * dt
        return [
            [sa2 * dt4 / 4, 0,              sa2 * dt3 / 2, 0],
            [0,             sa2 * dt4 / 4,  0,             sa2 * dt3 / 2],
            [sa2 * dt3 / 2, 0,              sa2 * dt2,     0],
            [0,             sa2 * dt3 / 2,  0,             sa2 * dt2],
        ]
    }

    private static func identity(_ n: Int) -> [[Double]] {
        var m = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n { m[i][i] = 1 }
        return m
    }

    private static func transpose(_ m: [[Double]]) -> [[Double]] {
        let n = m.count
        var out = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n {
                out[j][i] = m[i][j]
            }
        }
        return out
    }

    private static func mul(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        let n = a.count
        var out = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n {
                var s = 0.0
                for k in 0..<n { s += a[i][k] * b[k][j] }
                out[i][j] = s
            }
        }
        return out
    }

    private static func add(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        let n = a.count
        var out = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n { out[i][j] = a[i][j] + b[i][j] }
        }
        return out
    }

    // MARK: - ENU conversion

    /// Earth-radius-based degrees→meters conversion. Accurate enough for
    /// the local ENU frame used between resets (sub-meter error across
    /// any plausible intra-session span — typically a few kilometers).
    private static let metersPerDegreeLat: Double = 6_371_000.0 * .pi / 180.0

    /// Local east/north offsets (meters) from `origin` to `coord`. The
    /// longitude-axis scaling uses `cos(origin.latitude)` — this is the
    /// standard equirectangular approximation and introduces negligible
    /// error within one session. Convenience overload; the hot path
    /// (`consume`) uses `cosLat`-taking variant below to avoid re-
    /// computing the cosine on every call.
    static func enuOffset(
        origin: CLLocationCoordinate2D,
        coord: CLLocationCoordinate2D
    ) -> (x: Double, y: Double) {
        enuOffset(
            origin: origin,
            cosLat: cos(origin.latitude * .pi / 180.0),
            coord: coord
        )
    }

    /// Hot-path variant of `enuOffset` that accepts a precomputed
    /// `cos(origin.latitude · π/180)`. `origin` is constant across a
    /// non-reset Kalman window so caching the cosine saves one
    /// trigonometric call per `consume` (1.2.9, R8 from the audit).
    static func enuOffset(
        origin: CLLocationCoordinate2D,
        cosLat: Double,
        coord: CLLocationCoordinate2D
    ) -> (x: Double, y: Double) {
        let dx = (coord.longitude - origin.longitude) * metersPerDegreeLat * cosLat
        let dy = (coord.latitude - origin.latitude) * metersPerDegreeLat
        return (dx, dy)
    }

    /// Inverse of `enuOffset`: recover lat/lon from ENU meters around
    /// `origin`. Kept symmetric with the forward mapping so round-trip
    /// identity holds to the same sub-meter tolerance. Convenience
    /// overload; hot path uses the `cosLat`-taking variant below.
    static func latLonFromENU(
        origin: CLLocationCoordinate2D,
        x: Double,
        y: Double
    ) -> CLLocationCoordinate2D {
        latLonFromENU(
            origin: origin,
            cosLat: cos(origin.latitude * .pi / 180.0),
            x: x,
            y: y
        )
    }

    /// Hot-path variant of `latLonFromENU` that accepts a precomputed
    /// `cos(origin.latitude · π/180)`.
    static func latLonFromENU(
        origin: CLLocationCoordinate2D,
        cosLat: Double,
        x: Double,
        y: Double
    ) -> CLLocationCoordinate2D {
        let lat = origin.latitude + y / metersPerDegreeLat
        let lon = origin.longitude + x / (metersPerDegreeLat * cosLat)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
