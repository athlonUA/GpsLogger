import XCTest
@testable import GpsLogger

/// Exercises the local SQLite store end-to-end: insert, fetch in batches,
/// delete-by-id (simulating a successful SyncService drain), retention
/// cleanup. Each test opens a fresh in-memory database via the `path:`
/// override on `Database.init`, so there is no cross-test contamination
/// and no disk I/O.
///
/// The invariant these tests lock in: **after `fetchBatch` / `fetchDiagnosticsBatch`
/// followed by `delete(ids:)` / `deleteDiagnostics(ids:)`, the uploaded rows
/// are gone from the local store.** That's the whole contract SyncService
/// relies on for "after sync the device has nothing left".
final class DatabaseTests: XCTestCase {

    private func makeDatabase() -> Database {
        // `:memory:` gives each test its own isolated in-process SQLite.
        Database(path: ":memory:")
    }

    // MARK: - points

    func testPointsInsertFetchDeleteCycleLeavesStoreEmpty() {
        let db = makeDatabase()
        for i in 0..<5 {
            db.insert(
                latitude: 50.45 + Double(i) * 0.0001,
                longitude: 30.52,
                createdAt: Date(timeIntervalSince1970: 1_760_000_000 + Double(i))
            )
        }
        XCTAssertEqual(db.initialCount(), 5)

        let batch = db.fetchBatch(limit: 100)
        XCTAssertEqual(batch.count, 5)

        db.delete(ids: batch.map { $0.id })
        XCTAssertEqual(db.initialCount(), 0, "after delete, points table must be empty")
        XCTAssertTrue(db.fetchBatch(limit: 100).isEmpty)
    }

    func testPointsBatchLimitDrainsAcrossMultipleTicks() {
        // 250 rows, batch size 100 → needs three drain cycles to empty.
        let db = makeDatabase()
        for i in 0..<250 {
            db.insert(
                latitude: 50.0,
                longitude: 30.0,
                createdAt: Date(timeIntervalSince1970: 1_760_000_000 + Double(i))
            )
        }
        XCTAssertEqual(db.initialCount(), 250)

        var drained = 0
        var ticks = 0
        while true {
            let batch = db.fetchBatch(limit: 100)
            if batch.isEmpty { break }
            db.delete(ids: batch.map { $0.id })
            drained += batch.count
            ticks += 1
            XCTAssertLessThan(ticks, 10, "safety: must not loop forever")
        }
        XCTAssertEqual(drained, 250)
        XCTAssertEqual(ticks, 3, "250 rows with batch=100 should drain in exactly 3 ticks")
        XCTAssertEqual(db.initialCount(), 0)
    }

    // MARK: - diagnostics

    func testDiagnosticsLogFetchDeleteCycleLeavesStoreEmpty() {
        let db = makeDatabase()
        let base = Date(timeIntervalSince1970: 1_760_000_000)
        for i in 0..<5 {
            db.logDiagnostic(FixDiagnostic(
                fixTimestamp: base.addingTimeInterval(Double(i)),
                latitude: 50.45,
                longitude: 30.52,
                horizontalAccuracy: 5,
                verticalAccuracy: 5,
                altitude: 100,
                speed: 1.2,
                speedAccuracy: 0.3,
                course: 45,
                courseAccuracy: 5,
                decision: "accept"
            ))
        }

        let batch = db.fetchDiagnosticsBatch(limit: 100)
        XCTAssertEqual(batch.count, 5)
        XCTAssertEqual(batch.first?.decision, "accept")

        db.deleteDiagnostics(ids: batch.map { $0.id })
        XCTAssertTrue(
            db.fetchDiagnosticsBatch(limit: 100).isEmpty,
            "after delete, fix_diagnostics must be empty"
        )
    }

    func testDiagnosticsRoundTripPreservesSentinelValues() {
        // The whole point of storing diagnostics is that the negative
        // sentinels CoreLocation uses for Wi-Fi / cell fallback survive
        // the round trip. If these get clipped to 0 or dropped, the
        // analysis workflow is useless.
        let db = makeDatabase()
        db.logDiagnostic(FixDiagnostic(
            fixTimestamp: Date(timeIntervalSince1970: 1_760_000_000),
            latitude: 50.45,
            longitude: 30.52,
            horizontalAccuracy: 42,
            verticalAccuracy: -1,
            altitude: 0,
            speed: -1,
            speedAccuracy: -1,
            course: -1,
            courseAccuracy: -1,
            decision: "discard:nonGpsSource"
        ))
        let batch = db.fetchDiagnosticsBatch(limit: 10)
        XCTAssertEqual(batch.count, 1)
        let row = batch[0]
        XCTAssertEqual(row.horizontalAccuracy, 42)
        XCTAssertEqual(row.verticalAccuracy, -1)
        XCTAssertEqual(row.speed, -1)
        XCTAssertEqual(row.speedAccuracy, -1)
        XCTAssertEqual(row.course, -1)
        XCTAssertEqual(row.courseAccuracy, -1)
        XCTAssertEqual(row.decision, "discard:nonGpsSource")
    }

    func testDiagnosticsBatchLimitDrainsAcrossMultipleTicks() {
        // Mirror of the points test — make sure the diagnostics channel has
        // the same drain semantics.
        let db = makeDatabase()
        let base = Date(timeIntervalSince1970: 1_760_000_000)
        for i in 0..<250 {
            db.logDiagnostic(FixDiagnostic(
                fixTimestamp: base.addingTimeInterval(Double(i)),
                latitude: 50.45,
                longitude: 30.52,
                horizontalAccuracy: 5,
                verticalAccuracy: 5,
                altitude: 100,
                speed: 1.2,
                speedAccuracy: 0.3,
                course: 45,
                courseAccuracy: 5,
                decision: "accept"
            ))
        }

        var drained = 0
        var ticks = 0
        while true {
            let batch = db.fetchDiagnosticsBatch(limit: 100)
            if batch.isEmpty { break }
            db.deleteDiagnostics(ids: batch.map { $0.id })
            drained += batch.count
            ticks += 1
            XCTAssertLessThan(ticks, 10, "safety: must not loop forever")
        }
        XCTAssertEqual(drained, 250)
        XCTAssertEqual(ticks, 3)
        XCTAssertTrue(db.fetchDiagnosticsBatch(limit: 100).isEmpty)
    }

    func testDrainIsolatedToFetchedIds() {
        // Rows written *after* fetch but *before* delete must NOT be
        // collaterally removed. This protects against a race where a new
        // fix lands mid-upload: the next drain tick must still see it.
        let db = makeDatabase()
        let base = Date(timeIntervalSince1970: 1_760_000_000)
        for i in 0..<3 {
            db.logDiagnostic(FixDiagnostic(
                fixTimestamp: base.addingTimeInterval(Double(i)),
                latitude: 0, longitude: 0,
                horizontalAccuracy: 5, verticalAccuracy: 5, altitude: 0,
                speed: 1, speedAccuracy: 0.3, course: 0, courseAccuracy: 5,
                decision: "accept"
            ))
        }
        let batch = db.fetchDiagnosticsBatch(limit: 100)
        XCTAssertEqual(batch.count, 3)

        // New fix lands while the upload is "in flight".
        db.logDiagnostic(FixDiagnostic(
            fixTimestamp: base.addingTimeInterval(999),
            latitude: 0, longitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: 5, altitude: 0,
            speed: 1, speedAccuracy: 0.3, course: 0, courseAccuracy: 5,
            decision: "accept"
        ))

        // Simulated success: delete only the ids we actually uploaded.
        db.deleteDiagnostics(ids: batch.map { $0.id })

        let remaining = db.fetchDiagnosticsBatch(limit: 100)
        XCTAssertEqual(remaining.count, 1, "the fix written during upload must survive")
    }

    // MARK: - retention

    func testCleanupDiagnosticsPrunesOldRowsOnly() {
        let db = makeDatabase()
        // Note: cleanupDiagnostics uses *wall-clock* `logged_at`, not the
        // caller-provided fix_timestamp. Since logDiagnostic stamps
        // `Date()` at write time, in this test every row has a fresh
        // logged_at and 0 rows should be pruned by a 3-day cleanup — which
        // is exactly the behavior SyncService relies on (fresh rows must
        // survive long enough to get uploaded).
        for _ in 0..<5 {
            db.logDiagnostic(FixDiagnostic(
                fixTimestamp: Date(),
                latitude: 0, longitude: 0,
                horizontalAccuracy: 5, verticalAccuracy: 5, altitude: 0,
                speed: 1, speedAccuracy: 0.3, course: 0, courseAccuracy: 5,
                decision: "accept"
            ))
        }
        db.cleanupDiagnostics(olderThanDays: 3)
        XCTAssertEqual(
            db.fetchDiagnosticsBatch(limit: 100).count, 5,
            "cleanup must not touch rows logged within the retention window"
        )
    }
}
