import Foundation

/// Single owner of all app-level singletons.
///
/// Built once on first access. Guarantees one `Database`, one `AppState`,
/// one `LocationTracker`, and one `SyncService` for the entire app lifetime.
/// `shared` is accessed from SwiftUI `@StateObject` property initializers,
/// which run on the main thread, so construction is main-thread-safe by
/// construction.
///
/// Boot sequence (split into two phases as of 1.2.13):
///
/// **Phase 1 — `init()`**, runs as soon as `shared` is first accessed
/// (which happens when the SwiftUI App's `@StateObject` initializers
/// execute, *before* `application(_:didFinishLaunchingWithOptions:)`):
///   1. Open/migrate the local SQLite store.
///   2. Resolve the stable device identity (Keychain → UserDefaults → UUID).
///   3. Seed the in-memory unsynced counter and publish the device ID.
///   4. Prune diagnostic rows older than the retention window.
///   5. Construct (but do **not** start) the tracker and sync service.
///
/// **Phase 2 — `bootstrap(launchedForLocation:)`**, called from the
/// AppDelegate's `application(_:didFinishLaunchingWithOptions:)` so it
/// has access to the `UIApplicationLaunchOptionsLocationKey` flag:
///   6. Start the tracker, passing the SLC-launch context. Tracker uses
///      this to decide between `.fullTracking` and `.deferred` mode.
///   7. Start the sync loop so any leftover points drain immediately.
///
/// The two-phase split exists because the tracker's mode decision
/// requires authoritative knowledge of *whether iOS launched us
/// because of a location event*, and that signal is only available in
/// the AppDelegate's launchOptions — which fires *after* SwiftUI has
/// already constructed the `@StateObject`s. Keeping init() lightweight
/// and starting the tracker explicitly from the AppDelegate is the
/// clean way to thread that signal through without resorting to a
/// global mutable flag.
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

    /// Once-per-process guard so a second AppDelegate callback (or a
    /// rogue test setup) cannot start the tracker / sync loop twice.
    /// `tracker.start` and `sync.start` both have idempotency at their
    /// own layer, but tracking that here makes the contract obvious
    /// at the call site.
    private var didBootstrap = false

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
    }

    /// Phase-2 startup. Called from the AppDelegate's
    /// `application(_:didFinishLaunchingWithOptions:)`. The
    /// `launchedForLocation` parameter mirrors
    /// `launchOptions[.location] != nil` and tells the tracker
    /// whether iOS spawned this process to deliver a SLC event (in
    /// which case the tracker considers the deferred-mode entry) or
    /// the user opened the app (in which case the tracker enters
    /// full-tracking immediately).
    func bootstrap(launchedForLocation: Bool) {
        guard !didBootstrap else { return }
        didBootstrap = true
        tracker.start(launchedForLocation: launchedForLocation)
        sync.start()
    }
}
