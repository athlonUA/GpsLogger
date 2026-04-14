import Foundation
import Combine

/// Minimal shared UI state.
/// The `unsyncedCount` is the source of truth for the UI counter and lives in memory:
/// - seeded once at launch from the DB
/// - incremented on save
/// - decremented on successful sync
final class AppState: ObservableObject {
    @Published var unsyncedCount: Int = 0

    func seed(_ count: Int) {
        unsyncedCount = count
    }
}
