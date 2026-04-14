import Foundation

/// Single owner of all app-level singletons.
/// Built once on first access. Guarantees one Database, one AppState, one LocationTracker,
/// and one SyncService for the entire app lifetime. `shared` is accessed from SwiftUI
/// `@StateObject` property initializers, which run on the main thread.
final class AppContainer {
    static let shared = AppContainer()

    let database: Database
    let appState: AppState
    let tracker: LocationTracker
    let sync: SyncService

    private init() {
        let db = Database()
        let state = AppState()
        state.seed(db.initialCount())

        self.database = db
        self.appState = state
        self.tracker = LocationTracker(database: db, appState: state)
        self.sync = SyncService(database: db, appState: state)

        // Sync runs for the entire app lifetime so leftover points from
        // previous sessions drain even before the user presses Start again.
        self.sync.start()
    }
}
