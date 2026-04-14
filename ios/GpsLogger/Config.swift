import Foundation
import CoreLocation

enum Config {
    /// Backend base URL.
    /// Must be your Mac's LAN IP (System Settings → Network → Wi-Fi → Details → TCP/IP).
    /// - Works for both iOS Simulator (shares the Mac's network stack) and physical iPhone
    ///   (iPhone must be on the same Wi-Fi).
    /// - Update this when you move to a different network.
    static let apiBaseURL = URL(string: "http://192.168.1.129:3000")!

    /// Sync timer interval. Spec allows 30–60s.
    static let syncIntervalSeconds: TimeInterval = 30

    /// Max points uploaded per request.
    static let syncBatchSize = 100

    /// Minimum distance between saved points, in meters.
    static let minDistanceMeters: CLLocationDistance = 10
}
