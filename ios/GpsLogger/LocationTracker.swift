import Foundation
import CoreLocation
import Combine

/// Thin wrapper around CLLocationManager.
///
/// - No timers. Points are stored purely in response to CoreLocation callbacks.
/// - Raw CLLocation samples pass through `LocationFilter` first (validity,
///   source discrimination, accuracy, speed, spike buffer — see
///   `LocationFilter.swift`), then through `StationaryDetector`, which
///   suppresses stationary-jitter clusters without touching the coordinates
///   themselves.
/// - Always-on: `start()` is invoked once during container bootstrap and the
///   tracker runs for the full app lifetime. There is no user-facing Stop;
///   CoreLocation only ceases when the OS terminates the process.
/// - Device identity is owned by `SyncService` and stamped on the upload
///   payload, not on individual rows — it's a property of the install, not
///   of each fix.
/// - **Multi-modal `activityType`**: the hint passed to CoreLocation is
///   swapped at runtime from `.fitness` to `.automotiveNavigation` based on
///   `MotionClassifier`'s reading of the phone's inertial sensors. Walking
///   and cycling use `.fitness`, motorized transport (car, bus, train) uses
///   `.automotiveNavigation`, and the default on startup — before CoreMotion
///   has had time to classify — is `.fitness`. See `MotionClassifier.swift`.
final class LocationTracker: NSObject, ObservableObject {
    @Published private(set) var isTracking = false
    @Published private(set) var authStatus: CLAuthorizationStatus
    @Published private(set) var motionMode: MotionClassifier.Mode = .unknown

    private let manager = CLLocationManager()
    private let database: Database
    private let appState: AppState

    private var filter = LocationFilter()
    private var stationary = StationaryDetector()
    private let classifier = MotionClassifier()

    init(database: Database, appState: AppState) {
        self.database = database
        self.appState = appState
        self.authStatus = manager.authorizationStatus
        super.init()

        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // Startup default: pedestrian hint. `MotionClassifier` will flip
        // this to `.automotiveNavigation` once it detects a motor vehicle
        // with medium/high confidence. The previous hard-coded
        // `.automotiveNavigation` was a semantic mismatch for walkers and
        // biased the fusion engine toward vehicle motion models in
        // degraded-signal environments.
        manager.activityType = .fitness
        manager.distanceFilter = Config.minDistanceMeters
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true

        classifier.onModeChange = { [weak self] mode in
            self?.apply(mode: mode)
        }
        classifier.start()
    }

    /// Kick off tracking. Called once from `AppContainer` at launch.
    /// If authorization is not yet granted, the request is issued and
    /// `locationManagerDidChangeAuthorization` will call `beginUpdates` once
    /// the user responds.
    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            beginUpdates()
        case .denied, .restricted:
            print("[tracker] location permission denied")
        @unknown default:
            break
        }
    }

    private func beginUpdates() {
        manager.startUpdatingLocation()
        DispatchQueue.main.async { [weak self] in
            self?.isTracking = true
        }
    }

    /// Map a `MotionClassifier.Mode` to the `CLActivityType` hint used by
    /// CoreLocation's fusion engine, and apply it if it actually changes.
    /// Called on the main queue because `MotionClassifier` delivers
    /// updates there.
    ///
    /// Mapping rationale:
    /// - `.pedestrian` / `.cycling` → `.fitness` (Apple's documented hint
    ///   for walking/running/cycling).
    /// - `.automotive` → `.automotiveNavigation` (correct for car, bus,
    ///   and train — CoreMotion does not distinguish between them).
    /// - `.unknown` is intentionally left as a no-op: if CoreMotion can't
    ///   classify (stationary, low confidence, permission denied), we
    ///   keep whatever hint was last applied instead of flapping back to
    ///   the default on every ambiguous reading.
    private func apply(mode: MotionClassifier.Mode) {
        DispatchQueue.main.async { [weak self] in
            self?.motionMode = mode
        }

        let target: CLActivityType?
        switch mode {
        case .pedestrian, .cycling:
            target = .fitness
        case .automotive:
            target = .automotiveNavigation
        case .unknown:
            target = nil
        }

        guard let target = target, manager.activityType != target else { return }
        manager.activityType = target
        #if DEBUG
        print("[tracker] activityType -> \(target.rawValue) (\(mode))")
        #endif
    }

    private func persist(_ loc: CLLocation) {
        database.insert(
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            createdAt: loc.timestamp
        )
        DispatchQueue.main.async { [weak self] in
            self?.appState.unsyncedCount += 1
        }
    }

    /// Persist with a final stationary-jitter gate. Every accept path from
    /// `LocationFilter` funnels through here so stationary suppression is
    /// applied uniformly to direct accepts, spike replacements, and
    /// committed-pending emissions.
    private func maybePersist(_ loc: CLLocation) {
        switch stationary.consume(loc) {
        case .accept:
            persist(loc)
        case .suppress:
            #if DEBUG
            print("[tracker] suppress stationary @ \(loc.coordinate.latitude),\(loc.coordinate.longitude)")
            #endif
        }
    }

    private func logDiscard(_ reason: LocationFilter.Reason, _ loc: CLLocation) {
        #if DEBUG
        let coord = "\(loc.coordinate.latitude),\(loc.coordinate.longitude)"
        switch reason {
        case .invalidFix:
            print("[tracker] discard invalid @ \(coord)")
        case .nonGpsSource:
            print("[tracker] discard nonGps speed=\(loc.speed) vAcc=\(loc.verticalAccuracy) @ \(coord)")
        case .poorAccuracy(let m):
            print("[tracker] discard accuracy=\(Int(m))m @ \(coord)")
        case .staleTimestamp:
            print("[tracker] discard stale @ \(coord)")
        case .implausibleSpeed(let mps):
            print("[tracker] discard speed=\(Int(mps * 3.6))kmh @ \(coord)")
        case .tooClose:
            break // extremely chatty, and redundant with distanceFilter
        }
        #endif
    }
}

extension LocationTracker: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        DispatchQueue.main.async { [weak self] in
            self?.authStatus = status
        }

        // First-time grant after `requestAlwaysAuthorization()` — kick off updates.
        if !isTracking,
           status == .authorizedAlways || status == .authorizedWhenInUse {
            beginUpdates()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for loc in locations {
            let decision = filter.consume(loc)

            // Debug observability: snapshot every raw fix with its full set of
            // CLLocation fields and the filter verdict. Writes land in
            // `fix_diagnostics`, never in `points`, so the upload path is
            // unaffected. Retention is bounded in `AppContainer`.
            database.logDiagnostic(FixDiagnostic(
                fixTimestamp: loc.timestamp,
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude,
                horizontalAccuracy: loc.horizontalAccuracy,
                verticalAccuracy: loc.verticalAccuracy,
                altitude: loc.altitude,
                speed: loc.speed,
                speedAccuracy: loc.speedAccuracy,
                course: loc.course,
                courseAccuracy: loc.courseAccuracy,
                decision: diagnosticTag(decision)
            ))

            switch decision {
            case .accept(let accepted):
                maybePersist(accepted)

            case .buffered:
                break // waiting for next fix to confirm

            case .discard(let reason):
                logDiscard(reason, loc)

            case .spikeReplaced(let dropped, let accepted):
                #if DEBUG
                print("[tracker] discard spike @ \(dropped.coordinate.latitude),\(dropped.coordinate.longitude)")
                #endif
                if let accepted = accepted {
                    maybePersist(accepted)
                }

            case .committedPending(let pending, let alsoAccept):
                maybePersist(pending)
                if let alsoAccept = alsoAccept {
                    maybePersist(alsoAccept)
                }
            }
        }
    }

    /// Short string tag describing what `LocationFilter` decided about a raw
    /// fix. Used only by `fix_diagnostics` — never affects control flow.
    private func diagnosticTag(_ decision: LocationFilter.Decision) -> String {
        switch decision {
        case .accept: return "accept"
        case .buffered: return "buffered"
        case .spikeReplaced: return "spikeReplaced"
        case .committedPending: return "committedPending"
        case .discard(let reason):
            switch reason {
            case .invalidFix: return "discard:invalidFix"
            case .nonGpsSource: return "discard:nonGpsSource"
            case .poorAccuracy: return "discard:poorAccuracy"
            case .staleTimestamp: return "discard:staleTimestamp"
            case .implausibleSpeed: return "discard:implausibleSpeed"
            case .tooClose: return "discard:tooClose"
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[tracker] error: \(error.localizedDescription)")
    }
}
