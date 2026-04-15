import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var tracker: LocationTracker

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                if !tracker.impairments.isEmpty {
                    ImpairmentBanner(impairments: tracker.impairments)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                }

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

                DeviceIdRow(deviceId: appState.deviceId)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)

                Text(Self.versionString)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            TrackingIndicator(isActive: tracker.isTracking)
                .padding(.top, 20)
                .padding(.trailing, 20)
        }
    }

    /// Marketing version + build number from the bundle Info.plist,
    /// formatted as `v1.0 (1)`. Falls back to `?` for either half if the
    /// bundle metadata is somehow missing.
    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let v = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let b = (info?["CFBundleVersion"] as? String) ?? "?"
        return "v\(v) (\(b))"
    }
}

// MARK: - Impairment banner

/// Amber banner shown at the top of the screen whenever
/// `LocationTracker.impairments` contains any entries. Each impairment
/// gets its own line so a partially-denied state (e.g. location ok,
/// motion denied) surfaces clearly. The order is stable because
/// `TrackingImpairment: CaseIterable` returns declaration order.
private struct ImpairmentBanner: View {
    let impairments: Set<LocationTracker.TrackingImpairment>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(LocationTracker.TrackingImpairment.allCases, id: \.self) { imp in
                if impairments.contains(imp) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(imp.shortMessage)
                            .font(.footnote)
                            .foregroundColor(.primary)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15))
        .cornerRadius(8)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Tracking indicator

/// Small status dot in the top-right corner.
///
/// - Green with a subtle pulsing opacity when tracking is active.
/// - Solid gray when inactive (edge case: permission denied or not yet granted).
///
/// The animation is driven by a state flag toggled once on appear / on
/// isActive transitions. Using `.repeatForever` yields a steady breath that
/// is noticeable without being distracting.
private struct TrackingIndicator: View {
    let isActive: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(isActive ? Color.green : Color.gray.opacity(0.5))
            .frame(width: 12, height: 12)
            .opacity(isActive && pulse ? 0.4 : 1.0)
            .animation(
                isActive
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .onAppear { pulse = isActive }
            .onChange(of: isActive, perform: { pulse = $0 })
            .accessibilityLabel(isActive ? "Tracking active" : "Tracking inactive")
    }
}

// MARK: - Device ID row

/// Non-editable display of the stable device identifier with a copy button.
/// The ID is presented in a monospaced, middle-truncated field so the user
/// can recognize it at a glance; tapping the copy icon writes the full value
/// to the pasteboard and flashes a checkmark for visual feedback.
private struct DeviceIdRow: View {
    let deviceId: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Device ID")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            HStack(spacing: 8) {
                Text(deviceId.isEmpty ? "—" : deviceId)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)

                Button {
                    guard !deviceId.isEmpty else { return }
                    UIPasteboard.general.string = deviceId
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(copied ? .green : .primary)
                        .frame(width: 40, height: 40)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy device ID")
            }
        }
    }
}
