import XCTest
import CoreMotion
@testable import GpsLogger

/// Tests for `MotionClassifier.classify(...)`. The classifier is exercised
/// as a pure static function — we construct no `CMMotionActivity`
/// instances (they have no public initializer on iOS 16+), just pass
/// the primitive flags and a confidence value directly.
final class MotionClassifierTests: XCTestCase {

    // MARK: - Confidence gate

    func testLowConfidenceIsDropped() {
        // Any combination of flags at .low confidence returns nil, meaning
        // "don't change the current mode". This prevents thrashing while
        // CoreMotion is transitioning between activities.
        XCTAssertNil(MotionClassifier.classify(
            automotive: true, cycling: false, walking: false, running: false,
            confidence: .low
        ))
        XCTAssertNil(MotionClassifier.classify(
            automotive: false, cycling: true, walking: false, running: false,
            confidence: .low
        ))
        XCTAssertNil(MotionClassifier.classify(
            automotive: false, cycling: false, walking: true, running: false,
            confidence: .low
        ))
    }

    // MARK: - Core mode mapping

    func testAutomotiveMapsToAutomotive() {
        XCTAssertEqual(
            MotionClassifier.classify(
                automotive: true, cycling: false, walking: false, running: false,
                confidence: .medium
            ),
            .automotive
        )
        XCTAssertEqual(
            MotionClassifier.classify(
                automotive: true, cycling: false, walking: false, running: false,
                confidence: .high
            ),
            .automotive
        )
    }

    func testCyclingMapsToCycling() {
        XCTAssertEqual(
            MotionClassifier.classify(
                automotive: false, cycling: true, walking: false, running: false,
                confidence: .medium
            ),
            .cycling
        )
    }

    func testWalkingMapsToPedestrian() {
        XCTAssertEqual(
            MotionClassifier.classify(
                automotive: false, cycling: false, walking: true, running: false,
                confidence: .medium
            ),
            .pedestrian
        )
    }

    func testRunningMapsToPedestrian() {
        // Running is a pedestrian activity for our purposes — same
        // activityType hint (`.fitness`) as walking.
        XCTAssertEqual(
            MotionClassifier.classify(
                automotive: false, cycling: false, walking: false, running: true,
                confidence: .medium
            ),
            .pedestrian
        )
    }

    func testAllFlagsFalseMapsToUnknown() {
        // Pure stationary with no activity bias. `LocationTracker`
        // interprets this as "hold the previous hint".
        XCTAssertEqual(
            MotionClassifier.classify(
                automotive: false, cycling: false, walking: false, running: false,
                confidence: .high
            ),
            .unknown
        )
    }

    // MARK: - Overlap priority

    func testAutomotiveBeatsWalking() {
        // CoreMotion sometimes reports `automotive && walking` during the
        // few seconds around getting in/out of a car. We intentionally
        // bias toward `.automotive` so the activityType hint stays on the
        // vehicle mode until CoreMotion is confident the user has purely
        // dismounted — preventing mid-drive flapping to `.fitness`.
        XCTAssertEqual(
            MotionClassifier.classify(
                automotive: true, cycling: false, walking: true, running: false,
                confidence: .medium
            ),
            .automotive
        )
    }

    func testAutomotiveBeatsCycling() {
        // Same rationale as the automotive-vs-walking case: if both flags
        // are set, prefer the vehicle hint.
        XCTAssertEqual(
            MotionClassifier.classify(
                automotive: true, cycling: true, walking: false, running: false,
                confidence: .medium
            ),
            .automotive
        )
    }

    func testCyclingBeatsWalking() {
        // A brief overlap when dismounting a bike — prefer cycling until
        // CoreMotion is sure you're only walking.
        XCTAssertEqual(
            MotionClassifier.classify(
                automotive: false, cycling: true, walking: true, running: false,
                confidence: .medium
            ),
            .cycling
        )
    }

    // MARK: - Nothing reported at high confidence

    func testHighConfidenceNothingIsUnknown() {
        // Phone reports "stationary" with high confidence — no activity
        // bias. Returns `.unknown`, LocationTracker keeps the previous
        // activityType.
        XCTAssertEqual(
            MotionClassifier.classify(
                automotive: false, cycling: false, walking: false, running: false,
                confidence: .high
            ),
            .unknown
        )
    }
}
