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

    func seed(_ count: Int) {
        unsyncedCount = count
    }
}
