import Foundation

/// Periodically drains the local DB and POSTs batches to the backend.
///
/// Two upload channels run on the same 30 s cadence:
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

    private var timer: Timer?
    private var pointsInFlight = false
    private var diagnosticsInFlight = false

    init(database: Database, appState: AppState, deviceId: String, session: URLSession = .shared) {
        self.database = database
        self.appState = appState
        self.deviceId = deviceId
        self.session = session
    }

    func start() {
        stop()
        let t = Timer(timeInterval: Config.syncIntervalSeconds, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Kick off an immediate attempt so leftover rows drain quickly on launch.
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        // Hop onto the serial sync queue before touching any state or
        // reading from the DB. The Timer fires on main; this is where we
        // leave main for the rest of the drain cycle.
        syncQueue.async { [weak self] in
            self?.drainPoints()
            self?.drainDiagnostics()
        }
    }

    // MARK: - points channel

    /// Runs on `syncQueue`. Reads/writes `pointsInFlight` safely because
    /// there is no other producer on this queue.
    private func drainPoints() {
        guard !pointsInFlight else { return }
        let batch = database.fetchBatch(limit: Config.syncBatchSize)
        guard !batch.isEmpty else { return }

        pointsInFlight = true
        let payload: [[String: Any]] = batch.map { p in
            [
                "latitude": p.latitude,
                "longitude": p.longitude,
                "created_at": p.createdAt,
                "device_id": self.deviceId,
            ]
        }
        postJsonBatch(path: "points", payload: payload) { [weak self] success in
            // URLSession completion runs on an unspecified background queue.
            // Hop back onto `syncQueue` so all state mutations stay on a
            // single serial owner — no locks, no torn writes.
            self?.syncQueue.async { [weak self] in
                guard let self = self else { return }
                if success {
                    let ids = batch.map { $0.id }
                    self.database.delete(ids: ids)

                    let delta = batch.count
                    DispatchQueue.main.async { [weak self] in
                        guard let state = self?.appState else { return }
                        state.unsyncedCount = max(0, state.unsyncedCount - delta)
                    }
                }
                self.pointsInFlight = false
            }
        }
    }

    // MARK: - diagnostics channel

    /// Runs on `syncQueue`. Mirror of `drainPoints` for the debug
    /// observability channel.
    private func drainDiagnostics() {
        guard !diagnosticsInFlight else { return }
        let batch = database.fetchDiagnosticsBatch(limit: Config.syncBatchSize)
        guard !batch.isEmpty else { return }

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
        postJsonBatch(path: "diagnostics", payload: payload) { [weak self] success in
            self?.syncQueue.async { [weak self] in
                guard let self = self else { return }
                if success {
                    let ids = batch.map { $0.id }
                    self.database.deleteDiagnostics(ids: ids)
                }
                self.diagnosticsInFlight = false
            }
        }
    }

    // MARK: - HTTP

    private func postJsonBatch(path: String, payload: [[String: Any]], completion: @escaping (Bool) -> Void) {
        let url = Config.apiBaseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            print("[sync] \(path) serialize error: \(error)")
            completion(false)
            return
        }

        let task = session.dataTask(with: req) { _, response, error in
            if let error = error {
                print("[sync] \(path) network error: \(error.localizedDescription)")
                completion(false)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(false)
                return
            }
            if (200..<300).contains(http.statusCode) {
                completion(true)
            } else {
                print("[sync] \(path) upload failed: HTTP \(http.statusCode)")
                completion(false)
            }
        }
        task.resume()
    }
}
