import XCTest
import CoreLocation
@testable import GpsLogger

/// Locks in the 1.2.13 unified home-zone contract — one persistent
/// last-known-position anchor + one radius decides three previously
/// independent questions:
///
///   1. **Cold-start under SLC-launch context** (`shouldEnterDeferredMode`):
///      should we enter `.deferred` mode and wait for the wake-monitor
///      to prove displacement, or run `.fullTracking` immediately?
///   2. **Wake-monitor delegate while in `.deferred`**
///      (`evaluateWakeFixForDeferredExit`): does the SLC fix prove
///      the user has left the home zone, or are we still home?
///   3. **`maybePersist` pre-pipeline gate**: should this accepted
///      fix flow into smoother → stationary → SQLite, or be silently
///      suppressed because it landed inside the home zone?
///
/// All three call sites read the same `Config.lastAnchor()` against
/// the same `Config.homeZoneRadiusMeters`, so a single set of
/// invariants is enough to lock down the unified semantics:
///
///   - Anchor freshness: a stale anchor (`> anchorMaxAgeSeconds`) is
///     treated as "no anchor" by every gate, falling back to the
///     pre-1.2.13 always-on behavior.
///   - Anchor-write coupling: the anchor is updated **only** by a
///     successful `database.insert` in `persist(_:)`, never on
///     suppress, never on filter discard. The on-disk anchor is
///     always backed by an actual `points` row.
///   - Symmetry with the conscious-launch UX: `launchedForLocation
///     == false` always lands in `.fullTracking`, no matter what the
///     anchor or Auto Wake setting says.
final class HomeZoneTests: XCTestCase {

    // Coordinate close to the user's actual evening anchor on
    // 2026-04-26 — Valencia, ES. Using realistic numbers so the
    // distance arithmetic exercises real-world geodetic math, not
    // the equator's degenerate cases.
    private let anchorLat: Double = 39.483866
    private let anchorLon: Double = -0.380608

    override func setUp() {
        super.setUp()
        // Every test starts from a known-empty UserDefaults state.
        // Both keys (Auto Wake + anchor triple) are owned by Config,
        // and the assertions in this suite only make sense when
        // neither has prior-test residue.
        UserDefaults.standard.removeObject(forKey: Config.autoWakeEnabledKey)
        Config.clearLastAnchor()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Config.autoWakeEnabledKey)
        Config.clearLastAnchor()
        super.tearDown()
    }

    /// Match the pattern from `WakeMonitorRoutingTests`: synthetic
    /// CLLocations are sufficient because we never invoke real
    /// CoreLocation services in these tests — we drive delegate
    /// methods and helpers directly.
    private static let drainSeconds: TimeInterval = 0.25

    private func makeFreshTracker() -> (Database, AppState, LocationTracker) {
        let db = Database(path: ":memory:")
        let state = AppState()
        let tracker = LocationTracker(database: db, appState: state)
        return (db, state, tracker)
    }

    private func cleanGnssFix(
        lat: Double,
        lon: Double,
        timestamp: Date = Date()
    ) -> CLLocation {
        // Same shape as WakeMonitorRoutingTests' helper. HA = 5 m
        // passes LocationFilter unconditionally on the first-fix
        // path, so the home-zone gate is the ONLY thing that can
        // suppress this fix from reaching `points`.
        CLLocation(
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

    /// Compute a coordinate offset by `meters` north of the given
    /// origin. North-only offsets keep the math readable and avoid
    /// the longitude-cosine-correction noise; for our purposes
    /// (verifying home-zone gate around 100 m) this is plenty.
    private func coordinate(metersNorth meters: Double, of lat: Double) -> Double {
        // 1° of latitude ≈ 111_320 m anywhere on Earth (close enough
        // for a few hundred meters at most). Keep the conversion
        // explicit so the test reads as "this fix is exactly N meters
        // away" — no surprises.
        return lat + meters / 111_320.0
    }

    // MARK: - Anchor round-trip + freshness

    func testLastAnchorReturnsNilWhenNeverWritten() {
        XCTAssertNil(
            Config.lastAnchor(),
            "Cold install: lastAnchor must be nil, not a phantom (0,0) record"
        )
    }

    func testAnchorRoundTripsThroughUserDefaults() {
        let now = Date()
        Config.updateLastAnchor(latitude: anchorLat, longitude: anchorLon, timestamp: now)

        guard let anchor = Config.lastAnchor() else {
            XCTFail("expected anchor after write")
            return
        }
        XCTAssertEqual(anchor.latitude, anchorLat, accuracy: 1e-9)
        XCTAssertEqual(anchor.longitude, anchorLon, accuracy: 1e-9)
        XCTAssertEqual(
            anchor.timestamp.timeIntervalSince1970,
            now.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testAnchorIsFreshWithinMaxAge() {
        let recent = Date().addingTimeInterval(-3600) // 1 hour ago
        Config.updateLastAnchor(latitude: anchorLat, longitude: anchorLon, timestamp: recent)
        XCTAssertTrue(Config.lastAnchor()?.isFresh() ?? false)
    }

    func testAnchorIsStaleAfterMaxAge() {
        let stale = Date().addingTimeInterval(-(Config.anchorMaxAgeSeconds + 60))
        Config.updateLastAnchor(latitude: anchorLat, longitude: anchorLon, timestamp: stale)
        XCTAssertFalse(
            Config.lastAnchor()?.isFresh() ?? true,
            "Anchor older than anchorMaxAgeSeconds must be reported stale"
        )
    }

    // MARK: - shouldEnterDeferredMode decision matrix

    /// The decision matrix has four binary inputs and the rule is
    /// AND across all of them. The five tests below cover the
    /// all-true case + the four "exactly one false" cases, which
    /// is sufficient for an AND-only predicate (any one false →
    /// false; all true → true).

    func testDeferredModeRequiresAllFourPreconditions() {
        // All preconditions met → true.
        UserDefaults.standard.set(true, forKey: Config.autoWakeEnabledKey)
        Config.updateLastAnchor(latitude: anchorLat, longitude: anchorLon, timestamp: Date())

        let (_, _, tracker) = makeFreshTracker()
        // `start` is the only public way to set launchedForLocation;
        // we invoke it without auth grant so it doesn't kick off
        // CoreLocation (which on a unit-test bundle without
        // permissions would just sit in .notDetermined).
        tracker.start(launchedForLocation: true)

        XCTAssertTrue(
            tracker.shouldEnterDeferredMode(),
            "All four preconditions met must produce deferred mode"
        )
    }

    func testDeferredModeFalseWhenNotLaunchedForLocation() {
        // Conscious launch (manual app-icon tap, BGAppRefresh, etc.)
        // must always go to .fullTracking, regardless of anchor /
        // Auto Wake state. This is the symmetry guarantee.
        UserDefaults.standard.set(true, forKey: Config.autoWakeEnabledKey)
        Config.updateLastAnchor(latitude: anchorLat, longitude: anchorLon, timestamp: Date())

        let (_, _, tracker) = makeFreshTracker()
        tracker.start(launchedForLocation: false)

        XCTAssertFalse(
            tracker.shouldEnterDeferredMode(),
            "User-initiated launch must never enter deferred mode"
        )
    }

    func testDeferredModeFalseWhenAutoWakeOff() {
        // Auto Wake off → wake-monitor is not armed, so deferred
        // would never receive a promotion signal. Defensive: the
        // tracker must not enter a state from which it cannot exit.
        UserDefaults.standard.set(false, forKey: Config.autoWakeEnabledKey)
        Config.updateLastAnchor(latitude: anchorLat, longitude: anchorLon, timestamp: Date())

        let (_, _, tracker) = makeFreshTracker()
        tracker.start(launchedForLocation: true)

        XCTAssertFalse(tracker.shouldEnterDeferredMode())
    }

    func testDeferredModeFalseWhenNoAnchor() {
        // First-ever install / freshly-cleared state. No anchor → no
        // reference distance, so the deferred path has nothing to
        // evaluate against. Falls back to .fullTracking, which
        // becomes the source of the FIRST anchor for next session.
        UserDefaults.standard.set(true, forKey: Config.autoWakeEnabledKey)
        Config.clearLastAnchor()

        let (_, _, tracker) = makeFreshTracker()
        tracker.start(launchedForLocation: true)

        XCTAssertFalse(tracker.shouldEnterDeferredMode())
    }

    func testDeferredModeFalseWhenAnchorStale() {
        // A 25-hour-old anchor is past the 24 h max. Trip from a
        // week ago must not influence today's first-fix routing.
        UserDefaults.standard.set(true, forKey: Config.autoWakeEnabledKey)
        let stale = Date().addingTimeInterval(-(Config.anchorMaxAgeSeconds + 3600))
        Config.updateLastAnchor(latitude: anchorLat, longitude: anchorLon, timestamp: stale)

        let (_, _, tracker) = makeFreshTracker()
        tracker.start(launchedForLocation: true)

        XCTAssertFalse(tracker.shouldEnterDeferredMode())
    }

    // MARK: - evaluateWakeFixForDeferredExit

    func testWakeFixInsideHomeZoneKeepsDeferred() {
        // Setup: tracker is in deferred mode, wake-monitor delivers
        // a fix close to the home anchor (50 m north, comfortably
        // inside 100 m). Mode must stay .deferred.
        UserDefaults.standard.set(true, forKey: Config.autoWakeEnabledKey)
        Config.updateLastAnchor(latitude: anchorLat, longitude: anchorLon, timestamp: Date())
        let (_, _, tracker) = makeFreshTracker()
        // Force tracker into .deferred for the test. Production
        // code reaches this state through start(launchedForLocation:)
        // + handleAuthorizationState; here we exercise the wake
        // delegate path directly.
        tracker.forceDeferredModeForTesting()
        XCTAssertEqual(tracker.mode, .deferred)

        let fixNear = cleanGnssFix(
            lat: coordinate(metersNorth: 50, of: anchorLat),
            lon: anchorLon
        )
        tracker.evaluateWakeFixForDeferredExit(fixNear)

        XCTAssertEqual(
            tracker.mode, .deferred,
            "SLC fix inside home zone must NOT promote to fullTracking"
        )
    }

    func testWakeFixOutsideHomeZonePromotesToFullTracking() {
        // 200 m north is decisively outside the 100 m radius.
        // Promotion must engage.
        UserDefaults.standard.set(true, forKey: Config.autoWakeEnabledKey)
        Config.updateLastAnchor(latitude: anchorLat, longitude: anchorLon, timestamp: Date())
        let (_, _, tracker) = makeFreshTracker()
        tracker.forceDeferredModeForTesting()

        let fixFar = cleanGnssFix(
            lat: coordinate(metersNorth: 200, of: anchorLat),
            lon: anchorLon
        )
        tracker.evaluateWakeFixForDeferredExit(fixFar)

        XCTAssertEqual(
            tracker.mode, .fullTracking,
            "SLC fix > homeZoneRadiusMeters must promote to fullTracking"
        )
    }

    func testWakeFixWithNoAnchorPromotesDefensively() {
        // Edge case: somehow we got into deferred mode without an
        // anchor on disk (test uses forceDeferredModeForTesting
        // directly to construct this state). The wake-monitor's
        // first fix should defensively promote — we have no
        // reference to prove "still home", so default to safe.
        Config.clearLastAnchor()
        let (_, _, tracker) = makeFreshTracker()
        tracker.forceDeferredModeForTesting()

        let anyFix = cleanGnssFix(lat: anchorLat, lon: anchorLon)
        tracker.evaluateWakeFixForDeferredExit(anyFix)

        XCTAssertEqual(tracker.mode, .fullTracking)
    }

    // MARK: - maybePersist home-zone pre-check

    func testSLCLaunchFixInsideHomeZoneSuppressedFromPersist() {
        // 2026-04-26 phantom-points: 19 min quiet, fix 33 m from anchor
        // → suppressed by the combined gap + distance gate.
        // 1.3.1: the gap clause is now SLC-only. This test must
        // simulate the SLC-launch context (start + auth grant) so
        // isSLCLaunch=true and the gate engages. Renamed from
        // testFixInsideHomeZoneSuppressedFromPersist.
        let nineteenMinAgo = Date().addingTimeInterval(-19 * 60)
        Config.updateLastAnchor(
            latitude: anchorLat,
            longitude: anchorLon,
            timestamp: nineteenMinAgo
        )
        let (db, state, tracker) = makeFreshTracker()

        // SLC-launch context: isSLCLaunch must be true for the gap
        // clause to fire. Simulate the SLC-wake flow.
        tracker.start(launchedForLocation: true)
        tracker.handleAuthorizationStateForTesting(.authorizedAlways)

        XCTAssertEqual(db.initialCount(), 0)

        let phantom = cleanGnssFix(
            lat: coordinate(metersNorth: 33, of: anchorLat),
            lon: anchorLon
        )
        tracker.locationManager(tracker.testingTrackingManager(), didUpdateLocations: [phantom])
        waitForAsyncDrain()

        XCTAssertEqual(
            db.initialCount(), 0,
            "SLC-launch: fix inside home zone after a long quiet window must not produce a points row"
        )
        XCTAssertEqual(state.unsyncedCount, 0)
    }

    func testManualLaunchFixInsideHomeZoneIsNotSuppressed() {
        // 1.3.1 regression test. Manual launch (isSLCLaunch=false)
        // must NOT suppress fixes within the home zone, even after
        // a long gap. The user explicitly launched the app — they
        // expect tracking to start immediately, not after walking
        // >100 m from their last-anchor position.
        let nineteenMinAgo = Date().addingTimeInterval(-19 * 60)
        Config.updateLastAnchor(
            latitude: anchorLat,
            longitude: anchorLon,
            timestamp: nineteenMinAgo
        )
        let (db, state, tracker) = makeFreshTracker()

        // Manual-launch context
        tracker.start(launchedForLocation: false)
        tracker.handleAuthorizationStateForTesting(.authorizedAlways)

        XCTAssertEqual(db.initialCount(), 0)

        let fix = cleanGnssFix(
            lat: coordinate(metersNorth: 33, of: anchorLat),
            lon: anchorLon
        )
        tracker.locationManager(tracker.testingTrackingManager(), didUpdateLocations: [fix])
        waitForAsyncDrain()

        XCTAssertEqual(
            db.initialCount(), 1,
            "Manual launch + fresh anchor + long gap + fix within 100 m → must persist"
        )
        XCTAssertEqual(state.unsyncedCount, 1)
    }

    func testDeferredExitClearsSLCFlag() {
        // 1.3.1 edge case: SLC-launched → deferred overnight → user
        // opens app in morning → exitDeferredIfNeeded → gap clause
        // must NOT suppress the first fix after promotion.
        //
        // Simulate: SLC launch sets isSLCLaunch=true. Force deferred
        // (as the overnight SLC wake would). Then promote — this
        // must clear the sticky flag so the resumed stream records
        // immediately.
        let nineteenMinAgo = Date().addingTimeInterval(-19 * 60)
        Config.updateLastAnchor(
            latitude: anchorLat,
            longitude: anchorLon,
            timestamp: nineteenMinAgo
        )
        let (db, state, tracker) = makeFreshTracker()

        // SLC-launch context — sets isSLCLaunch=true
        tracker.start(launchedForLocation: true)
        tracker.forceDeferredModeForTesting()
        XCTAssertEqual(tracker.mode, .deferred)

        // User opens app → exit from deferred → must clear isSLCLaunch
        tracker.exitDeferredIfNeeded()
        XCTAssertEqual(tracker.mode, .fullTracking)

        // Now drive a fix inside the home zone. Without the flag
        // clear, the gap clause would suppress it (anchor 19 min ago,
        // gap > 60s, within 100m). With the flag cleared by exit,
        // it must persist.
        let fix = cleanGnssFix(
            lat: coordinate(metersNorth: 33, of: anchorLat),
            lon: anchorLon
        )
        tracker.locationManager(tracker.testingTrackingManager(), didUpdateLocations: [fix])
        waitForAsyncDrain()

        XCTAssertEqual(
            db.initialCount(), 1,
            "Fix after deferred exit must persist — isSLCLaunch cleared on promotion"
        )
        XCTAssertEqual(state.unsyncedCount, 1)
    }

    func testWakeMonitorPromotionClearsSLCFlag() {
        // 1.3.1: wake-monitor path (evaluateWakeFixForDeferredExit)
        // also calls exitDeferredIfNeeded internally — verify the
        // SLC flag is cleared so post-promotion fixes inside the
        // home zone persist without gap-clause suppression.
        let nineteenMinAgo = Date().addingTimeInterval(-19 * 60)
        Config.updateLastAnchor(
            latitude: anchorLat,
            longitude: anchorLon,
            timestamp: nineteenMinAgo
        )
        let (db, state, tracker) = makeFreshTracker()

        // SLC-launch → deferred context
        tracker.start(launchedForLocation: true)
        tracker.forceDeferredModeForTesting()
        XCTAssertEqual(tracker.mode, .deferred)

        // Wake-monitor delivers a fix outside the home zone —
        // this triggers promotion to fullTracking and must clear
        // isSLCLaunch.
        let farFix = cleanGnssFix(
            lat: coordinate(metersNorth: 200, of: anchorLat),
            lon: anchorLon
        )
        tracker.evaluateWakeFixForDeferredExit(farFix)
        XCTAssertEqual(
            tracker.mode, .fullTracking,
            "Wake-monitor displacement must promote to fullTracking"
        )

        // Now a fix inside the home zone after promotion must persist
        let fix = cleanGnssFix(
            lat: coordinate(metersNorth: 33, of: anchorLat),
            lon: anchorLon
        )
        tracker.locationManager(tracker.testingTrackingManager(), didUpdateLocations: [fix])
        waitForAsyncDrain()

        XCTAssertEqual(
            db.initialCount(), 1,
            "Fix after wake-monitor promotion must persist — isSLCLaunch cleared"
        )
        XCTAssertEqual(state.unsyncedCount, 1)
    }

    func testContinuousWalkingFixInsideHomeZoneIsNotSuppressed() {
        // 2026-04-29 regression: rolling anchor + fresh fix at 15 m must
        // NOT be suppressed — the gap clause gates the home-zone radius
        // so dense walks cannot trip it.
        let twoSecondsAgo = Date().addingTimeInterval(-2)
        Config.updateLastAnchor(
            latitude: anchorLat,
            longitude: anchorLon,
            timestamp: twoSecondsAgo
        )
        let (db, state, tracker) = makeFreshTracker()
        XCTAssertEqual(db.initialCount(), 0)

        let nextStep = cleanGnssFix(
            lat: coordinate(metersNorth: 15, of: anchorLat),
            lon: anchorLon
        )
        tracker.locationManager(
            tracker.testingTrackingManager(),
            didUpdateLocations: [nextStep]
        )
        waitForAsyncDrain()

        XCTAssertEqual(
            db.initialCount(), 1,
            "Continuous walking fix must reach `points` even when within 100 m of the anchor"
        )
        XCTAssertEqual(state.unsyncedCount, 1)
    }

    func testFixOutsideHomeZoneStillFlowsToPersist() {
        // Symmetric: a fix 200 m north of anchor is real
        // displacement. The home-zone gate must NOT silently swallow
        // it — that would break the genuine "left home" recording.
        Config.updateLastAnchor(latitude: anchorLat, longitude: anchorLon, timestamp: Date())
        let (db, state, tracker) = makeFreshTracker()

        let realMove = cleanGnssFix(
            lat: coordinate(metersNorth: 200, of: anchorLat),
            lon: anchorLon
        )
        tracker.locationManager(tracker.testingTrackingManager(), didUpdateLocations: [realMove])
        waitForAsyncDrain()

        XCTAssertEqual(
            db.initialCount(), 1,
            "Fix outside home zone must flow through to points"
        )
        XCTAssertEqual(state.unsyncedCount, 1)
    }

    func testFixWithStaleAnchorIsNotSuppressed() {
        // Returning user from a vacation: anchor on disk is from a
        // week ago. New fix lands at a coincidentally similar
        // coordinate. The gate must NOT suppress — stale anchors
        // are equivalent to no anchor for this decision.
        let stale = Date().addingTimeInterval(-(Config.anchorMaxAgeSeconds + 3600))
        Config.updateLastAnchor(latitude: anchorLat, longitude: anchorLon, timestamp: stale)
        let (db, _, tracker) = makeFreshTracker()

        let fix = cleanGnssFix(
            lat: coordinate(metersNorth: 10, of: anchorLat),
            lon: anchorLon
        )
        tracker.locationManager(tracker.testingTrackingManager(), didUpdateLocations: [fix])
        waitForAsyncDrain()

        XCTAssertEqual(
            db.initialCount(), 1,
            "Stale anchor must not gate persist — stale anchors fall back to pre-1.2.13 behavior"
        )
    }

    func testPersistUpdatesAnchor() {
        // Each successful persist must refresh the anchor so the
        // home zone follows the user. Use a stale anchor as a
        // canary: if the post-persist anchor is fresh AND at the
        // new coordinate, we know persist updated it.
        let stale = Date().addingTimeInterval(-(Config.anchorMaxAgeSeconds + 3600))
        // Place stale anchor far away so the new fix is outside the
        // home zone from the stale anchor's perspective AND the
        // stale anchor would not gate it anyway.
        Config.updateLastAnchor(latitude: 0.0, longitude: 0.0, timestamp: stale)
        let (db, _, tracker) = makeFreshTracker()

        let newFix = cleanGnssFix(lat: anchorLat, lon: anchorLon)
        tracker.locationManager(tracker.testingTrackingManager(), didUpdateLocations: [newFix])
        waitForAsyncDrain()

        XCTAssertEqual(db.initialCount(), 1)
        guard let anchor = Config.lastAnchor() else {
            XCTFail("expected anchor written by persist")
            return
        }
        XCTAssertEqual(anchor.latitude, anchorLat, accuracy: 1e-6)
        XCTAssertEqual(anchor.longitude, anchorLon, accuracy: 1e-6)
        XCTAssertTrue(anchor.isFresh(), "anchor must be fresh right after persist")
    }

    // MARK: - exitDeferredIfNeeded idempotency

    func testExitDeferredFromFullTrackingIsNoOp() {
        // Already in fullTracking — calling exit must not flip
        // anything. Important because GpsLoggerApp's scenePhase
        // observer calls this on every .active transition.
        let (_, _, tracker) = makeFreshTracker()
        XCTAssertEqual(tracker.mode, .fullTracking)
        tracker.exitDeferredIfNeeded()
        XCTAssertEqual(tracker.mode, .fullTracking)
    }

    func testExitDeferredFromDeferredFlipsToFullTracking() {
        let (_, _, tracker) = makeFreshTracker()
        tracker.forceDeferredModeForTesting()
        XCTAssertEqual(tracker.mode, .deferred)

        tracker.exitDeferredIfNeeded()
        XCTAssertEqual(tracker.mode, .fullTracking)
    }

    // MARK: - Single-evaluation contract for launchedForLocation
    //
    // Audit finding: the SLC-launch flag must be cleared after the
    // first authorization-state evaluation post-launch. Otherwise a
    // user who revokes permission and re-grants it later (while
    // actively using the app, hours after the SLC launch) would be
    // pushed back into `.deferred` despite being in foreground —
    // because all the deferred preconditions still hold (Auto Wake
    // on, anchor fresh) and the flag would still report "we were
    // launched by SLC". The clear-after-first-evaluation rule binds
    // the flag to its actual semantics: it represents the *boot*
    // context, not a persistent property.

    func testLaunchedForLocationFlagPersistsBeforeFirstAuthEvaluation() {
        // Sanity: right after `start(launchedForLocation: true)`, the
        // flag is still set — the auth-state callback hasn't fired
        // yet. shouldEnterDeferredMode is the only consumer and must
        // see `true` here for the original deferred entry to work.
        UserDefaults.standard.set(true, forKey: Config.autoWakeEnabledKey)
        Config.updateLastAnchor(latitude: anchorLat, longitude: anchorLon, timestamp: Date())
        let (_, _, tracker) = makeFreshTracker()

        tracker.start(launchedForLocation: true)
        XCTAssertTrue(tracker.launchedForLocationFlagForTesting)
        XCTAssertTrue(tracker.shouldEnterDeferredMode())
    }

    func testLaunchedForLocationFlagClearedAfterAlwaysGrant() {
        // The bug being guarded: user is SLC-launched into deferred,
        // wakes up, exits to full tracking, hours later revokes and
        // re-grants permission in Settings. Without the clear-on-
        // first-evaluation rule, the second grant would re-enter
        // deferred with a foreground app — wrong.
        UserDefaults.standard.set(true, forKey: Config.autoWakeEnabledKey)
        Config.updateLastAnchor(latitude: anchorLat, longitude: anchorLon, timestamp: Date())
        let (_, _, tracker) = makeFreshTracker()

        tracker.start(launchedForLocation: true)
        XCTAssertTrue(tracker.shouldEnterDeferredMode(), "preconditions for deferred")

        // Simulate the first auth-state callback — this is what
        // production reaches via locationManagerDidChangeAuthorization
        // when iOS reports the granted state.
        tracker.handleAuthorizationStateForTesting(.authorizedAlways)

        XCTAssertFalse(
            tracker.launchedForLocationFlagForTesting,
            "Flag must clear after the first auth-state evaluation"
        )
        XCTAssertFalse(
            tracker.shouldEnterDeferredMode(),
            "Subsequent grants must never re-enter deferred"
        )
    }

    func testLaunchedForLocationFlagClearedAfterWhenInUseGrant() {
        // Same contract under the WhenInUse branch — that path also
        // ends authorization evaluation, and the flag is no longer
        // meaningful afterward (SLC requires Always anyway, but the
        // semantics need to be uniform across both grant kinds).
        UserDefaults.standard.set(true, forKey: Config.autoWakeEnabledKey)
        Config.updateLastAnchor(latitude: anchorLat, longitude: anchorLon, timestamp: Date())
        let (_, _, tracker) = makeFreshTracker()
        tracker.start(launchedForLocation: true)

        tracker.handleAuthorizationStateForTesting(.authorizedWhenInUse)

        XCTAssertFalse(tracker.launchedForLocationFlagForTesting)
        XCTAssertFalse(tracker.shouldEnterDeferredMode())
    }

    // MARK: - WhenInUse mode invariant
    //
    // Audit finding: the original .authorizedWhenInUse branch called
    // beginUpdates() but didn't update `mode`. After an
    // .authorizedAlways → .authorizedWhenInUse downgrade while in
    // .deferred, isTracking would flip true via beginUpdates while
    // mode stayed .deferred — a state-machine inconsistency. The fix
    // explicitly sets `mode = .fullTracking` in the WhenInUse branch
    // and adds a defensive exitDeferredIfNeeded for the in-deferred
    // downgrade case.

    func testWhenInUseGrantSetsFullTrackingMode() {
        // Cold WhenInUse grant: mode must end up at .fullTracking,
        // not lingering at whatever default the tracker was constructed
        // with. (The default happens to be .fullTracking, but a future
        // refactor could change that — the assertion keeps the
        // invariant explicit.)
        let (_, _, tracker) = makeFreshTracker()

        tracker.handleAuthorizationStateForTesting(.authorizedWhenInUse)

        XCTAssertEqual(tracker.mode, .fullTracking)
    }

    func testWhenInUseDowngradeFromDeferredPromotes() {
        // Audit scenario: app is in deferred (via SLC launch), user
        // downgrades from Always to WhenInUse in Settings. iOS
        // delivers the auth-state change. The branch must promote
        // out of deferred — otherwise we'd have isTracking=true
        // (from beginUpdates) but mode=.deferred.
        let (_, _, tracker) = makeFreshTracker()
        tracker.forceDeferredModeForTesting()
        XCTAssertEqual(tracker.mode, .deferred)

        tracker.handleAuthorizationStateForTesting(.authorizedWhenInUse)

        XCTAssertEqual(
            tracker.mode, .fullTracking,
            "Downgrade-into-deferred must defensively promote to fullTracking"
        )
    }
}
