import Foundation
import CoreMotion

/// Thin wrapper around `CMMotionActivityManager` that emits a coarse
/// transportation-mode recommendation (pedestrian / cycling / automotive /
/// unknown) based on the phone's inertial sensors. Used by
/// `LocationTracker` to swap `CLLocationManager.activityType` at runtime
/// so a single install can track walking, cycling, and motorized transport
/// (car, bus, train) without a user-facing mode toggle.
///
/// Design notes:
/// - **The classification itself is a pure static function**
///   (`MotionClassifier.classify(...)`). Everything CoreMotion-specific is
///   kept out of it, so the decision logic can be unit-tested without
///   constructing `CMMotionActivity` instances (which have no public
///   initializer on iOS 16).
/// - **Low-confidence readings are dropped.** CoreMotion may emit
///   borderline `walking && automotive` combinations while the user is
///   settling into a new mode; rejecting `confidence == .low` prevents
///   thrashing between activityTypes on every reading.
/// - **Falls back silently on permission denial or unavailability.** If
///   `CMMotionActivityManager.isActivityAvailable()` is false or the user
///   declines the Motion & Fitness permission, `start()` is a no-op and
///   `currentMode` stays `.unknown` — `LocationTracker` will simply keep
///   its default `.fitness` hint, matching the pre-1.2 behavior.
/// - **Not the load-bearing defense.** CoreLocation's `activityType` is a
///   *hint* — it biases fusion and road-snapping, but it does not by
///   itself accept or reject fixes. The real defense against bad data
///   remains `LocationFilter`'s source gate (`speed ≥ 0`, `vAcc > 0`),
///   which works identically across all modes.
final class MotionClassifier {
    enum Mode: Equatable {
        /// Walking, running, or stationary near a walking episode.
        case pedestrian
        /// Cycling (detected by the periodic pedaling motion).
        case cycling
        /// Any motor vehicle — CoreMotion does not distinguish car from bus
        /// from train, and for our purposes the `.automotiveNavigation`
        /// hint is correct for all three.
        case automotive
        /// No confident reading yet, or fully stationary without a prior
        /// activity bias. `LocationTracker` keeps whatever hint was last
        /// applied (default at startup is `.fitness`).
        case unknown
    }

    /// Reason the classifier might be unavailable at runtime, reported via
    /// `onAvailabilityChange` so the app can surface a UI hint ("motion
    /// sensing denied — multi-modal tracking is disabled").
    enum UnavailabilityReason {
        /// `CMMotionActivityManager.isActivityAvailable()` returned false
        /// — the device has no motion coprocessor. Effectively impossible
        /// on any iOS 16+ iPhone but handled defensively.
        case hardwareUnavailable
        /// User denied the Motion & Fitness permission (or parental
        /// controls restricted it). CoreMotion will silently deliver no
        /// data; we don't try to start updates.
        case permissionDenied
    }

    /// Latest emitted mode. Writes happen only on the main queue (same
    /// queue CoreMotion delivers callbacks to), so single-threaded reads
    /// from the main thread are safe without explicit locking.
    private(set) var currentMode: Mode = .unknown

    /// Called on the main queue when the confirmed mode actually changes.
    /// Identical consecutive readings do not re-fire this closure, so
    /// downstream `activityType` writes only happen on real transitions.
    var onModeChange: ((Mode) -> Void)?

    /// Called on the main queue if the classifier cannot start. Allows the
    /// owning `LocationTracker` to surface the situation through its
    /// `TrackingImpairment` channel so the UI can warn the user that
    /// multi-modal classification is disabled for the rest of the session.
    var onUnavailable: ((UnavailabilityReason) -> Void)?

    private let manager = CMMotionActivityManager()

    /// Begin subscribing to CoreMotion activity updates. Idempotent — safe
    /// to call multiple times; subsequent calls are ignored by the
    /// underlying manager if an update session is already active.
    ///
    /// Permission handling: CoreMotion does not have an explicit
    /// `requestAuthorization` API — the first call to `startActivityUpdates`
    /// triggers an implicit system prompt. We check
    /// `CMMotionActivityManager.authorizationStatus()` first so that a
    /// previously-denied permission results in a clean no-op plus an
    /// `onUnavailable(.permissionDenied)` callback, instead of silently
    /// starting a subscription that never receives data.
    func start() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            #if DEBUG
            print("[motion] activity manager not available on this device")
            #endif
            onUnavailable?(.hardwareUnavailable)
            return
        }

        let status = CMMotionActivityManager.authorizationStatus()
        switch status {
        case .denied, .restricted:
            #if DEBUG
            print("[motion] authorization=\(status.rawValue) — starting would be a no-op")
            #endif
            onUnavailable?(.permissionDenied)
            return
        case .notDetermined, .authorized:
            break // proceed — .notDetermined will trigger the prompt implicitly
        @unknown default:
            break
        }

        manager.startActivityUpdates(to: OperationQueue.main) { [weak self] activity in
            guard let self = self, let activity = activity else { return }
            guard let nextMode = Self.classify(
                automotive: activity.automotive,
                cycling: activity.cycling,
                walking: activity.walking,
                running: activity.running,
                confidence: activity.confidence
            ) else {
                return // low-confidence reading, hold previous mode
            }
            if nextMode != self.currentMode {
                self.currentMode = nextMode
                #if DEBUG
                print("[motion] mode -> \(nextMode)")
                #endif
                self.onModeChange?(nextMode)
            }
        }
    }

    func stop() {
        manager.stopActivityUpdates()
    }

    /// Pure classification rule. Exposed as `static` and parameterised over
    /// primitive types so unit tests do not need a real `CMMotionActivity`.
    ///
    /// Returns:
    /// - `nil` when the reading is low-confidence (caller should keep the
    ///   previous mode and avoid thrashing the activity type).
    /// - `.automotive` > `.cycling` > `.pedestrian` > `.unknown` in
    ///   priority order when multiple flags are set. CoreMotion sometimes
    ///   reports overlapping flags during transitions (e.g.
    ///   `walking && automotive` as the user gets out of a car); the
    ///   `.automotive` preference means we stay on the vehicle hint until
    ///   CoreMotion is confident the user is purely walking again.
    static func classify(
        automotive: Bool,
        cycling: Bool,
        walking: Bool,
        running: Bool,
        confidence: CMMotionActivityConfidence
    ) -> Mode? {
        guard confidence != .low else { return nil }
        if automotive { return .automotive }
        if cycling { return .cycling }
        if walking || running { return .pedestrian }
        return .unknown
    }
}
