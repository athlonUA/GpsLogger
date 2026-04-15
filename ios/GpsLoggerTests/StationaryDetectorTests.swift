import XCTest
import CoreLocation
@testable import GpsLogger

/// Covers `StationaryDetector`'s state machine end-to-end: Phase A
/// (evaluating whether the user has gone stationary), Phase B (suppressing
/// fixes while inside the cluster), exit via `resumeRadius`, and the
/// negative-age clock-skew guard added in 1.2.1.
final class StationaryDetectorTests: XCTestCase {

    /// Helper: build a `CLLocation` at a given lat/lon/timestamp.
    /// Fields not relevant to the detector (accuracy, speed, etc.) use
    /// harmless non-negative values so the detector never short-circuits
    /// on invalid input.
    private func loc(
        _ lat: Double,
        _ lon: Double,
        t: TimeInterval
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: -1,
            speed: 0.5,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + t)
        )
    }

    // MARK: - Phase A: accept path

    func testFirstFixIsAcceptedAndBecomesCandidate() {
        var d = StationaryDetector()
        let a = loc(50.45, 30.52, t: 0)
        XCTAssertEqual(d.consume(a), .accept)
        XCTAssertNotNil(d.candidateAnchor)
        XCTAssertNil(d.stationaryCenter)
    }

    func testFixInsideRadiusBeforeWindowIsAccepted() {
        // Before the 150 s window has elapsed, fixes inside the
        // stationaryRadius are still forwarded — the user has not yet
        // been classified as stationary.
        var d = StationaryDetector()
        _ = d.consume(loc(50.45, 30.52, t: 0))
        // ~5 m north — well inside the 20 m radius.
        let near = loc(50.4500449, 30.52, t: 5)
        XCTAssertEqual(d.consume(near), .accept)
    }

    func testFixOutsideRadiusResetsCandidate() {
        // A fix outside the stationaryRadius breaks the candidate
        // cluster. The new fix becomes the fresh candidate and the
        // window timer restarts.
        var d = StationaryDetector()
        let a = loc(50.45, 30.52, t: 0)
        _ = d.consume(a)
        let outside = loc(50.451, 30.52, t: 5)  // ~111 m north, way past 20 m
        XCTAssertEqual(d.consume(outside), .accept)
        // The candidate is now the outside fix.
        XCTAssertEqual(d.candidateAnchor?.coordinate.latitude, 50.451)
    }

    // MARK: - Phase A → B: entering stationary mode

    func testSustainedClusterEntersStationary() {
        // Keep fixes inside the cluster for the full window, then one
        // more fix should transition into stationary mode and get
        // suppressed.
        var d = StationaryDetector(windowSeconds: 150)
        _ = d.consume(loc(50.45, 30.52, t: 0))
        // Bunch of fixes within the radius over 120 s — still accepted.
        for t in stride(from: 30.0, through: 120.0, by: 30.0) {
            XCTAssertEqual(d.consume(loc(50.4501, 30.52, t: t)), .accept)
        }
        // At t=160, we are past the 150 s window. The detector now
        // declares stationary and suppresses this fix.
        XCTAssertEqual(d.consume(loc(50.4501, 30.52, t: 160)), .suppress)
        XCTAssertNotNil(d.stationaryCenter)
        XCTAssertNil(d.candidateAnchor)
    }

    // MARK: - Phase B: suppression and exit

    func testStationaryStateSuppressesFixesInsideResumeRadius() {
        // Once stationary, any fix within resumeRadius (30 m) stays
        // suppressed. Only a fix beyond resumeRadius breaks out.
        var d = StationaryDetector(windowSeconds: 150, resumeRadius: 30)
        // Force entry into Phase B.
        _ = d.consume(loc(50.45, 30.52, t: 0))
        for t in stride(from: 30.0, through: 160.0, by: 30.0) {
            _ = d.consume(loc(50.4500, 30.52, t: t))
        }
        XCTAssertNotNil(d.stationaryCenter)

        // ~20 m away — inside resumeRadius. Suppressed.
        XCTAssertEqual(d.consume(loc(50.45018, 30.52, t: 200)), .suppress)
    }

    func testFixBeyondResumeRadiusExitsStationary() {
        // Fix beyond 30 m from the frozen center resumes normal
        // recording. The detector clears stationaryCenter and adopts
        // the new fix as a fresh candidate.
        var d = StationaryDetector(windowSeconds: 150, resumeRadius: 30)
        _ = d.consume(loc(50.45, 30.52, t: 0))
        for t in stride(from: 30.0, through: 160.0, by: 30.0) {
            _ = d.consume(loc(50.4500, 30.52, t: t))
        }
        XCTAssertNotNil(d.stationaryCenter)

        // ~111 m away — well beyond 30 m.
        XCTAssertEqual(d.consume(loc(50.451, 30.52, t: 200)), .accept)
        XCTAssertNil(d.stationaryCenter)
        XCTAssertNotNil(d.candidateAnchor)
    }

    // MARK: - Hysteresis: resume > radius

    func testHysteresisSuppressesBorderlineFixBetweenRadii() {
        // A fix at 25 m — outside stationaryRadius (20 m) but inside
        // resumeRadius (30 m) — while in Phase B stays suppressed. This
        // is the hysteresis behavior: we do not exit stationary mode on
        // a borderline jitter fix.
        var d = StationaryDetector()
        _ = d.consume(loc(50.45, 30.52, t: 0))
        for t in stride(from: 30.0, through: 160.0, by: 30.0) {
            _ = d.consume(loc(50.4500, 30.52, t: t))
        }
        XCTAssertNotNil(d.stationaryCenter)

        // ~25 m north of the frozen center — 50.45022.
        XCTAssertEqual(d.consume(loc(50.45022, 30.52, t: 200)), .suppress)
    }

    // MARK: - Clock skew guard (1.2.1 fix)

    func testNegativeAgeResetsCandidateInsteadOfStalling() {
        // Scenario: the anchor was captured with a future timestamp
        // (NTP correction, DST transition, or a cached-replay fix that
        // landed after a live fix with an older clock value). Before the
        // guard, `age = loc.timestamp - anchor.timestamp` went negative
        // and the `age >= windowSeconds` check never fired, leaving the
        // detector stuck in Phase A forever. The guard resets the
        // candidate to the newer fix so the window restarts cleanly.
        var d = StationaryDetector()
        // Anchor at t=1000 (the "future").
        let future = loc(50.45, 30.52, t: 1000)
        _ = d.consume(future)
        XCTAssertEqual(d.candidateAnchor?.timestamp, future.timestamp)

        // Next fix lands with t=500 — 500 s in the past relative to
        // anchor. Inside the radius, so the old code would hit
        // `age = -500 < windowSeconds` and return .accept forever.
        let pastInsideRadius = loc(50.4501, 30.52, t: 500)
        XCTAssertEqual(d.consume(pastInsideRadius), .accept)
        // The candidate should now be the newer-by-clock fix, so the
        // window restarts from it.
        XCTAssertEqual(d.candidateAnchor?.timestamp, pastInsideRadius.timestamp)
    }

    // MARK: - reset()

    func testResetClearsBothStates() {
        var d = StationaryDetector()
        _ = d.consume(loc(50.45, 30.52, t: 0))
        for t in stride(from: 30.0, through: 160.0, by: 30.0) {
            _ = d.consume(loc(50.4500, 30.52, t: t))
        }
        XCTAssertNotNil(d.stationaryCenter)

        d.reset()
        XCTAssertNil(d.candidateAnchor)
        XCTAssertNil(d.stationaryCenter)

        // Post-reset, the next fix becomes a fresh candidate.
        XCTAssertEqual(d.consume(loc(50.45, 30.52, t: 300)), .accept)
        XCTAssertNotNil(d.candidateAnchor)
    }
}
