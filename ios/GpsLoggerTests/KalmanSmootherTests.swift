import XCTest
import CoreLocation
@testable import GpsLogger

/// Covers `KalmanSmoother`'s observable contract: first-fix passthrough,
/// noise attenuation under repeated observations, outlier damping via the
/// motion prior, and state reset on long gaps or out-of-order delivery.
///
/// The tests intentionally work in local ENU meters around the equator
/// (latitude 0) so one degree of longitude equals `metersPerDeg` cleanly
/// without cosine scaling, keeping the synthetic trajectories easy to
/// inspect when a case fails.
final class KalmanSmootherTests: XCTestCase {

    /// Earth-radius-based meters-per-degree conversion. Must match the
    /// constant used inside `KalmanSmoother` so round-trip ENU ↔ lat/lon
    /// in the tests produces the same distances the filter sees.
    private let metersPerDeg: Double = 6_371_000.0 * .pi / 180.0

    /// Build a synthetic raw fix with controllable HA. Fields not
    /// relevant to the horizontal filter (vertical accuracy, altitude,
    /// speed) take harmless positive defaults so callers can focus on
    /// the coordinate + timestamp + HA that actually drive behavior.
    private func fix(
        lat: Double,
        lon: Double,
        t: TimeInterval,
        ha: CLLocationAccuracy = 32.0
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: 0,
            horizontalAccuracy: ha,
            verticalAccuracy: 3.0,
            course: -1,
            speed: 1.0,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + t)
        )
    }

    // MARK: - First-fix behavior

    func testFirstFixCoordinatePassesThrough() {
        // The filter has no prior state on the first fix, so it must
        // emit the measurement verbatim (modulo non-coordinate fields,
        // which are covered in a separate test). A sub-nanodegree
        // tolerance guards against accidental degree↔meter round-trip
        // error during initialization.
        var k = KalmanSmoother()
        let raw = fix(lat: 50.45, lon: 30.52, t: 0, ha: 32)
        let out = k.consume(raw)
        XCTAssertEqual(out.coordinate.latitude, raw.coordinate.latitude, accuracy: 1e-9)
        XCTAssertEqual(out.coordinate.longitude, raw.coordinate.longitude, accuracy: 1e-9)
        XCTAssertEqual(out.timestamp, raw.timestamp)
    }

    func testFirstFixNonHorizontalFieldsPreserved() {
        // altitude / verticalAccuracy / speed / course / speedAccuracy /
        // courseAccuracy are not part of the horizontal Kalman state.
        // They must flow through unchanged so downstream consumers keep
        // seeing the chip's reported values.
        var k = KalmanSmoother()
        let raw = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 50.45, longitude: 30.52),
            altitude: 123.0,
            horizontalAccuracy: 16.0,
            verticalAccuracy: 2.5,
            course: 45.0,
            speed: 3.5,
            timestamp: Date()
        )
        let out = k.consume(raw)
        XCTAssertEqual(out.altitude, 123.0)
        XCTAssertEqual(out.verticalAccuracy, 2.5)
        XCTAssertEqual(out.course, 45.0)
        XCTAssertEqual(out.speed, 3.5)
    }

    // MARK: - Noise attenuation

    func testReportedAccuracyImprovesAfterSeveralUpdates() {
        // A stream of co-located fixes with σ=32 m should drive the
        // filter's position variance well below σ² after a handful of
        // updates (position-only measurements collapse uncertainty each
        // step). The reported horizontalAccuracy on the output — which
        // is derived from the post-update covariance — must reflect that.
        var k = KalmanSmoother()
        for t in 0..<5 {
            _ = k.consume(fix(lat: 0, lon: 0, t: TimeInterval(t), ha: 32))
        }
        let out = k.consume(fix(lat: 0, lon: 0, t: 5, ha: 32))
        XCTAssertLessThan(out.horizontalAccuracy, 32.0)
    }

    func testLinearMotionSmoothsZigzag() {
        // True path: due east along y=0 at 1 m/s. Measurements alternate
        // ±10 m in the cross-track direction, simulating the HA=32 m
        // bucket noise observed in the 2026-04-17 logs. The smoothed
        // output should sit much closer to the y=0 true line than the
        // raw input — the motion prior averages the alternating noise
        // across the window.
        var k = KalmanSmoother()
        var rawCrossTrack: [Double] = []
        var smoothedCrossTrack: [Double] = []
        for t in 0..<20 {
            let trueEastMeters = Double(t) * 1.0
            let crossTrackNoise = (t % 2 == 0 ? 1.0 : -1.0) * 10.0
            let raw = fix(
                lat: crossTrackNoise / metersPerDeg,
                lon: trueEastMeters / metersPerDeg, // cos(0) = 1 at equator
                t: TimeInterval(t),
                ha: 32
            )
            let out = k.consume(raw)
            rawCrossTrack.append(abs(raw.coordinate.latitude * metersPerDeg))
            smoothedCrossTrack.append(abs(out.coordinate.latitude * metersPerDeg))
        }
        // Compare the last-10 averages so the warm-up region does not
        // dilute the result. Expect at least a 40 % improvement — the
        // filter is trusted to average ±10 m jitter down to single
        // digits after ~5 samples with σ_a = 2 m/s², σ_m = 32 m.
        let rawAvg = rawCrossTrack.suffix(10).reduce(0, +) / 10.0
        let smoothedAvg = smoothedCrossTrack.suffix(10).reduce(0, +) / 10.0
        XCTAssertLessThan(
            smoothedAvg,
            rawAvg * 0.6,
            "zigzag not smoothed: raw avg=\(rawAvg), smoothed avg=\(smoothedAvg)"
        )
    }

    // MARK: - Outlier damping

    func testSingleSpikeDoesNotFullyPullOutput() {
        // A clean east-walk at 1 m/s with one 50 m cross-track spike on
        // the tenth fix. The filter does not reject the spike (that is
        // upstream in LocationFilter's spike buffer), but the motion
        // prior damps the innovation — the output at the spike step
        // must deviate far less than the raw 50 m.
        var k = KalmanSmoother()
        var samples: [CLLocation] = []
        for t in 0..<9 {
            samples.append(fix(
                lat: 0,
                lon: Double(t) / metersPerDeg,
                t: TimeInterval(t),
                ha: 16
            ))
        }
        samples.append(fix(
            lat: 50.0 / metersPerDeg,
            lon: 9.0 / metersPerDeg,
            t: 9,
            ha: 16
        ))
        for t in 10..<19 {
            samples.append(fix(
                lat: 0,
                lon: Double(t) / metersPerDeg,
                t: TimeInterval(t),
                ha: 16
            ))
        }
        var outs: [CLLocation] = []
        for s in samples { outs.append(k.consume(s)) }

        let spikeDeviation = abs(outs[9].coordinate.latitude * metersPerDeg)
        XCTAssertLessThan(
            spikeDeviation,
            30.0,
            "spike pulled smoothed output by \(spikeDeviation) m out of 50 m"
        )
    }

    // MARK: - State reset

    func testLongGapResetsFilterState() {
        // Feed several fixes so the filter accumulates a velocity
        // estimate, then pause beyond resetGapSeconds. The post-gap fix
        // must be treated as a fresh first-fix — without reset, the KF
        // would project the stale velocity across the gap and output a
        // coordinate near the *predicted* position, not the actual one.
        var k = KalmanSmoother(resetGapSeconds: 10)
        for t in 0..<5 {
            _ = k.consume(fix(
                lat: 0,
                lon: Double(t) / metersPerDeg,
                t: TimeInterval(t),
                ha: 16
            ))
        }
        // 30 s gap, fix 100 m north of the last known position.
        let afterGap = fix(lat: 100.0 / metersPerDeg, lon: 0, t: 35, ha: 16)
        let out = k.consume(afterGap)
        XCTAssertEqual(
            out.coordinate.latitude,
            afterGap.coordinate.latitude,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            out.coordinate.longitude,
            afterGap.coordinate.longitude,
            accuracy: 1e-9
        )
    }

    func testOutOfOrderTimestampResetsState() {
        // CLLocationManager is documented to deliver ascending
        // timestamps, but cached-replay fixes after a signal gap can
        // violate that order. `dt ≤ 0` would otherwise divide by zero
        // or propagate state backwards in time; the filter must reset.
        var k = KalmanSmoother()
        _ = k.consume(fix(lat: 0, lon: 0, t: 100, ha: 16))
        let backwards = fix(lat: 10.0 / metersPerDeg, lon: 20.0 / metersPerDeg, t: 50, ha: 16)
        let out = k.consume(backwards)
        XCTAssertEqual(
            out.coordinate.latitude,
            backwards.coordinate.latitude,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            out.coordinate.longitude,
            backwards.coordinate.longitude,
            accuracy: 1e-9
        )
    }

    func testResetClearsAllState() {
        var k = KalmanSmoother()
        _ = k.consume(fix(lat: 0, lon: 0, t: 0, ha: 16))
        _ = k.consume(fix(lat: 0, lon: 1.0 / metersPerDeg, t: 1, ha: 16))
        k.reset()
        // Post-reset, the next fix must pass through as a fresh first-fix.
        let fresh = fix(lat: 50, lon: 30, t: 100, ha: 16)
        let out = k.consume(fresh)
        XCTAssertEqual(
            out.coordinate.latitude,
            fresh.coordinate.latitude,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            out.coordinate.longitude,
            fresh.coordinate.longitude,
            accuracy: 1e-9
        )
    }

    // MARK: - ENU round-trip

    func testENURoundTripPreservesCoordinates() {
        // Sanity: the ENU forward + inverse mapping is self-consistent
        // to sub-meter tolerance at city scale. If this ever drifts, the
        // filter's output coordinates would silently shift even when the
        // Kalman state vector is mathematically correct.
        let origin = CLLocationCoordinate2D(latitude: 39.4847, longitude: -0.3830)
        let probe = CLLocationCoordinate2D(latitude: 39.4860, longitude: -0.3810)
        let (x, y) = KalmanSmoother.enuOffset(origin: origin, coord: probe)
        let back = KalmanSmoother.latLonFromENU(origin: origin, x: x, y: y)
        XCTAssertEqual(back.latitude, probe.latitude, accuracy: 1e-9)
        XCTAssertEqual(back.longitude, probe.longitude, accuracy: 1e-9)
    }
}
