import XCTest
import CoreLocation
@testable import GpsLogger

/// Locks in the 1.2.12 Auto Wake kill-switch contract:
///
///   1. `Config.autoWakeEnabled` is `false` on a fresh install — the
///      OS-level SLC subscription must not be armed without an
///      explicit opt-in.
///   2. `LocationTracker.setAutoWakeEnabled(_:)` persists the choice
///      to UserDefaults under `Config.autoWakeEnabledKey` so the next
///      launch picks it up via `Config.autoWakeEnabled`.
///   3. The `@Published autoWakeEnabled` mirror used by the SwiftUI
///      Toggle is updated synchronously on the main thread so the
///      sheet does not flicker between the old and new state.
///   4. A new `LocationTracker` instance reads the persisted
///      preference at init time, so a returning user with Auto Wake
///      previously enabled sees the toggle pre-flipped on the next
///      launch (and vice versa).
///
/// What this suite intentionally does not cover:
///   - Whether `wakeMonitor.startMonitoringSignificantLocationChanges()`
///     and `stop...` calls actually take effect at the OS level. The
///     OS-level SLC subscription state is opaque to the app — Apple
///     does not expose it — so we rely on Apple's documented contract
///     that the calls are real system-level effects, not app-local
///     flags. The only deterministic assertion we can make here is
///     about the persisted preference and the `@Published` mirror.
final class AutoWakeSettingsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Each test starts from a fresh UserDefaults state so prior
        // test runs (or the developer's app session) cannot pollute
        // the assertion. `removeObject` brings the value back to its
        // documented default of `false`.
        UserDefaults.standard.removeObject(forKey: Config.autoWakeEnabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Config.autoWakeEnabledKey)
        super.tearDown()
    }

    // MARK: - Config-level invariants

    func testAutoWakeIsOffByDefault() {
        // Spec contract: a fresh install must not arm SLC. The default
        // path through `UserDefaults.bool(forKey:)` is `false`, so the
        // assertion is direct — no side channel needed.
        XCTAssertFalse(
            Config.autoWakeEnabled,
            "Auto Wake must default to OFF — opt-in only"
        )
    }

    func testAutoWakeRoundTripsThroughUserDefaults() {
        // Independent of LocationTracker so we lock down the storage
        // contract on its own. The hidden settings sheet writes via
        // `setAutoWakeEnabled` (covered below); other readers
        // (`Config.autoWakeEnabled` getter, `LocationTracker.init`
        // seeding) must agree on the same key/value semantics.
        UserDefaults.standard.set(true, forKey: Config.autoWakeEnabledKey)
        XCTAssertTrue(Config.autoWakeEnabled)

        UserDefaults.standard.set(false, forKey: Config.autoWakeEnabledKey)
        XCTAssertFalse(Config.autoWakeEnabled)
    }

    // MARK: - LocationTracker init reads persisted preference

    func testTrackerInitMirrorsPersistedAutoWakeFalse() {
        // Default state: tracker boots with toggle OFF. SwiftUI sheet
        // would render the off position on first paint.
        let (_, _, tracker) = makeTracker()
        XCTAssertFalse(tracker.autoWakeEnabled)
    }

    func testTrackerInitMirrorsPersistedAutoWakeTrue() {
        // A returning user who previously opted in: the persisted
        // preference is read once at init and surfaced through the
        // `@Published` mirror so the SwiftUI Toggle binding shows the
        // correct position before any user interaction.
        UserDefaults.standard.set(true, forKey: Config.autoWakeEnabledKey)
        let (_, _, tracker) = makeTracker()
        XCTAssertTrue(tracker.autoWakeEnabled)
    }

    // MARK: - setAutoWakeEnabled side effects

    func testSetAutoWakeEnabledTrueUpdatesPublishedAndPersists() {
        let (_, _, tracker) = makeTracker()
        XCTAssertFalse(tracker.autoWakeEnabled, "preconditions: starts OFF")
        XCTAssertFalse(Config.autoWakeEnabled)

        tracker.setAutoWakeEnabled(true)

        XCTAssertTrue(
            tracker.autoWakeEnabled,
            "@Published mirror must reflect the new value synchronously"
        )
        XCTAssertTrue(
            Config.autoWakeEnabled,
            "UserDefaults must be written so the next launch picks it up"
        )
    }

    func testSetAutoWakeEnabledFalseUpdatesPublishedAndPersists() {
        UserDefaults.standard.set(true, forKey: Config.autoWakeEnabledKey)
        let (_, _, tracker) = makeTracker()
        XCTAssertTrue(tracker.autoWakeEnabled, "preconditions: starts ON")

        tracker.setAutoWakeEnabled(false)

        XCTAssertFalse(tracker.autoWakeEnabled)
        XCTAssertFalse(Config.autoWakeEnabled)
    }

    func testToggleSequencePreservesEachStep() {
        // Sanity: every transition in the on/off cycle propagates to
        // both the published mirror and the persisted store. Catches
        // regressions where one direction skips persistence (e.g. a
        // future `setAutoWakeEnabled(_:)` that early-returns when the
        // current value already matches and forgets to call the side
        // effect on the no-op branch).
        let (_, _, tracker) = makeTracker()
        let sequence: [Bool] = [true, false, true, true, false, false]
        for value in sequence {
            tracker.setAutoWakeEnabled(value)
            XCTAssertEqual(tracker.autoWakeEnabled, value)
            XCTAssertEqual(Config.autoWakeEnabled, value)
        }
    }

    // MARK: - Data-safety invariants (negative space)

    func testTogglingAutoWakeDoesNotDisturbStoredPoints() {
        // Spec: "Turning Auto Wake OFF must NOT delete local GPS
        // points." The setter writes one UserDefaults key and runs
        // start/stop on a CLLocationManager — it must never touch the
        // points table. Verify by seeding rows, toggling the switch
        // through both directions, and asserting the row count is
        // preserved.
        let db = Database(path: ":memory:")
        let state = AppState()
        let tracker = LocationTracker(database: db, appState: state)

        // Seed a few points to detect any inadvertent wipe.
        let baseTime = Date(timeIntervalSince1970: 1_760_000_000)
        for i in 0..<3 {
            db.insert(
                latitude: 50.45 + Double(i) * 0.0001,
                longitude: 30.52,
                createdAt: baseTime.addingTimeInterval(Double(i))
            )
        }
        XCTAssertEqual(db.initialCount(), 3, "preconditions: seeded rows")

        tracker.setAutoWakeEnabled(true)
        XCTAssertEqual(db.initialCount(), 3, "ON must not touch points")

        tracker.setAutoWakeEnabled(false)
        XCTAssertEqual(db.initialCount(), 3, "OFF must not touch points")
    }

    // MARK: - Helpers

    private func makeTracker() -> (Database, AppState, LocationTracker) {
        // In-memory store so each test is isolated from any prior run
        // and from the user's real database.
        let db = Database(path: ":memory:")
        let state = AppState()
        let tracker = LocationTracker(database: db, appState: state)
        return (db, state, tracker)
    }
}
