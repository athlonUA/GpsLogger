import Foundation
import CoreLocation

enum Config {
    /// Backend base URL.
    /// - **iOS Simulator**: `http://localhost:3000` works out of the box —
    ///   the simulator shares the Mac's network stack.
    /// - **Physical iPhone**: replace with your Mac's LAN IP
    ///   (System Settings → Network → Wi-Fi → Details → TCP/IP),
    ///   e.g. `http://192.168.1.25:3000`. Mac and iPhone must share the
    ///   same Wi-Fi. If you move to a different network, update this value.
    static let apiBaseURL = URL(string: "http://localhost:3000")!

    /// Sync timer interval. Spec allows 30–60s.
    static let syncIntervalSeconds: TimeInterval = 30

    /// Max points uploaded per request.
    static let syncBatchSize = 100

    /// Minimum distance between saved points, in meters.
    static let minDistanceMeters: CLLocationDistance = 10
}
