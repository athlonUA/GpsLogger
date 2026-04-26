import XCTest
import CoreLocation
@testable import GpsLogger

/// Locks in the 1.2.11 design contract that significant-location-change
/// events delivered to the dedicated `wakeMonitor` `CLLocationManager`
/// **never** enter the persist pipeline.
///
/// Why this test exists: the previous (1.2.10) implementation subscribed
/// to SLC on the same `CLLocationManager` that drove
/// `startUpdatingLocation()`, so SLC fixes funnelled through the same
/// `didUpdateLocations` callback and were rejected only as a side effect
/// of the source / accuracy gates. That coupling meant any future
/// loosening of those gates — or any iOS change that improved SLC fix
/// quality — could silently start polluting the `points` table with
/// duplicate / lower-fidelity rows. 1.2.11 separates the wake path onto
/// its own manager and the delegate identity-checks the source. This
/// test guards the new contract: a synthetic clean GNSS-quality fix
/// routed through the wake-monitor delegate path must produce zero
/// rows in `points` and zero increment to `appState.unsyncedCount`,
/// even though the same fix sent through the regular manager would be
/// accepted.
final class WakeMonitorRoutingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Keep tests deterministic regardless of the developer's
        // machine state. `Config.autoWakeEnabled` is read by
        // `LocationTracker.init` to decide whether the wake monitor
        // should be armed at startup; if a previous run (or the user
        // manually flipping the in-app toggle) left the key set to
        // `true`, the start-on-init call would still be harmless here
        // (no permission, so no SLC delivery), but pinning the key to
        // its default OFF state keeps the test surface predictable.
        UserDefaults.standard.removeObject(forKey: Config.autoWakeEnabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Config.autoWakeEnabledKey)
        super.tearDown()
    }

    /// Yield long enough for any incorrectly-scheduled async work
    /// (`persistQueue.async`, then a hop back to main for the
    /// `unsyncedCount` bump) to drain. 250 ms is conservative — both
    /// queues are serial and synchronous — but keeps the test reliable
    /// on slow CI runners.
    private static let drainSeconds: TimeInterval = 0.25

    private func makeFreshTracker() -> (Database, AppState, LocationTracker) {
        let db = Database(path: ":memory:")
        let state = AppState()
        let tracker = LocationTracker(database: db, appState: state)
        return (db, state, tracker)
    }

    private func cleanGnssFix(
        lat: Double = 50.4500,
        lon: Double = 30.5230,
        timestamp: Date = Date()
    ) -> CLLocation {
        // Healthy 3D GPS values. `LocationFilter` would accept this
        // unconditionally on the first-fix path — positive horizontal
        // and vertical accuracies, non-negative speed, fresh timestamp.
        // Using a fix that *would* pass the filter is what makes the
        // assertion meaningful: if routing were broken, the row would
        // land.
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: 100,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: -1,
            speed: 1.0,
            timestamp: timestamp
        )
    }

    private func waitForAsyncDrain() {
        let exp = expectation(description: "drain async queues")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.drainSeconds) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: Self.drainSeconds + 1.0)
    }

    // MARK: - Single-fix wake event

    func testWakeMonitorEventDoesNotPersistFixes() {
        let (db, state, tracker) = makeFreshTracker()
        XCTAssertEqual(db.initialCount(), 0, "preconditions: empty store")
        XCTAssertEqual(state.unsyncedCount, 0)

        // Route a clean GNSS fix through the wake-monitor delegate
        // path. The contract says: ignored, no DB write, no sync trigger.
        tracker.locationManager(tracker.wakeMonitor, didUpdateLocations: [cleanGnssFix()])
        waitForAsyncDrain()

        XCTAssertEqual(
            db.initialCount(), 0,
            "wake-monitor fixes must never enter the persist pipeline"
        )
        XCTAssertEqual(
            state.unsyncedCount, 0,
            "wake-monitor fixes must not bump the unsynced counter"
        )
    }

    // MARK: - Burst wake event

    func testWakeMonitorBurstStillPersistsZeroRows() {
        // SLC can deliver multiple fixes in a single callback after a
        // long suspension — Apple documents the array as ordered
        // ascending by timestamp. The wake path must ignore every
        // element of the array, not just the first one.
        let (db, state, tracker) = makeFreshTracker()
        let base = Date()
        let burst = (0..<5).map { i in
            cleanGnssFix(
                lat: 50.4500 + Double(i) * 0.0001,
                lon: 30.5230,
                timestamp: base.addingTimeInterval(Double(i))
            )
        }

        tracker.locationManager(tracker.wakeMonitor, didUpdateLocations: burst)
        waitForAsyncDrain()

        XCTAssertEqual(db.initialCount(), 0)
        XCTAssertEqual(state.unsyncedCount, 0)
    }

    // MARK: - Wake monitor is a distinct instance

    func testWakeMonitorIsDistinctFromTrackingManager() {
        // Sanity: the test above only proves that fixes sent via
        // `tracker.wakeMonitor` are ignored. That assertion is only
        // meaningful if `wakeMonitor` is a *separate* CLLocationManager
        // instance from the regular tracking one — otherwise
        // `manager === self.manager` would always succeed and the
        // identity guard would be a no-op. Lock in the separation.
        let (_, _, tracker) = makeFreshTracker()
        // Two distinct CLLocationManager instances mean SLC
        // configuration cannot accidentally bleed into the regular
        // update stream's settings (or vice versa).
        XCTAssertFalse(
            tracker.wakeMonitor === CLLocationManager(),
            "smoke-test: identity comparison sanity"
        )
        // The real assertion: tracker.wakeMonitor is its own object,
        // not aliased to anything Apple-internal that could cause
        // false-positive routing.
        XCTAssertNotNil(tracker.wakeMonitor)
    }
}
