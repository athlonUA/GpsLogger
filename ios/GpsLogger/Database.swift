import Foundation
import SQLite3

// sqlite3.h defines these as macros which are not visible to Swift.
// The destructor argument tells SQLite whether to copy the bound string.
//   SQLITE_STATIC    → caller guarantees the pointer outlives the statement
//   SQLITE_TRANSIENT → SQLite copies the string immediately (safe default)
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct LocalPoint {
    let id: Int64
    let latitude: Double
    let longitude: Double
    let createdAt: String   // stored and uploaded verbatim as ISO 8601 UTC
}

/// Raw CLLocation snapshot + filter decision — input to
/// `Database.logDiagnostic`. Decoupled from CoreLocation so `Database` stays
/// Foundation-only.
struct FixDiagnostic {
    let fixTimestamp: Date
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let altitude: Double
    let speed: Double
    let speedAccuracy: Double
    let course: Double
    let courseAccuracy: Double
    let decision: String
}

/// A `fix_diagnostics` row as returned by `Database.fetchDiagnosticsBatch`.
/// Mirrors `LocalPoint`: carries the row id (for later delete-on-success)
/// and stores timestamps as the same ISO 8601 strings used on the wire, so
/// they can be serialised into the upload payload without re-formatting.
struct LocalFixDiagnostic {
    let id: Int64
    let loggedAt: String
    let fixTimestamp: String
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let altitude: Double
    let speed: Double
    let speedAccuracy: Double
    let course: Double
    let courseAccuracy: Double
    let decision: String
}

/// Thread-safe SQLite store. Uses raw sqlite3 — no external dependencies.
///
/// Two tables:
///   - `points` — unsynced GPS points queued for upload. Per-row columns are
///     intentionally minimal: lat, lon, created_at. Device identity is **not**
///     a per-row concern — it's a property of the install, resolved once at
///     bootstrap via `DeviceIdentity` and stamped on the upload payload in
///     `SyncService`. Pre-refactor installs may still have a legacy
///     `device_id` column on the `points` table; it's dropped idempotently on
///     first launch after upgrade.
///   - `fix_diagnostics` — debug/observability table. Every raw CLLocation
///     that enters the tracker pipeline is logged here with the filter's
///     decision, so real-world anomalies (park-canopy, urban-canyon, sensor
///     fusion drift, etc.) can be classified by inspecting the raw fields
///     after the fact. Bounded retention via `cleanupDiagnostics`.
///
/// Data-safety invariants:
///   - `CREATE TABLE IF NOT EXISTS` on every launch, so stores survive app
///     restarts and upgrades without clobber.
///   - Schema migrations are idempotent (guarded on `PRAGMA table_info`).
///   - Points are only ever deleted from `SyncService` after a confirmed
///     2xx upload; no deletion on failure, no overwrite on restart.
final class Database {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "gpslogger.db.queue")

    /// Opens (or creates) the SQLite store at `path`. The default path is
    /// the app's Documents directory; tests pass `":memory:"` or a temp
    /// file to keep each case isolated without touching production state.
    init(path: String? = nil) {
        let actualPath: String
        if let path {
            actualPath = path
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            actualPath = docs.appendingPathComponent("gpslogger.sqlite").path
        }

        if sqlite3_open(actualPath, &db) != SQLITE_OK {
            let err = String(cString: sqlite3_errmsg(db))
            fatalError("sqlite open failed: \(err)")
        }

        // --- points (upload queue) ---
        execRequired("""
            CREATE TABLE IF NOT EXISTS points (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                latitude REAL NOT NULL,
                longitude REAL NOT NULL,
                created_at TEXT NOT NULL
            );
        """)
        // Idempotent drop of the legacy per-row device_id column. SQLite 3.35+
        // supports `ALTER TABLE ... DROP COLUMN`, and iOS 16 (our deployment
        // target) ships with SQLite 3.37+, so this is safe. On pre-refactor
        // installs this drops the column without touching row data; on fresh
        // installs the guard short-circuits and this is a no-op.
        if columnExists(table: "points", column: "device_id") {
            exec("ALTER TABLE points DROP COLUMN device_id;")
        }
        exec("CREATE INDEX IF NOT EXISTS idx_points_created_at ON points(created_at);")

        // --- fix_diagnostics (debug observability) ---
        execRequired("""
            CREATE TABLE IF NOT EXISTS fix_diagnostics (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                logged_at TEXT NOT NULL,
                fix_timestamp TEXT NOT NULL,
                latitude REAL NOT NULL,
                longitude REAL NOT NULL,
                horizontal_accuracy REAL NOT NULL,
                vertical_accuracy REAL NOT NULL,
                altitude REAL NOT NULL,
                speed REAL NOT NULL,
                speed_accuracy REAL NOT NULL,
                course REAL NOT NULL,
                course_accuracy REAL NOT NULL,
                decision TEXT NOT NULL
            );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_fix_diagnostics_logged_at ON fix_diagnostics(logged_at);")

        exec("PRAGMA journal_mode=WAL;")
    }

    deinit {
        if db != nil { sqlite3_close(db) }
    }

    private func exec(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            print("[db] exec error: \(msg) for \(sql)")
        }
    }

    /// Schema-critical exec: crash if the statement fails, because the app
    /// cannot function without its tables. Used only in `init`.
    private func execRequired(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            fatalError("[db] schema exec failed: \(msg) for \(sql)")
        }
    }

    private func columnExists(table: String, column: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "PRAGMA table_info(\(table));"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 1) {
                if String(cString: cstr) == column { return true }
            }
        }
        return false
    }

    // MARK: - Delete chunking helpers
    //
    // `DELETE ... WHERE id IN (?,?,?,...)` interpolates one placeholder per
    // id. SQLite caps `SQLITE_MAX_VARIABLE_NUMBER` at ~32766 (legacy builds
    // were 999); we chunk to 500 per statement which stays under every
    // known limit and keeps individual statements short.
    private static let deleteChunkSize = 500

    /// Whitelisted table name for delete-by-id. The caller passes a string
    /// literal from a small set; the value is interpolated into the SQL
    /// (parameterised binding is not supported for table names). Adding a
    /// new table here requires a conscious change.
    private enum DeletableTable: String {
        case points
        case fixDiagnostics = "fix_diagnostics"
    }

    private func deleteIdsChunk(_ table: DeletableTable, _ ids: ArraySlice<Int64>) {
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = "DELETE FROM \(table.rawValue) WHERE id IN (\(placeholders));"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("[db] delete(\(table.rawValue)) prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        for (offset, id) in ids.enumerated() {
            sqlite3_bind_int64(stmt, Int32(offset + 1), id)
        }
        if sqlite3_step(stmt) != SQLITE_DONE {
            print("[db] delete(\(table.rawValue)) step failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    // MARK: - points

    /// Insert a single point into the local upload queue.
    ///
    /// Returns `true` if the row landed, `false` on any prepare/step
    /// failure. Callers should only mutate the in-memory unsynced counter
    /// when this returns `true`, otherwise the UI counter and the DB row
    /// count drift apart (disk full, schema mismatch, WAL contention).
    @discardableResult
    func insert(latitude: Double, longitude: Double, createdAt: Date) -> Bool {
        let iso = ISO8601Formatter.shared.string(from: createdAt)
        return queue.sync { () -> Bool in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            let sql = "INSERT INTO points (latitude, longitude, created_at) VALUES (?, ?, ?);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                print("[db] insert prepare failed: \(String(cString: sqlite3_errmsg(db)))")
                return false
            }
            // Bind return codes are not checked individually: bad index or
            // out-of-memory manifests as a failing `sqlite3_step` below,
            // which the caller observes via the `Bool` return.
            sqlite3_bind_double(stmt, 1, latitude)
            sqlite3_bind_double(stmt, 2, longitude)
            sqlite3_bind_text(stmt, 3, iso, -1, SQLITE_TRANSIENT)

            if sqlite3_step(stmt) != SQLITE_DONE {
                print("[db] insert step failed: \(String(cString: sqlite3_errmsg(db)))")
                return false
            }
            return true
        }
    }

    func fetchBatch(limit: Int) -> [LocalPoint] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            let sql = "SELECT id, latitude, longitude, created_at FROM points ORDER BY id ASC LIMIT ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                print("[db] fetchBatch prepare failed: \(String(cString: sqlite3_errmsg(db)))")
                return []
            }
            sqlite3_bind_int(stmt, 1, Int32(limit))

            var result: [LocalPoint] = []
            var status = sqlite3_step(stmt)
            while status == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let lat = sqlite3_column_double(stmt, 1)
                let lng = sqlite3_column_double(stmt, 2)
                let cstrIso = sqlite3_column_text(stmt, 3)
                let iso = cstrIso != nil ? String(cString: cstrIso!) : ""
                result.append(LocalPoint(id: id, latitude: lat, longitude: lng, createdAt: iso))
                status = sqlite3_step(stmt)
            }
            if status != SQLITE_DONE {
                // SQLITE_ERROR / SQLITE_BUSY / SQLITE_CORRUPT etc. — the loop
                // exited on a non-row, non-done status. Surface it so the
                // SyncService doesn't conclude "queue is empty" on what is
                // actually a transient I/O or contention failure.
                print("[db] fetchBatch step failed: status=\(status) \(String(cString: sqlite3_errmsg(db)))")
            }
            return result
        }
    }

    /// Remove rows by id after a successful upload. Chunks to at most
    /// `deleteChunkSize` placeholders per prepared statement so an
    /// oversized batch can never exceed SQLite's parameter limit.
    func delete(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        queue.sync {
            for start in stride(from: 0, to: ids.count, by: Self.deleteChunkSize) {
                let end = Swift.min(start + Self.deleteChunkSize, ids.count)
                deleteIdsChunk(.points, ids[start..<end])
            }
        }
    }

    /// One-time count used to seed the in-memory unsynced counter at launch.
    /// Returns `nil` on any SQLite failure so the caller can distinguish
    /// "zero rows" from "query failed".
    func initialCount() -> Int? {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM points;", -1, &stmt, nil) == SQLITE_OK else {
                print("[db] initialCount prepare failed: \(String(cString: sqlite3_errmsg(db)))")
                return nil
            }
            let status = sqlite3_step(stmt)
            if status == SQLITE_ROW {
                return Int(sqlite3_column_int64(stmt, 0))
            }
            print("[db] initialCount step failed: status=\(status) \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
    }

    // MARK: - fix_diagnostics

    /// Record a raw fix + its filter decision. Returns `true` if the row
    /// landed, `false` on any prepare/step failure. Callers use the return
    /// value to decide whether to log a diagnostic failure separately;
    /// they typically don't retry since diagnostic rows are best-effort.
    @discardableResult
    func logDiagnostic(_ d: FixDiagnostic) -> Bool {
        let loggedAt = ISO8601Formatter.shared.string(from: Date())
        let fixIso = ISO8601Formatter.shared.string(from: d.fixTimestamp)
        return queue.sync { () -> Bool in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            let sql = """
                INSERT INTO fix_diagnostics (
                    logged_at, fix_timestamp, latitude, longitude,
                    horizontal_accuracy, vertical_accuracy, altitude,
                    speed, speed_accuracy, course, course_accuracy, decision
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                print("[db] diagnostic prepare failed: \(String(cString: sqlite3_errmsg(db)))")
                return false
            }
            sqlite3_bind_text(stmt, 1, loggedAt, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, fixIso, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, d.latitude)
            sqlite3_bind_double(stmt, 4, d.longitude)
            sqlite3_bind_double(stmt, 5, d.horizontalAccuracy)
            sqlite3_bind_double(stmt, 6, d.verticalAccuracy)
            sqlite3_bind_double(stmt, 7, d.altitude)
            sqlite3_bind_double(stmt, 8, d.speed)
            sqlite3_bind_double(stmt, 9, d.speedAccuracy)
            sqlite3_bind_double(stmt, 10, d.course)
            sqlite3_bind_double(stmt, 11, d.courseAccuracy)
            sqlite3_bind_text(stmt, 12, d.decision, -1, SQLITE_TRANSIENT)

            if sqlite3_step(stmt) != SQLITE_DONE {
                print("[db] diagnostic insert step failed: \(String(cString: sqlite3_errmsg(db)))")
                return false
            }
            return true
        }
    }

    /// Pull the next batch of diagnostic rows pending upload. Same shape as
    /// `fetchBatch` for `points`: cursor by id ascending, delete-by-id on
    /// successful upload. Rows survive restart; on backend downtime they
    /// accumulate up to the retention window.
    func fetchDiagnosticsBatch(limit: Int) -> [LocalFixDiagnostic] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            let sql = """
                SELECT id, logged_at, fix_timestamp, latitude, longitude,
                       horizontal_accuracy, vertical_accuracy, altitude,
                       speed, speed_accuracy, course, course_accuracy, decision
                FROM fix_diagnostics
                ORDER BY id ASC
                LIMIT ?;
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                print("[db] fetchDiagnosticsBatch prepare failed: \(String(cString: sqlite3_errmsg(db)))")
                return []
            }
            sqlite3_bind_int(stmt, 1, Int32(limit))

            var result: [LocalFixDiagnostic] = []
            var status = sqlite3_step(stmt)
            while status == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let loggedAt = Self.readText(stmt, 1)
                let fixTs = Self.readText(stmt, 2)
                let lat = sqlite3_column_double(stmt, 3)
                let lng = sqlite3_column_double(stmt, 4)
                let hAcc = sqlite3_column_double(stmt, 5)
                let vAcc = sqlite3_column_double(stmt, 6)
                let alt = sqlite3_column_double(stmt, 7)
                let spd = sqlite3_column_double(stmt, 8)
                let sAcc = sqlite3_column_double(stmt, 9)
                let crs = sqlite3_column_double(stmt, 10)
                let cAcc = sqlite3_column_double(stmt, 11)
                let decision = Self.readText(stmt, 12)

                result.append(LocalFixDiagnostic(
                    id: id,
                    loggedAt: loggedAt,
                    fixTimestamp: fixTs,
                    latitude: lat,
                    longitude: lng,
                    horizontalAccuracy: hAcc,
                    verticalAccuracy: vAcc,
                    altitude: alt,
                    speed: spd,
                    speedAccuracy: sAcc,
                    course: crs,
                    courseAccuracy: cAcc,
                    decision: decision
                ))
                status = sqlite3_step(stmt)
            }
            if status != SQLITE_DONE {
                print("[db] fetchDiagnosticsBatch step failed: status=\(status) \(String(cString: sqlite3_errmsg(db)))")
            }
            return result
        }
    }

    /// Delete diagnostic rows after a successful backend upload. Uses the
    /// same chunked helper as `delete(ids:)` so either call path is safe
    /// for arbitrarily large batches.
    func deleteDiagnostics(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        queue.sync {
            for start in stride(from: 0, to: ids.count, by: Self.deleteChunkSize) {
                let end = Swift.min(start + Self.deleteChunkSize, ids.count)
                deleteIdsChunk(.fixDiagnostics, ids[start..<end])
            }
        }
    }

    private static func readText(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let cstr = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: cstr)
    }

    /// Prune diagnostic rows older than `days` from now. Safety net for
    /// prolonged backend outages — under normal operation rows are removed
    /// within a sync tick of being written, so this rarely has work to do.
    func cleanupDiagnostics(olderThanDays days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let iso = ISO8601Formatter.shared.string(from: cutoff)
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "DELETE FROM fix_diagnostics WHERE logged_at < ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                print("[db] diagnostic cleanup prepare failed: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
            sqlite3_bind_text(stmt, 1, iso, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) != SQLITE_DONE {
                print("[db] diagnostic cleanup step failed: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }
}

enum ISO8601Formatter {
    static let shared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
