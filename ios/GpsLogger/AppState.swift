import Foundation
import Combine

/// Minimal shared UI state.
///
/// - `unsyncedCount` is the source of truth for the on-screen counter. Seeded
///   once at launch from the DB, incremented on save, decremented on
///   successful sync. In-memory after seeding.
/// - `deviceId` is set once during container bootstrap from `DeviceIdentity`
///   and never mutated. Published so the UI can display and copy it.
final class AppState: ObservableObject {
    @Published var unsyncedCount: Int = 0
    @Published var deviceId: String = ""

    /// Seed the counter from the DB row count. `nil` means the count
    /// query failed — default to 0 and log a warning so the counter
    /// is at least visible (will self-correct on first sync drain).
    func seed(_ count: Int?) {
        if let count {
            unsyncedCount = count
        } else {
            print("[state] WARNING: initial count unavailable, defaulting to 0")
            unsyncedCount = 0
        }
    }
}
