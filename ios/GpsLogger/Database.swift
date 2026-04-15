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

/// Raw CLLocation snapshot + filter decision for post-hoc diagnosis of GPS
/// anomalies. Decoupled from CoreLocation so `Database` stays Foundation-only.
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

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let path = docs.appendingPathComponent("gpslogger.sqlite").path

        if sqlite3_open(path, &db) != SQLITE_OK {
            let err = String(cString: sqlite3_errmsg(db))
            fatalError("sqlite open failed: \(err)")
        }

        // --- points (upload queue) ---
        exec("""
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
        exec("""
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

    // MARK: - points

    func insert(latitude: Double, longitude: Double, createdAt: Date) {
        let iso = ISO8601Formatter.shared.string(from: createdAt)
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            let sql = "INSERT INTO points (latitude, longitude, created_at) VALUES (?, ?, ?);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                print("[db] insert prepare failed: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
            sqlite3_bind_double(stmt, 1, latitude)
            sqlite3_bind_double(stmt, 2, longitude)
            sqlite3_bind_text(stmt, 3, iso, -1, SQLITE_TRANSIENT)

            if sqlite3_step(stmt) != SQLITE_DONE {
                print("[db] insert step failed: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    func fetchBatch(limit: Int) -> [LocalPoint] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            let sql = "SELECT id, latitude, longitude, created_at FROM points ORDER BY id ASC LIMIT ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return []
            }
            sqlite3_bind_int(stmt, 1, Int32(limit))

            var result: [LocalPoint] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let lat = sqlite3_column_double(stmt, 1)
                let lng = sqlite3_column_double(stmt, 2)
                let cstrIso = sqlite3_column_text(stmt, 3)
                let iso = cstrIso != nil ? String(cString: cstrIso!) : ""
                result.append(LocalPoint(id: id, latitude: lat, longitude: lng, createdAt: iso))
            }
            return result
        }
    }

    func delete(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        queue.sync {
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let sql = "DELETE FROM points WHERE id IN (\(placeholders));"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                print("[db] delete prepare failed: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
            for (i, id) in ids.enumerated() {
                sqlite3_bind_int64(stmt, Int32(i + 1), id)
            }
            if sqlite3_step(stmt) != SQLITE_DONE {
                print("[db] delete step failed: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    /// One-time count used to seed the in-memory unsynced counter at launch.
    /// Not called during normal operation — the in-memory counter is authoritative after init.
    func initialCount() -> Int {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM points;", -1, &stmt, nil) == SQLITE_OK else {
                return 0
            }
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int64(stmt, 0))
            }
            return 0
        }
    }

    // MARK: - fix_diagnostics

    /// Record a raw fix + its filter decision. Used only for offline analysis
    /// of anomalies; never touched by the upload path.
    func logDiagnostic(_ d: FixDiagnostic) {
        let loggedAt = ISO8601Formatter.shared.string(from: Date())
        let fixIso = ISO8601Formatter.shared.string(from: d.fixTimestamp)
        queue.sync {
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
                return
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
            }
        }
    }

    /// Prune diagnostic rows older than `days` from now. Cheap via the
    /// `idx_fix_diagnostics_logged_at` index; safe to call on every launch.
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
