import Foundation
import CoreLocation
import Combine

/// Thin wrapper around CLLocationManager.
/// - No timers. Points are stored purely in response to CoreLocation callbacks.
/// - Minimum distance filter of `Config.minDistanceMeters` is applied both at the
///   CoreLocation level (`distanceFilter`) and defensively in `didUpdateLocations`
///   to ignore any residual short deltas.
final class LocationTracker: NSObject, ObservableObject {
    @Published private(set) var isTracking = false
    @Published private(set) var authStatus: CLAuthorizationStatus

    private let manager = CLLocationManager()
    private let database: Database
    private let appState: AppState

    private var lastSavedLocation: CLLocation?

    init(database: Database, appState: AppState) {
        self.database = database
        self.appState = appState
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

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            // Permission request is async — actual start happens in the delegate callback.
            manager.requestAlwaysAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            beginUpdates()
        case .denied, .restricted:
            print("[tracker] location permission denied")
        @unknown default:
            break
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        DispatchQueue.main.async { [weak self] in
            self?.isTracking = false
        }
        lastSavedLocation = nil
    }

    private func beginUpdates() {
        manager.startUpdatingLocation()
        DispatchQueue.main.async { [weak self] in
            self?.isTracking = true
        }
    }
}

extension LocationTracker: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        DispatchQueue.main.async { [weak self] in
            self?.authStatus = status
        }

        // If the user just granted permission after pressing Start, kick off updates.
        if !isTracking,
           status == .authorizedAlways || status == .authorizedWhenInUse {
            beginUpdates()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for loc in locations {
            // Skip invalid fixes.
            guard loc.horizontalAccuracy > 0 else { continue }

            // Distance filter — redundant with CLLocationManager.distanceFilter,
            // kept as defense-in-depth.
            if let last = lastSavedLocation,
               loc.distance(from: last) < Config.minDistanceMeters {
                continue
            }

            lastSavedLocation = loc
            database.insert(
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude,
                createdAt: loc.timestamp
            )

            DispatchQueue.main.async { [weak self] in
                self?.appState.unsyncedCount += 1
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[tracker] error: \(error.localizedDescription)")
    }
}
