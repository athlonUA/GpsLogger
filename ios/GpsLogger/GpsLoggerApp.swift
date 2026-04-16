import SwiftUI
import BackgroundTasks

@main
struct GpsLoggerApp: App {
    @StateObject private var appState = AppContainer.shared.appState
    @StateObject private var tracker = AppContainer.shared.tracker
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // `BGTaskScheduler.register(forTaskWithIdentifier:)` must run
        // before application launch completes. For a pure SwiftUI-lifecycle
        // app that means the `App` struct initializer — there is no
        // UIApplicationDelegate to hang this off. The handler closure is
        // invoked by iOS on a background thread when it decides to wake
        // the app for a refresh; the actual drain is delegated to
        // `SyncService.drainOnce` so the logic stays in one place.
        //
        // The paired `UIBackgroundModes = ["fetch"]` entry and the
        // `BGTaskSchedulerPermittedIdentifiers = [Config.backgroundRefreshTaskId]`
        // entry are declared in `project.yml` and emitted into the
        // generated Info.plist by xcodegen.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Config.backgroundRefreshTaskId,
            using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handleBackgroundRefresh(refresh)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(tracker)
        }
        .onChange(of: scenePhase) { phase in
            // Queue the next refresh on every background transition. Calls
            // to `submit` replace any existing pending request for the same
            // identifier, so it is safe to call this repeatedly.
            if phase == .background {
                Self.scheduleBackgroundRefresh()
            }
        }
    }

    /// Enqueue the next `BGAppRefreshTaskRequest`. Failures are logged but
    /// otherwise ignored: the foreground `Timer` in `SyncService` keeps
    /// working, and the next background transition will retry the submit.
    private static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Config.backgroundRefreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Config.backgroundRefreshMinInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            #if DEBUG
            print("[bg] submit failed: \(error.localizedDescription)")
            #endif
        }
    }

    /// Handler body for the BGAppRefreshTask. Order matters:
    ///   1. Submit the NEXT refresh first — even if the drain times out
    ///      or throws, we always want another opportunity later.
    ///   2. Install an expiration handler so iOS gets a clean completion
    ///      signal if it reclaims our runtime mid-flight.
    ///   3. Trigger a one-shot drain and mark the task completed when it
    ///      finishes.
    ///
    /// The drain's correctness under mid-flight termination is guaranteed
    /// by the server-side idempotency contract documented in
    /// `SyncService`: a replayed batch is a no-op at the INSERT layer.
    private static func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()
        let sync = AppContainer.shared.sync
        task.expirationHandler = {
            // No explicit cancel of the URLSession — the in-flight request
            // is tolerant of process death thanks to server idempotency,
            // and cancelling explicitly would just leave local rows in the
            // queue that the server already has. Signal expiration to iOS
            // so it stops counting our runtime.
            task.setTaskCompleted(success: false)
        }
        sync.drainOnce {
            task.setTaskCompleted(success: true)
        }
    }
}
