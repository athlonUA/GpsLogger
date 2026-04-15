import Foundation

/// Single owner of all app-level singletons.
///
/// Built once on first access. Guarantees one `Database`, one `AppState`,
/// one `LocationTracker`, and one `SyncService` for the entire app lifetime.
/// `shared` is accessed from SwiftUI `@StateObject` property initializers,
/// which run on the main thread, so construction is main-thread-safe by
/// construction.
///
/// Boot sequence:
///   1. Open/migrate the local SQLite store (drops legacy `device_id` column
///      on `points` if present; creates `fix_diagnostics` if missing).
///   2. Resolve the stable device identity (Keychain → UserDefaults → new UUID).
///   3. Seed the in-memory unsynced counter and publish the device ID.
///   4. Prune diagnostic rows older than the retention window.
///   5. Start the tracker (always-on for the full app lifetime).
///   6. Start the sync loop so any leftover points drain immediately.
final class AppContainer {
    static let shared = AppContainer()

    /// Local retention window for `fix_diagnostics`, as a safety net against
    /// prolonged backend outages. Under normal operation rows are deleted
    /// within a single 30 s sync tick of being written, so this almost never
    /// has work to do — 3 days is enough headroom to survive a weekend of
    /// backend downtime without letting the local DB balloon.
    private static let diagnosticRetentionDays = 3

    let database: Database
    let appState: AppState
    let tracker: LocationTracker
    let sync: SyncService

    private init() {
        let db = Database()
        let state = AppState()
        let deviceId = DeviceIdentity.get()

        state.seed(db.initialCount())
        state.deviceId = deviceId
        db.cleanupDiagnostics(olderThanDays: Self.diagnosticRetentionDays)

        self.database = db
        self.appState = state
        self.tracker = LocationTracker(database: db, appState: state)
        self.sync = SyncService(database: db, appState: state, deviceId: deviceId)

        // Always-on tracking: there is no user-facing Start/Stop.
        self.tracker.start()
        self.sync.start()
    }
}
