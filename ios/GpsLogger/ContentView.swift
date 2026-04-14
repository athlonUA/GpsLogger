import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var tracker: LocationTracker

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            VStack(spacing: 8) {
                Text("\(appState.unsyncedCount)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("Unsynced points")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(tracker.isTracking ? "Tracking…" : "Stopped")
                .font(.headline)
                .foregroundColor(tracker.isTracking ? .green : .gray)

            HStack(spacing: 16) {
                Button {
                    tracker.start()
                } label: {
                    Text("Start")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(tracker.isTracking ? Color.gray.opacity(0.3) : Color.green)
                        .foregroundColor(.white)
                        .font(.headline)
                        .cornerRadius(12)
                }
                .disabled(tracker.isTracking)

                Button {
                    tracker.stop()
                } label: {
                    Text("Stop")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(!tracker.isTracking ? Color.gray.opacity(0.3) : Color.red)
                        .foregroundColor(.white)
                        .font(.headline)
                        .cornerRadius(12)
                }
                .disabled(!tracker.isTracking)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .onAppear {
            // Headless test hook: let `xcrun simctl launch` auto-start tracking
            // without a UI tap. Requires location permission to be pre-granted
            // via `xcrun simctl privacy booted grant location-always <bundle>`.
            if CommandLine.arguments.contains("--auto-start") {
                tracker.start()
            }
        }
    }
}
