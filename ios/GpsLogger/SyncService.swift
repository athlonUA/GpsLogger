import Foundation

/// Periodically drains the local DB and POSTs batches to the backend.
/// A timer is allowed here — it is used ONLY for sync, never for location collection.
final class SyncService {
    private let database: Database
    private let appState: AppState
    private let session: URLSession

    private var timer: Timer?
    private var inFlight = false

    init(database: Database, appState: AppState, session: URLSession = .shared) {
        self.database = database
        self.appState = appState
        self.session = session
    }

    func start() {
        stop()
        let t = Timer(timeInterval: Config.syncIntervalSeconds, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Kick off an immediate attempt so leftover points drain quickly on launch.
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !inFlight else { return }
        let batch = database.fetchBatch(limit: Config.syncBatchSize)
        guard !batch.isEmpty else { return }

        inFlight = true
        upload(batch: batch) { [weak self] success in
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

            self.inFlight = false
        }
    }

    private func upload(batch: [LocalPoint], completion: @escaping (Bool) -> Void) {
        let url = Config.apiBaseURL.appendingPathComponent("points")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [[String: Any]] = batch.map { p in
            [
                "latitude": p.latitude,
                "longitude": p.longitude,
                "created_at": p.createdAt,
            ]
        }

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            print("[sync] serialize error: \(error)")
            completion(false)
            return
        }

        let task = session.dataTask(with: req) { _, response, error in
            if let error = error {
                print("[sync] network error: \(error.localizedDescription)")
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
                print("[sync] upload failed: HTTP \(http.statusCode)")
                completion(false)
            }
        }
        task.resume()
    }
}
