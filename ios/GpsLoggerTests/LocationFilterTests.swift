import XCTest
import CoreLocation
@testable import GpsLogger

/// Tests for `LocationFilter`. The filter is a pure value type, so every
/// rule can be exercised in isolation by constructing `CLLocation`s with
/// explicit field values.
///
/// The park-canopy anomaly (Wi-Fi-Positioning fallback delivering "teleported"
/// fixes at ~1 Hz) is covered by the `testRejects*NonGpsSource*` group: those
/// cases prove the source gate drops network-derived fixes before they reach
/// the spike buffer or stationary detector, regardless of their reported
/// `horizontalAccuracy`.
final class LocationFilterTests: XCTestCase {

    // MARK: - Validity gate

    func testRejectsFixWithNegativeHorizontalAccuracy() {
        var filter = LocationFilter()
        let fix = makeFix(lat: 0, lon: 0, horizontalAccuracy: -1)
        XCTAssertEqual(filter.consume(fix), .discard(.invalidFix))
    }

    // MARK: - Source gate (park-canopy / WPS fallback defense)

    func testRejectsFixWithNegativeSpeed() {
        // Wi-Fi / cell-tower fallback fixes leave `speed` at -1 because
        // network positioning has no Doppler velocity. This is the primary
        // defense against the park-canopy teleport anomaly.
        var filter = LocationFilter()
        let fix = makeFix(lat: 0, lon: 0, speed: -1)
        XCTAssertEqual(filter.consume(fix), .discard(.nonGpsSource))
    }

    func testRejectsFixWithNegativeVerticalAccuracy() {
        // Wi-Fi / cell fallback fixes report `verticalAccuracy = -1` because
        // network positioning has no altitude.
        var filter = LocationFilter()
        let fix = makeFix(lat: 0, lon: 0, verticalAccuracy: -1)
        XCTAssertEqual(filter.consume(fix), .discard(.nonGpsSource))
    }

    func testRejectsFixWithZeroVerticalAccuracy() {
        // Zero is not a valid altitude uncertainty — real 3D GPS solutions
        // report a positive meters-scale value.
        var filter = LocationFilter()
        let fix = makeFix(lat: 0, lon: 0, verticalAccuracy: 0)
        XCTAssertEqual(filter.consume(fix), .discard(.nonGpsSource))
    }

    func testAcceptsStationaryGpsFix() {
        // A person standing still on GPS reports speed = 0 (not -1) and a
        // positive vertical accuracy. Must not be confused with network fixes.
        var filter = LocationFilter()
        let fix = makeFix(lat: 0, lon: 0, speed: 0)
        guard case .accept = filter.consume(fix) else {
            return XCTFail("stationary GPS fix should be accepted")
        }
    }

    func testSourceGateRunsBeforeAccuracyGate() {
        // A fix with great accuracy but no GPS fields must still be rejected
        // as non-GPS, not mistakenly let through by the accuracy gate.
        var filter = LocationFilter()
        let fix = makeFix(lat: 0, lon: 0, horizontalAccuracy: 5, verticalAccuracy: -1, speed: -1)
        XCTAssertEqual(filter.consume(fix), .discard(.nonGpsSource))
    }

    func testWPSBurstAllDropped() {
        // The park-canopy anomaly: a dense stream of network-derived fixes,
        // each jumping to a different part of the city. After the source
        // gate, zero of them reach the spike buffer; internal filter state
        // stays pinned to the last real GPS fix.
        var filter = LocationFilter()
        let gps = makeFix(lat: 50.450, lon: 30.523, timestamp: date(0))
        guard case .accept = filter.consume(gps) else {
            return XCTFail("initial GPS fix should be accepted")
        }

        let bogusJumps: [(Double, Double)] = [
            (50.500, 30.600),   // far-north
            (50.410, 30.700),   // far-east
            (50.380, 30.480),   // far-south
            (50.445, 30.400),   // far-west, near sea
        ]
        for (i, (lat, lon)) in bogusJumps.enumerated() {
            let wps = makeFix(
                lat: lat,
                lon: lon,
                horizontalAccuracy: 35,   // plausible; would pass accuracy gate
                verticalAccuracy: -1,     // network fallback
                speed: -1,
                timestamp: date(Double(i + 1))
            )
            XCTAssertEqual(filter.consume(wps), .discard(.nonGpsSource))
        }
        // lastAccepted must still be the original real fix.
        XCTAssertEqual(filter.lastAccepted?.coordinate.latitude, 50.450)
        XCTAssertEqual(filter.lastAccepted?.coordinate.longitude, 30.523)
        XCTAssertNil(filter.pending)
    }

    // MARK: - Accuracy value gate

    func testRejectsFixWorseThanMaxAccuracy() {
        var filter = LocationFilter()
        let fix = makeFix(lat: 0, lon: 0, horizontalAccuracy: 80)
        XCTAssertEqual(filter.consume(fix), .discard(.poorAccuracy(meters: 80)))
    }

    // MARK: - Chronology / speed gates

    func testRejectsStaleTimestamp() {
        var filter = LocationFilter()
        let t0 = Date()
        let a = makeFix(lat: 0, lon: 0, timestamp: t0)
        _ = filter.consume(a)
        // Same timestamp → dt == 0 → stale.
        let b = makeFix(lat: 0.001, lon: 0.001, timestamp: t0)
        XCTAssertEqual(filter.consume(b), .discard(.staleTimestamp))
    }

    func testRejectsImplausibleSpeed() {
        // 5 km displacement in 1 s → 18000 km/h. Far above 500 km/h ceiling.
        var filter = LocationFilter()
        let a = makeFix(lat: 0, lon: 0, timestamp: date(0))
        _ = filter.consume(a)
        let b = makeFix(lat: 0.05, lon: 0, timestamp: date(1))
        guard case .discard(.implausibleSpeed) = filter.consume(b) else {
            return XCTFail("teleport should be flagged as implausible speed")
        }
    }

    // MARK: - Distance / spike-buffer regression

    func testRejectsTooClose() {
        var filter = LocationFilter()
        _ = filter.consume(makeFix(lat: 0, lon: 0, timestamp: date(0)))
        // ~0.5 m — well under the 10 m minimum.
        let b = makeFix(lat: 0.000005, lon: 0, timestamp: date(1))
        XCTAssertEqual(filter.consume(b), .discard(.tooClose))
    }

    func testSpikePatternDropsBufferedPoint() {
        // A → B(far jump, > 750 m) → C(back near A). B must be dropped.
        // dt spacing is 10 s so the ~1 km jump implies ~100 m/s (360 km/h),
        // well under the 500 km/h implausible-speed ceiling and therefore
        // reaches the spike buffer branch rather than being rejected upfront.
        var filter = LocationFilter()
        let a = makeFix(lat: 50.4500, lon: 30.5230, timestamp: date(0))
        _ = filter.consume(a)

        // ~1 km east of A.
        let b = makeFix(lat: 50.4500, lon: 30.5370, timestamp: date(10))
        XCTAssertEqual(filter.consume(b), .buffered)

        // Back at A's position.
        let c = makeFix(lat: 50.4500, lon: 30.5230, timestamp: date(20))
        guard case .spikeReplaced(let dropped, _) = filter.consume(c) else {
            return XCTFail("A → B(far) → C(back near A) must trigger spike replacement")
        }
        XCTAssertEqual(dropped.coordinate.longitude, 30.5370)
        XCTAssertNil(filter.pending)
    }

    func testFirstFixAccepted() {
        var filter = LocationFilter()
        let fix = makeFix(lat: 50.45, lon: 30.52)
        guard case .accept(let accepted) = filter.consume(fix) else {
            return XCTFail("first valid fix should be accepted")
        }
        XCTAssertEqual(accepted.coordinate.latitude, 50.45)
    }

    // MARK: - Helpers

    private let baseTime = Date(timeIntervalSince1970: 1_700_000_000)

    private func date(_ offset: TimeInterval) -> Date {
        baseTime.addingTimeInterval(offset)
    }

    /// Default field values describe a healthy 3D GPS fix: positive
    /// accuracies, non-negative speed, a fresh timestamp. Individual tests
    /// override whichever fields they exercise.
    private func makeFix(
        lat: Double,
        lon: Double,
        horizontalAccuracy: CLLocationAccuracy = 5,
        verticalAccuracy: CLLocationAccuracy = 5,
        speed: CLLocationSpeed = 1.0,
        timestamp: Date? = nil
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: 100,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy,
            course: -1,
            speed: speed,
            timestamp: timestamp ?? baseTime
        )
    }
}
