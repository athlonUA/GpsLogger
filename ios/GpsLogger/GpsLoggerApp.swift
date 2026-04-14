import SwiftUI

@main
struct GpsLoggerApp: App {
    @StateObject private var appState = AppContainer.shared.appState
    @StateObject private var tracker = AppContainer.shared.tracker

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(tracker)
        }
    }
}
