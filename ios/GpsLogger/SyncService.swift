import Foundation
import Network

/// Classification of a single HTTP attempt's outcome. Drives two orthogonal
/// decisions in the sync loop:
///   - Whether to delete the uploaded rows from the local queue (only on
///     `.success`).
///   - Whether to adjust the drain interval (only `.retryable` doubles it;
///     `.success` resets; `.nonRetryable` holds it steady so a client bug
///     can't stretch the interval out to 5 min and then hide indefinitely).
///
/// The `reason` string is DEBUG-log-only and does not leak to the UI.
enum SyncResult {
    case success
    case retryable(String)
    case nonRetryable(String)
}

/// Periodically drains the local DB and POSTs batches to the backend.
///
/// Two upload channels run on the same cadence:
///   - `points` → the production upload queue, drives the visible trace.
///   - `fix_diagnostics` → debug/observability rows, uploaded into the
///     backend `fix_diagnostics` table for post-hoc analysis. Each channel
///     has an independent in-flight guard so a slow response on one does
///     not stall the other.
///
/// All in-flight state (`pointsInFlight`, `diagnosticsInFlight`) and all
/// database access triggered by sync is performed on a **private serial
/// queue** (`syncQueue`). The main-thread `Timer` callback schedules work
/// onto that queue; the URLSession completion handler also hops back onto
/// that queue before touching state. This eliminates the Bool data race
/// that would otherwise occur between main-thread reads and background
/// URLSession completion writes, and keeps main thread free of
/// synchronous SQLite reads via `fetchBatch`.
///
/// Device identity is owned here and stamped onto every upload payload, not
/// written into each row in the local DB. The ID is resolved once at
/// bootstrap (`DeviceIdentity.get()`), injected via `init`, and reused for
/// every request on both channels.
///
/// **Fetch → upload → delete invariant (C4).** The drain sequence per
/// channel is: `fetchBatch` → POST → on 2xx, `database.delete(ids:)`. If
/// the process is killed after the server persists the rows but before the
/// local DELETE commits, the same rows will be re-POSTed on the next
/// drain. Correctness is preserved by the backend's idempotent INSERT —
/// unique `(device_id, created_at)` on `points` / `(device_id,
/// fix_timestamp)` on `fix_diagnostics`, with `ON CONFLICT DO NOTHING`
/// (see `backend/migrations/004_idempotency.sql`). Replayed rows are
/// silently skipped server-side. Any future migration that weakens these
/// constraints must also introduce a two-phase commit here (mark-synced
/// then delete) or it will silently reintroduce duplicate-row risk.
final class SyncService {
    private let database: Database
    private let appState: AppState
    private let deviceId: String
    private let session: URLSession

    /// Serial queue that owns all sync state. Every read or write of
    /// `pointsInFlight` / `diagnosticsInFlight` happens here, including
    /// from URLSession completion handlers (which re-dispatch onto this
    /// queue before touching the flags). `fetchBatch` /
    /// `fetchDiagnosticsBatch` also run here so main thread never blocks
    /// on synchronous SQLite reads during a Timer callback.
    private let syncQueue = DispatchQueue(
        label: "gpslogger.sync.state",
        qos: .utility
    )

    /// Reachability watcher. Avoids burning battery on 15 s URLSession
    /// timeouts when the device has no usable network (airplane mode, no
    /// LAN, captive portal). Updates are delivered on `pathQueue`; reads
    /// happen on `syncQueue`, so `lastPathStatus` is owned by that queue
    /// after being set via `syncQueue.async`.
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(
        label: "gpslogger.sync.path",
        qos: .utility
    )
    /// Last observed path status. Starts pessimistic so the first tick
    /// before the monitor has published anything is a no-op rather than a
    /// doomed 15 s timeout.
    private var lastPathStatus: NWPath.Status = .requiresConnection

    private var timer: Timer?
    private var pointsInFlight = false
    private var diagnosticsInFlight = false

    /// Exponential backoff: doubles on retryable failures, resets to the
    /// base interval on success, holds steady on non-retryable failures
    /// (4xx client bugs — stretching the interval would hide them). Caps
    /// at 300 s (5 min) to bound battery drain when the backend is down
    /// for an extended period.
    private var currentInterval: TimeInterval = Config.syncIntervalSeconds
    private static let maxInterval: TimeInterval = 300

    init(database: Database, appState: AppState, deviceId: String, session: URLSession = .shared) {
        self.database = database
        self.appState = appState
        self.deviceId = deviceId
        self.session = session
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.syncQueue.async { [weak self] in
                self?.lastPathStatus = path.status
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    deinit {
        pathMonitor.cancel()
    }

    func start() {
        stop()
        currentInterval = Config.syncIntervalSeconds
        scheduleTimer()
        // Kick off an immediate attempt so leftover rows drain quickly on launch.
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: currentInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Public entry point for a one-shot drain cycle, used by
    /// `BGAppRefreshTask` when iOS wakes the app in background. Completes
    /// after both channels have finished (drained one batch each, or
    /// skipped because in-flight / empty / offline). Safe to call from any
    /// thread; all work is hopped onto `syncQueue`.
    ///
    /// Intentionally does a single pass per channel (not "drain until
    /// empty"): BGAppRefreshTask gives us ~30 s of runtime, and iOS is
    /// stricter about wall-clock than about wall-clock-minus-URLSession.
    /// One batch is enough for any realistic accumulation between refresh
    /// windows; the next refresh picks up whatever remains.
    func drainOnce(completion: @escaping () -> Void) {
        syncQueue.async { [weak self] in
            guard let self = self else { completion(); return }
            let group = DispatchGroup()
            group.enter()
            self.drainPoints { group.leave() }
            group.enter()
            self.drainDiagnostics { group.leave() }
            group.notify(queue: self.syncQueue) { completion() }
        }
    }

    /// Called from `syncQueue` after a channel's cycle completes. Adjusts
    /// the timer interval based on the result classification.
    private func adjustBackoff(_ result: SyncResult) {
        let newInterval: TimeInterval
        switch result {
        case .success:
            newInterval = Config.syncIntervalSeconds
        case .retryable:
            newInterval = min(currentInterval * 2, Self.maxInterval)
        case .nonRetryable:
            // Hold interval steady. Do NOT backoff — a 4xx is a client
            // bug (stale schema, rotated key, bad URL) that we want to
            // keep retrying at the base cadence so the loud log shows up
            // every 30 s until someone notices, not once every 5 min.
            return
        }
        guard newInterval != currentInterval else { return }
        currentInterval = newInterval
        DispatchQueue.main.async { [weak self] in
            self?.scheduleTimer()
        }
        #if DEBUG
        print("[sync] backoff interval → \(Int(newInterval))s")
        #endif
    }

    private func tick() {
        // Hop onto the serial sync queue before touching any state or
        // reading from the DB. The Timer fires on main; this is where we
        // leave main for the rest of the drain cycle.
        syncQueue.async { [weak self] in
            self?.drainPoints(completion: nil)
            self?.drainDiagnostics(completion: nil)
        }
    }

    /// Runs on `syncQueue`. Returns `false` with a DEBUG log when the
    /// device has no usable network, letting the caller skip the HTTP
    /// attempt entirely. NWPathMonitor's view is coarse (tracks
    /// reachability of any default route, not the specific backend host),
    /// but correctly catches airplane mode / disabled Wi-Fi-and-cellular,
    /// which is the expensive case we care about.
    private func isNetworkReachable() -> Bool {
        lastPathStatus == .satisfied
    }

    // MARK: - points channel

    /// Runs on `syncQueue`. Reads/writes `pointsInFlight` safely because
    /// there is no other producer on this queue. See the class-level
    /// invariant note for why fetch → upload → delete is correct despite
    /// not being atomic.
    private func drainPoints(completion: (() -> Void)?) {
        guard !pointsInFlight else { completion?(); return }
        guard isNetworkReachable() else {
            #if DEBUG
            print("[sync] points: path not satisfied, skipping")
            #endif
            completion?()
            return
        }
        let batch = database.fetchBatch(limit: Config.syncBatchSize)
        guard !batch.isEmpty else { completion?(); return }

        pointsInFlight = true
        let payload: [[String: Any]] = batch.map { p in
            [
                "latitude": p.latitude,
                "longitude": p.longitude,
                "created_at": p.createdAt,
                "device_id": self.deviceId,
            ]
        }
        postJsonBatch(path: "points", payload: payload) { [weak self] result in
            // URLSession completion runs on an unspecified background queue.
            // Hop back onto `syncQueue` so all state mutations stay on a
            // single serial owner — no locks, no torn writes.
            self?.syncQueue.async { [weak self] in
                guard let self = self else { completion?(); return }
                switch result {
                case .success:
                    // Delete only runs on 2xx. A crash between here and the
                    // DELETE committing replays the batch next tick; the
                    // server's ON CONFLICT DO NOTHING absorbs it.
                    let ids = batch.map { $0.id }
                    self.database.delete(ids: ids)
                    let delta = batch.count
                    DispatchQueue.main.async { [weak self] in
                        guard let state = self?.appState else { return }
                        state.unsyncedCount = max(0, state.unsyncedCount - delta)
                    }
                case .retryable(let reason):
                    #if DEBUG
                    print("[sync] points retryable: \(reason)")
                    #endif
                case .nonRetryable(let reason):
                    // Deliberately unconditional print (not DEBUG-only) so a
                    // 4xx regression surfaces on release builds too. The
                    // batch is retained locally — we will keep retrying at
                    // the base cadence until the client-side bug is fixed.
                    print("[sync] points NON-RETRYABLE: \(reason) — batch retained")
                }
                self.adjustBackoff(result)
                self.pointsInFlight = false
                completion?()
            }
        }
    }

    // MARK: - diagnostics channel

    /// Runs on `syncQueue`. Mirror of `drainPoints` for the debug
    /// observability channel.
    private func drainDiagnostics(completion: (() -> Void)?) {
        guard !diagnosticsInFlight else { completion?(); return }
        guard isNetworkReachable() else {
            #if DEBUG
            print("[sync] diagnostics: path not satisfied, skipping")
            #endif
            completion?()
            return
        }
        let batch = database.fetchDiagnosticsBatch(limit: Config.syncBatchSize)
        guard !batch.isEmpty else { completion?(); return }

        diagnosticsInFlight = true
        let payload: [[String: Any]] = batch.map { d in
            [
                "logged_at": d.loggedAt,
                "fix_timestamp": d.fixTimestamp,
                "latitude": d.latitude,
                "longitude": d.longitude,
                "horizontal_accuracy": d.horizontalAccuracy,
                "vertical_accuracy": d.verticalAccuracy,
                "altitude": d.altitude,
                "speed": d.speed,
                "speed_accuracy": d.speedAccuracy,
                "course": d.course,
                "course_accuracy": d.courseAccuracy,
                "decision": d.decision,
                "device_id": self.deviceId,
            ]
        }
        postJsonBatch(path: "diagnostics", payload: payload) { [weak self] result in
            self?.syncQueue.async { [weak self] in
                guard let self = self else { completion?(); return }
                switch result {
                case .success:
                    let ids = batch.map { $0.id }
                    self.database.deleteDiagnostics(ids: ids)
                case .retryable(let reason):
                    #if DEBUG
                    print("[sync] diagnostics retryable: \(reason)")
                    #endif
                case .nonRetryable(let reason):
                    print("[sync] diagnostics NON-RETRYABLE: \(reason) — batch retained")
                }
                // Only feed the backoff state machine when the diagnostics
                // result is actionable. A `.success` on this channel does
                // not reset the interval — the points channel is the
                // user-facing one and owns that decision. A retryable /
                // non-retryable still updates the interval per policy.
                switch result {
                case .success:
                    break
                case .retryable, .nonRetryable:
                    self.adjustBackoff(result)
                }
                self.diagnosticsInFlight = false
                completion?()
            }
        }
    }

    // MARK: - HTTP

    /// Issue a single POST. Classifies the outcome into `SyncResult`:
    ///   - `.success` on 2xx
    ///   - `.retryable` on network errors, 408, 429, 5xx (transient; retrying
    ///     later is reasonable)
    ///   - `.nonRetryable` on 4xx other than 408/429 (client bug — bad
    ///     request, unauthorized, forbidden, not found, 413 payload too
    ///     large — retrying won't help without a code/config change)
    ///
    /// Serialization failures are classified as non-retryable because they
    /// indicate a payload-shape bug that won't fix itself.
    private func postJsonBatch(path: String, payload: [[String: Any]], completion: @escaping (SyncResult) -> Void) {
        let url = Config.apiBaseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let apiKey = Config.apiKey
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            completion(.nonRetryable("\(path) serialize: \(error.localizedDescription)"))
            return
        }

        let task = session.dataTask(with: req) { _, response, error in
            if let error = error {
                // URLSession surfaces timeouts, DNS failure, connection
                // lost, TLS handshake failure, explicit user cancellation,
                // etc. All are transient from the client's perspective.
                completion(.retryable("\(path) network: \(error.localizedDescription)"))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.retryable("\(path): no HTTP response"))
                return
            }
            let code = http.statusCode
            if (200..<300).contains(code) {
                completion(.success)
            } else if code == 408 || code == 429 || (500..<600).contains(code) {
                // 408 Request Timeout → client should retry with same body.
                // 429 Too Many Requests → backend rate-limiting, back off.
                // 5xx → server-side transient.
                completion(.retryable("\(path) HTTP \(code)"))
            } else {
                // 400/401/403/404/413/etc. Retrying sends the same bytes
                // that just failed; nothing will change. Surface loudly.
                completion(.nonRetryable("\(path) HTTP \(code)"))
            }
        }
        task.resume()
    }
}
