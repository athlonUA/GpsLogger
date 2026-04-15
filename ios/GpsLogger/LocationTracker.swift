import Foundation
import CoreLocation
import Combine

/// Thin wrapper around CLLocationManager.
///
/// - No timers. Points are stored purely in response to CoreLocation callbacks.
/// - Raw CLLocation samples pass through `LocationFilter` before reaching the
///   database (accuracy gate, min-distance gate, relaxed-speed gate, spike
///   buffer — see `LocationFilter.swift`).
/// - Always-on: `start()` is invoked once during container bootstrap and the
///   tracker runs for the full app lifetime. There is no user-facing Stop;
///   CoreLocation only ceases when the OS terminates the process.
/// - Every inserted point is stamped with the stable device ID obtained at
///   bootstrap.
final class LocationTracker: NSObject, ObservableObject {
    @Published private(set) var isTracking = false
    @Published private(set) var authStatus: CLAuthorizationStatus

    private let manager = CLLocationManager()
    private let database: Database
    private let appState: AppState
    private let deviceId: String

    private var filter = LocationFilter()

    init(database: Database, appState: AppState, deviceId: String) {
        self.database = database
        self.appState = appState
        self.deviceId = deviceId
        self.authStatus = manager.authorizationStatus
        super.init()

        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = Config.minDistanceMeters
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
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

    private func persist(_ loc: CLLocation) {
        database.insert(
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            createdAt: loc.timestamp,
            deviceId: deviceId
        )
        DispatchQueue.main.async { [weak self] in
            self?.appState.unsyncedCount += 1
        }
    }

    private func logDiscard(_ reason: LocationFilter.Reason, _ loc: CLLocation) {
        #if DEBUG
        let coord = "\(loc.coordinate.latitude),\(loc.coordinate.longitude)"
        switch reason {
        case .invalidFix:
            print("[tracker] discard invalid @ \(coord)")
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
            switch filter.consume(loc) {
            case .accept(let accepted):
                persist(accepted)

            case .buffered:
                break // waiting for next fix to confirm

            case .discard(let reason):
                logDiscard(reason, loc)

            case .spikeReplaced(let dropped, let accepted):
                #if DEBUG
                print("[tracker] discard spike @ \(dropped.coordinate.latitude),\(dropped.coordinate.longitude)")
                #endif
                if let accepted = accepted {
                    persist(accepted)
                }

            case .committedPending(let pending, let alsoAccept):
                persist(pending)
                if let alsoAccept = alsoAccept {
                    persist(alsoAccept)
                }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[tracker] error: \(error.localizedDescription)")
    }
}
