import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var tracker: LocationTracker

    /// Hidden-entry tap accumulator for the unsynced-points counter.
    /// Ten taps within the rolling window open the Auto Wake settings
    /// sheet; the count resets on present, on a stray gap, and on
    /// every cold launch (the state is `@State`, not persisted).
    /// Local to this view because the gesture has no meaning anywhere
    /// else in the app.
    @State private var counterTapCount = 0
    @State private var lastCounterTap: Date?
    @State private var showAutoWakeSettings = false

    /// Maximum gap between consecutive taps that still counts as
    /// "in a row". Tuned so a deliberate 10-tap sequence completes
    /// comfortably (~3–5 s for a normal cadence) while a stray tap
    /// minutes later does not creep the counter forward. 1.5 s is
    /// well above the iOS default double-tap interval (~0.25 s) so
    /// it does not interfere with system accessibility gestures.
    private static let tapWindow: TimeInterval = 1.5

    /// Number of taps required to open the hidden settings sheet.
    /// Deliberate friction: high enough that no normal interaction
    /// with the counter (it is otherwise read-only) reaches it, low
    /// enough that an informed user can perform it without timing out.
    private static let tapsToReveal = 10

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
                // `contentShape(Rectangle())` so the entire VStack
                // bounding box receives taps, not just the glyphs.
                // Without it, taps in the gap between the number and
                // the label would miss.
                .contentShape(Rectangle())
                .onTapGesture { handleCounterTap() }

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
        .sheet(isPresented: $showAutoWakeSettings) {
            AutoWakeSettingsView()
                .environmentObject(tracker)
        }
    }

    /// Tap handler for the unsynced-points counter. Resets the
    /// rolling counter if the gap since the previous tap exceeds
    /// `tapWindow`, otherwise increments. On reaching `tapsToReveal`
    /// it presents the hidden settings sheet and clears the
    /// accumulator so the next reveal requires a fresh sequence.
    private func handleCounterTap() {
        let now = Date()
        let gap = lastCounterTap.map { now.timeIntervalSince($0) } ?? .infinity
        counterTapCount = (gap > Self.tapWindow) ? 1 : counterTapCount + 1
        lastCounterTap = now
        if counterTapCount >= Self.tapsToReveal {
            counterTapCount = 0
            lastCounterTap = nil
            showAutoWakeSettings = true
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

// MARK: - Auto Wake settings (hidden sheet)

/// Hidden settings sheet reachable only via the 10-tap gesture on the
/// unsynced-points counter in `ContentView`. Single-purpose UI: one
/// toggle wired to `LocationTracker.setAutoWakeEnabled(_:)`. The
/// toggle's side effect is the actual `start...` /
/// `stopMonitoringSignificantLocationChanges()` call on the
/// dedicated `wakeMonitor` `CLLocationManager`, so OFF is a real
/// OS-level disable and not just a UI flag (see the doc comment on
/// `LocationTracker.applyAutoWakeSetting`). Footer copy spells out
/// that disabling does **not** stop normal tracking — opening the
/// app manually still starts always-on GPS.
private struct AutoWakeSettingsView: View {
    @EnvironmentObject var tracker: LocationTracker
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    // Plain text section — surfaces the description
                    // without the form-section header's caps + tint.
                    Text("Allows the app to resume automatically after significant movement.")
                        .font(.callout)
                        .foregroundColor(.primary)
                }

                Section {
                    Toggle("Auto Wake", isOn: Binding(
                        get: { tracker.autoWakeEnabled },
                        set: { tracker.setAutoWakeEnabled($0) }
                    ))
                } footer: {
                    Text("When disabled, the app will not try to wake itself automatically. Opening the app manually will still start tracking.")
                }
            }
            .navigationTitle("Auto Wake")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
