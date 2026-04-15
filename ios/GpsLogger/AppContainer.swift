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
///   1. Open/migrate the local SQLite store.
///   2. Resolve the stable device identity (Keychain → UserDefaults → new UUID).
///   3. Backfill any legacy rows with the current device ID.
///   4. Seed the in-memory unsynced counter and publish the device ID.
///   5. Start the tracker (always-on for the full app lifetime).
///   6. Start the sync loop so any leftover points drain immediately.
final class AppContainer {
    static let shared = AppContainer()

    let database: Database
    let appState: AppState
    let tracker: LocationTracker
    let sync: SyncService

    private init() {
        let db = Database()
        let state = AppState()
        let deviceId = DeviceIdentity.get()

        db.backfillDeviceIdIfNeeded(deviceId)
        state.seed(db.initialCount())
        state.deviceId = deviceId

        self.database = db
        self.appState = state
        self.tracker = LocationTracker(database: db, appState: state, deviceId: deviceId)
        self.sync = SyncService(database: db, appState: state)

        // Always-on tracking: there is no user-facing Start/Stop.
        self.tracker.start()
        self.sync.start()
    }
}
