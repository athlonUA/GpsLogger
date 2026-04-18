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
        XCTAssertEqual(feed(&filter,fix), .discard(.invalidFix))
    }

    // MARK: - Source gate (park-canopy / WPS fallback defense)

    func testRejectsFixWithNegativeSpeed() {
        // Wi-Fi / cell-tower fallback fixes leave `speed` at -1 because
        // network positioning has no Doppler velocity. This is the primary
        // defense against the park-canopy teleport anomaly.
        var filter = LocationFilter()
        let fix = makeFix(lat: 0, lon: 0, speed: -1)
        XCTAssertEqual(feed(&filter,fix), .discard(.nonGpsSource))
    }

    func testRejectsFixWithNegativeVerticalAccuracy() {
        // Wi-Fi / cell fallback fixes report `verticalAccuracy = -1` because
        // network positioning has no altitude.
        var filter = LocationFilter()
        let fix = makeFix(lat: 0, lon: 0, verticalAccuracy: -1)
        XCTAssertEqual(feed(&filter,fix), .discard(.nonGpsSource))
    }

    func testRejectsFixWithZeroVerticalAccuracy() {
        // Zero is not a valid altitude uncertainty — real 3D GPS solutions
        // report a positive meters-scale value.
        var filter = LocationFilter()
        let fix = makeFix(lat: 0, lon: 0, verticalAccuracy: 0)
        XCTAssertEqual(feed(&filter,fix), .discard(.nonGpsSource))
    }

    func testAcceptsStationaryGpsFix() {
        // A person standing still on GPS reports speed = 0 (not -1) and a
        // positive vertical accuracy. Must not be confused with network fixes.
        var filter = LocationFilter()
        let fix = makeFix(lat: 0, lon: 0, speed: 0)
        guard case .accept = feed(&filter,fix) else {
            return XCTFail("stationary GPS fix should be accepted")
        }
    }

    func testSourceGateRunsBeforeAccuracyGate() {
        // A fix with great accuracy but no GPS fields must still be rejected
        // as non-GPS, not mistakenly let through by the accuracy gate.
        var filter = LocationFilter()
        let fix = makeFix(lat: 0, lon: 0, horizontalAccuracy: 5, verticalAccuracy: -1, speed: -1)
        XCTAssertEqual(feed(&filter,fix), .discard(.nonGpsSource))
    }

    func testWPSBurstAllDropped() {
        // The park-canopy anomaly: a dense stream of network-derived fixes,
        // each jumping to a different part of the city. After the source
        // gate, zero of them reach the spike buffer; internal filter state
        // stays pinned to the last real GPS fix.
        var filter = LocationFilter()
        let gps = makeFix(lat: 50.450, lon: 30.523, timestamp: date(0))
        guard case .accept = feed(&filter,gps) else {
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
            XCTAssertEqual(feed(&filter,wps), .discard(.nonGpsSource))
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
        XCTAssertEqual(feed(&filter,fix), .discard(.poorAccuracy(meters: 80)))
    }

    // MARK: - Chronology / speed gates

    func testRejectsStaleTimestamp() {
        var filter = LocationFilter()
        let t0 = Date()
        let a = makeFix(lat: 0, lon: 0, timestamp: t0)
        _ = feed(&filter,a)
        // Same timestamp → dt == 0 → stale.
        let b = makeFix(lat: 0.001, lon: 0.001, timestamp: t0)
        XCTAssertEqual(feed(&filter,b), .discard(.staleTimestamp))
    }

    func testRejectsImplausibleSpeed() {
        // 5 km displacement in 1 s → 18000 km/h. Far above 500 km/h ceiling.
        var filter = LocationFilter()
        let a = makeFix(lat: 0, lon: 0, timestamp: date(0))
        _ = feed(&filter,a)
        let b = makeFix(lat: 0.05, lon: 0, timestamp: date(1))
        guard case .discard(.implausibleSpeed) = feed(&filter,b) else {
            return XCTFail("teleport should be flagged as implausible speed")
        }
    }

    // MARK: - Distance / spike-buffer regression

    func testRejectsTooClose() {
        var filter = LocationFilter()
        _ = feed(&filter,makeFix(lat: 0, lon: 0, timestamp: date(0)))
        // ~0.5 m — well under the 10 m minimum.
        let b = makeFix(lat: 0.000005, lon: 0, timestamp: date(1))
        XCTAssertEqual(feed(&filter,b), .discard(.tooClose))
    }

    func testSpikePatternDropsBufferedPoint() {
        // A → B(far jump, > 750 m) → C(back near A). B must be dropped.
        // dt spacing is 10 s so the ~1 km jump implies ~100 m/s (360 km/h),
        // well under the 500 km/h implausible-speed ceiling and therefore
        // reaches the spike buffer branch rather than being rejected upfront.
        var filter = LocationFilter()
        let a = makeFix(lat: 50.4500, lon: 30.5230, timestamp: date(0))
        _ = feed(&filter,a)

        // ~1 km east of A.
        let b = makeFix(lat: 50.4500, lon: 30.5370, timestamp: date(10))
        XCTAssertEqual(feed(&filter,b), .buffered)

        // Back at A's position.
        let c = makeFix(lat: 50.4500, lon: 30.5230, timestamp: date(20))
        guard case .spikeReplaced(let dropped, _) = feed(&filter,c) else {
            return XCTFail("A → B(far) → C(back near A) must trigger spike replacement")
        }
        XCTAssertEqual(dropped.coordinate.longitude, 30.5370)
        XCTAssertNil(filter.pending)
    }

    func testFirstFixAccepted() {
        var filter = LocationFilter()
        let fix = makeFix(lat: 50.45, lon: 30.52)
        guard case .accept(let accepted) = feed(&filter,fix) else {
            return XCTFail("first valid fix should be accepted")
        }
        XCTAssertEqual(accepted.coordinate.latitude, 50.45)
    }

    // MARK: - Pending timeout

    func testStalePendingDroppedAfterTimeout() {
        // A buffered spike waiting for confirmation must age out if the
        // next fix arrives much later than the expected sample interval
        // (app was backgrounded, CoreLocation stalled, etc.). Otherwise
        // the A→B→C temporal pattern is broken and the filter would
        // wrongly treat the next arbitrary fix as a spike confirmation.
        var filter = LocationFilter(pendingTimeout: 30)

        // A at t=0.
        let a = makeFix(lat: 50.4500, lon: 30.5230, timestamp: date(0))
        _ = feed(&filter,a)

        // B at t=10, ~1 km east — buffered as spike candidate.
        let b = makeFix(lat: 50.4500, lon: 30.5370, timestamp: date(10))
        XCTAssertEqual(feed(&filter,b), .buffered)
        XCTAssertNotNil(filter.pending)

        // C arrives 100 s later (far beyond the 30 s pendingTimeout). The
        // filter should have dropped the stale pending before evaluating
        // C. From C's perspective, only A is still the anchor.
        // Use a small displacement from A so C doesn't trip the spike
        // jump threshold itself — this way we're testing the pending
        // cleanup in isolation, not the new-spike path.
        let c = makeFix(lat: 50.4501, lon: 30.5232, timestamp: date(110))
        let decision = feed(&filter,c)
        // pending must be nil after consume; C is accepted as normal
        // progression from A (distance ~13 m, above minDistance = 10 m).
        XCTAssertNil(filter.pending, "stale pending must be dropped before evaluating the next fix")
        guard case .accept = decision else {
            return XCTFail("C should be accepted against A (not via spike logic) after pending aged out, got \(decision)")
        }
    }

    func testFreshPendingKeptWithinTimeout() {
        // Sanity check: pending that arrives within the timeout window
        // is retained and the normal spike logic runs.
        var filter = LocationFilter(pendingTimeout: 30)
        _ = feed(&filter,makeFix(lat: 50.4500, lon: 30.5230, timestamp: date(0)))

        // B ~1 km east, buffered.
        _ = feed(&filter,makeFix(lat: 50.4500, lon: 30.5370, timestamp: date(10)))
        XCTAssertNotNil(filter.pending)

        // C arrives at t=20, only 10 s after B — well under the 30 s
        // timeout. Pending must still be there when C is processed.
        // C is back near A, forming the classic spike pattern.
        let c = makeFix(lat: 50.4500, lon: 30.5230, timestamp: date(20))
        let decision = feed(&filter,c)
        guard case .spikeReplaced = decision else {
            return XCTFail("fresh A→B→C pattern must still produce spikeReplaced, got \(decision)")
        }
    }

    // MARK: - Stale-delivery gate

    func testRejectsStaleDeliveredFix() {
        // A fix whose timestamp is > maxFixAge behind wall-clock time is a
        // cached replay from a previous signal window. Must be rejected
        // before any other gate runs.
        var filter = LocationFilter()
        let fix = makeFix(lat: 50.45, lon: 30.52, timestamp: date(0))
        XCTAssertEqual(
            filter.consume(fix, now: date(15)),   // 15 s delivery age > 10 s
            .discard(.staleDelivery)
        )
    }

    func testAcceptsFixWithinAgeThreshold() {
        var filter = LocationFilter()
        let fix = makeFix(lat: 50.45, lon: 30.52, timestamp: date(0))
        // 2 s delivery latency — well under the 10 s ceiling.
        guard case .accept = filter.consume(fix, now: date(2)) else {
            return XCTFail("fix within age threshold should be accepted")
        }
    }

    func testStaleDeliveryGateRunsBeforeOtherGates() {
        // A fix that would pass every other gate (valid GNSS, good accuracy,
        // healthy speed) but has a stale delivery timestamp must be rejected
        // as staleDelivery, not accepted or caught by a later gate.
        var filter = LocationFilter()
        let fix = makeFix(lat: 50.45, lon: 30.52, horizontalAccuracy: 5,
                          timestamp: date(0))
        XCTAssertEqual(
            filter.consume(fix, now: date(15)),
            .discard(.staleDelivery)
        )
    }

    func testRejectsFutureTimestampedFix() {
        // Symmetric case (audit fix F3): if the fix's timestamp is
        // `maxFixAgeSeconds` or more *ahead* of wall-clock time — which
        // happens when the system clock jumps backward (manual time
        // change, NTP correction, daylight-saving edge case) — the gate
        // must reject it. Otherwise the anchor we already hold and the
        // new fix would be on different timelines, producing a negative
        // `dt` on the chronology gate or, worse, a negative age in the
        // stationary-detector Phase A window.
        var filter = LocationFilter()
        let fix = makeFix(lat: 50.45, lon: 30.52, timestamp: date(15))
        XCTAssertEqual(
            filter.consume(fix, now: date(0)),   // now is 15 s behind fix
            .discard(.staleDelivery)
        )
    }

    // MARK: - Automotive spike-jump threshold (1.2.9)

    func testAutomotiveModeWidensSpikeJumpThreshold() {
        // Pedestrian default is 250 m; `setAutomotive(true)` widens it
        // to 750 m so a car at 130 km/h (≈ 180 m per 5 s) does not trip
        // the gate on its own legitimate displacement. Same A → B → C
        // pattern, but B is 500 m away: caught as a spike under walking,
        // accepted as real motion under automotive.
        var walking = LocationFilter()
        var driving = LocationFilter()
        driving.setAutomotive(true)
        let a = makeFix(lat: 50.4500, lon: 30.5230, timestamp: date(0))
        feed(&walking, a)
        feed(&driving, a)
        // B is ~500 m east of A.
        let b = makeFix(lat: 50.4500, lon: 30.5300, timestamp: date(5))
        // Walking path: B is suspicious and gets buffered.
        XCTAssertEqual(walking.consume(b, now: date(5.5)), .buffered)
        // Automotive path: B is within the wider envelope and goes
        // straight through as a normal accept.
        guard case .accept = driving.consume(b, now: date(5.5)) else {
            return XCTFail("500 m jump should be accepted under automotive threshold")
        }
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

    /// Feed a fix with `now` auto-set to 0.5 s after the fix's own
    /// timestamp, keeping the stale-delivery gate out of the way for
    /// tests that target other gates.
    @discardableResult
    private func feed(
        _ filter: inout LocationFilter,
        _ loc: CLLocation
    ) -> LocationFilter.Decision {
        filter.consume(loc, now: loc.timestamp.addingTimeInterval(0.5))
    }
}
