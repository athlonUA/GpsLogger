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

/// Thread-safe SQLite store for unsynced GPS points.
/// Uses raw sqlite3 — no external dependencies, no SPM packages.
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

        exec("""
            CREATE TABLE IF NOT EXISTS points (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                latitude REAL NOT NULL,
                longitude REAL NOT NULL,
                created_at TEXT NOT NULL
            );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_points_created_at ON points(created_at);")
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
                let cstr = sqlite3_column_text(stmt, 3)
                let iso = cstr != nil ? String(cString: cstr!) : ""
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
}

enum ISO8601Formatter {
    static let shared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
