import XCTest
import CoreLocation
import UIKit
@testable import GpsLogger

/// Covers the pure static mapping helpers on
/// `LocationTracker.TrackingImpairment`. These are extracted specifically
/// so the silent-failure detection logic (iOS 14+ reduced-accuracy,
/// Background App Refresh status) can be tested in isolation without
/// mocking `CLLocationManager` or `UIApplication` themselves.
///
/// Rationale for these tests: each mapping protects a user-visible
/// banner, and a silent regression in the mapping (someone adds a new
/// `@unknown` case and flips the default, for example) would bring the
/// banner back to "everything is fine" while tracking is in fact broken.
final class TrackingImpairmentTests: XCTestCase {

    // MARK: - CLAccuracyAuthorization (iOS 14+)

    func testFullAccuracyProducesNoImpairment() {
        if #available(iOS 14.0, *) {
            XCTAssertNil(
                LocationTracker.TrackingImpairment.impairment(for: .fullAccuracy)
            )
        }
    }

    func testReducedAccuracyProducesReducedAccuracyImpairment() {
        if #available(iOS 14.0, *) {
            XCTAssertEqual(
                LocationTracker.TrackingImpairment.impairment(for: .reducedAccuracy),
                .reducedAccuracy
            )
        }
    }

    // MARK: - UIBackgroundRefreshStatus

    func testAvailableBackgroundRefreshProducesNoImpairment() {
        XCTAssertNil(
            LocationTracker.TrackingImpairment.impairment(for: .available)
        )
    }

    func testDeniedBackgroundRefreshProducesImpairment() {
        XCTAssertEqual(
            LocationTracker.TrackingImpairment.impairment(for: .denied),
            .backgroundRefreshDenied
        )
    }

    func testRestrictedBackgroundRefreshProducesImpairment() {
        // `.restricted` (Screen Time / MDM policy) is treated identically
        // to `.denied` because the symptom is identical — SLC relaunch
        // does not fire — and the user's recovery path is the same.
        XCTAssertEqual(
            LocationTracker.TrackingImpairment.impairment(for: .restricted),
            .backgroundRefreshDenied
        )
    }

    // MARK: - shortMessage sanity

    func testEveryImpairmentHasANonEmptyMessage() {
        // Future-proof guard: if someone adds a new case and forgets the
        // switch arm, this catches it before a release ships with an
        // empty banner. `CaseIterable` conformance plus non-empty check
        // gives us the coverage cheaply.
        for imp in LocationTracker.TrackingImpairment.allCases {
            XCTAssertFalse(
                imp.shortMessage.isEmpty,
                "TrackingImpairment.\(imp) has an empty shortMessage"
            )
        }
    }

    func testNewImpairmentMessagesMentionUserAction() {
        // Banners are only useful if they tell the user what to do next;
        // spot-check that the two 1.2.8 additions do so (otherwise we'd
        // be showing a dead-end warning).
        XCTAssertTrue(
            LocationTracker.TrackingImpairment.reducedAccuracy.shortMessage
                .lowercased()
                .contains("settings"),
            "reducedAccuracy banner should direct the user to Settings"
        )
        XCTAssertTrue(
            LocationTracker.TrackingImpairment.backgroundRefreshDenied.shortMessage
                .lowercased()
                .contains("force-quit") ||
            LocationTracker.TrackingImpairment.backgroundRefreshDenied.shortMessage
                .lowercased()
                .contains("background"),
            "backgroundRefreshDenied banner should explain the consequence"
        )
    }
}
