import XCTest
@testable import GpsLogger

/// Locks in the Wi-Fi-only sync policy introduced in 1.2.10:
///
///   - The predicate that decides whether a drain may run
///     (`ReachabilitySnapshot.isWifiOnlyReachable`).
///   - The OS-level URLSession configuration that is the second layer of
///     enforcement (`Config.makeSyncSessionConfiguration`).
///   - The diagnostics gate (`Config.syncDiagnosticsEnabled`) — default
///     off, flippable via UserDefaults at runtime.
///
/// These are pure-value tests and do not touch the network, so they run
/// instantly and are safe to keep in the main test bundle.
final class SyncPolicyTests: XCTestCase {

    // MARK: - ReachabilitySnapshot predicate

    func testWifiOnlyReachableRequiresAllFourConditions() {
        // Happy path: on Wi-Fi, not expensive, not constrained.
        let ok = ReachabilitySnapshot(
            isSatisfied: true, usesWifi: true,
            isExpensive: false, isConstrained: false
        )
        XCTAssertTrue(ok.isWifiOnlyReachable)
    }

    func testPessimisticSnapshotIsNotReachable() {
        XCTAssertFalse(ReachabilitySnapshot.pessimistic.isWifiOnlyReachable,
                       "before NWPathMonitor publishes, we must be offline-by-default")
    }

    func testCellularPathIsRejected() {
        // Cellular: satisfied + !wifi + expensive. Must be rejected so we
        // don't burn LTE/5G data or battery on a doomed LAN request.
        let cellular = ReachabilitySnapshot(
            isSatisfied: true, usesWifi: false,
            isExpensive: true, isConstrained: false
        )
        XCTAssertFalse(cellular.isWifiOnlyReachable)
    }

    func testPersonalHotspotIsRejected() {
        // Personal hotspot / tethered modem: iOS flags the interface as
        // Wi-Fi (the phone IS connecting over Wi-Fi to the peer) but also
        // marks it `isExpensive = true`. Refuse so we don't drain the
        // peer's cellular budget.
        let hotspot = ReachabilitySnapshot(
            isSatisfied: true, usesWifi: true,
            isExpensive: true, isConstrained: false
        )
        XCTAssertFalse(hotspot.isWifiOnlyReachable)
    }

    func testLowDataModeIsRejected() {
        // Low Data Mode: the user has explicitly asked the OS to back off.
        // Even on Wi-Fi we respect it.
        let lowData = ReachabilitySnapshot(
            isSatisfied: true, usesWifi: true,
            isExpensive: false, isConstrained: true
        )
        XCTAssertFalse(lowData.isWifiOnlyReachable)
    }

    func testUnsatisfiedPathIsRejected() {
        // Airplane mode / no interface up at all.
        let offline = ReachabilitySnapshot(
            isSatisfied: false, usesWifi: true,
            isExpensive: false, isConstrained: false
        )
        XCTAssertFalse(offline.isWifiOnlyReachable)
    }

    func testWiredNonWifiPathIsRejected() {
        // A wired (Ethernet-over-USB) or loopback-only default route —
        // NWPath marks it satisfied but `usesInterfaceType(.wifi)` is
        // false. We only enable uploads on true Wi-Fi, so reject.
        let wired = ReachabilitySnapshot(
            isSatisfied: true, usesWifi: false,
            isExpensive: false, isConstrained: false
        )
        XCTAssertFalse(wired.isWifiOnlyReachable)
    }

    // MARK: - URLSession configuration

    func testSyncSessionConfigurationDisallowsCellularAndExpensive() {
        // The OS-level half of the Wi-Fi-only policy. If the predicate
        // ever misfires, these flags still prevent iOS from carrying the
        // traffic. This test is the regression guard against anyone
        // flipping them back to the defaults during a refactor.
        let cfg = Config.makeSyncSessionConfiguration()
        XCTAssertFalse(cfg.allowsCellularAccess,
                       "LTE/5G uploads are forbidden by product policy")
        XCTAssertFalse(cfg.allowsExpensiveNetworkAccess,
                       "personal hotspot / tether uploads are forbidden")
        XCTAssertFalse(cfg.allowsConstrainedNetworkAccess,
                       "Low Data Mode respects the user's explicit back-off")
        XCTAssertFalse(cfg.waitsForConnectivity,
                       "don't queue a request waiting for Wi-Fi — the next tick will try again")
        XCTAssertEqual(cfg.timeoutIntervalForRequest,
                       Config.syncRequestTimeoutSeconds)
    }

    // MARK: - Diagnostics gate

    func testSyncDiagnosticsDisabledByDefault() {
        // Ensure no lingering test pollution in standard defaults.
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Config.syncDiagnosticsEnabledKey)
        XCTAssertFalse(Config.syncDiagnosticsEnabled,
                       "fix_diagnostics is debug scaffolding — off by default in 1.2.10")
    }

    func testSyncDiagnosticsHonorsUserDefaultsOverride() {
        let defaults = UserDefaults.standard
        let key = Config.syncDiagnosticsEnabledKey
        // Save + restore so this test doesn't bleed into sibling tests.
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.set(true, forKey: key)
        XCTAssertTrue(Config.syncDiagnosticsEnabled,
                      "runtime override (defaults write …) must take effect without rebuild")
    }
}
