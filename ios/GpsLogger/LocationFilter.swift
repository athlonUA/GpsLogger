import Foundation
import CoreLocation

/// Lightweight, deterministic GPS noise filter.
///
/// Philosophy: remove obvious glitches, never reject real movement. Filtering
/// is intentionally movement-type agnostic — the same thresholds apply to
/// walking, driving, and high-speed rail — because classifying transport
/// modes would introduce false negatives against legitimate users.
///
/// Applied in order:
///   1. `horizontalAccuracy` must be valid (≥ 0) and ≤ `maxHorizontalAccuracyMeters`
///      (PRIMARY signal — the single most reliable quality gate)
///   2. Δt vs. the last accepted point must be > 0 (reject replayed fixes)
///   3. implied speed vs. the last accepted point must be ≤ `maxPlausibleSpeedMps`
///      (extremely relaxed, 500 km/h — only catches teleport-class glitches)
///   4. distance vs. the last accepted point must be ≥ `minDistanceMeters`
///   5. a single-point look-ahead buffer rejects the classic
///      A → B(far jump) → C(back near A) spike pattern, where "far" is
///      `spikeJumpMeters` (750 m — beyond any realistic sample delta) and
///      "near" is `spikeReturnMeters` (100 m)
///
/// The filter is a plain value type with no CoreLocation-manager coupling, so
/// every rule is unit-testable in isolation by constructing `CLLocation`s with
/// explicit timestamps and accuracies.
struct LocationFilter {
    enum Decision: Equatable {
        /// Point is accepted and should be persisted immediately.
        case accept(CLLocation)
        /// Point was held back — the filter is waiting for the next fix to
        /// confirm or reject it. Nothing to persist this tick.
        case buffered
        /// Point was dropped. Includes the reason for debug logging.
        case discard(Reason)
        /// Previous buffered point was a confirmed spike AND the new point is
        /// also accepted, so both decisions are emitted.
        case spikeReplaced(dropped: CLLocation, accepted: CLLocation?)
        /// Previous buffered point turned out to be real movement; commit it,
        /// and optionally also commit the current point.
        case committedPending(pending: CLLocation, alsoAccept: CLLocation?)
    }

    enum Reason: Equatable {
        case invalidFix
        case poorAccuracy(meters: Double)
        case staleTimestamp
        case implausibleSpeed(metersPerSecond: Double)
        case tooClose
    }

    private(set) var lastAccepted: CLLocation?
    private(set) var pending: CLLocation?

    private let maxAccuracy: CLLocationDistance
    private let minDistance: CLLocationDistance
    private let maxSpeed: CLLocationSpeed
    private let spikeJump: CLLocationDistance
    private let spikeReturn: CLLocationDistance

    init(
        maxAccuracy: CLLocationDistance = Config.maxHorizontalAccuracyMeters,
        minDistance: CLLocationDistance = Config.minDistanceMeters,
        maxSpeed: CLLocationSpeed = Config.maxPlausibleSpeedMps,
        spikeJump: CLLocationDistance = Config.spikeJumpMeters,
        spikeReturn: CLLocationDistance = Config.spikeReturnMeters
    ) {
        self.maxAccuracy = maxAccuracy
        self.minDistance = minDistance
        self.maxSpeed = maxSpeed
        self.spikeJump = spikeJump
        self.spikeReturn = spikeReturn
    }

    mutating func reset() {
        lastAccepted = nil
        pending = nil
    }

    /// Feed a new raw fix. Mutates internal state and returns what the caller
    /// should persist.
    mutating func consume(_ loc: CLLocation) -> Decision {
        // 1. Validity + accuracy gate. An invalid CLLocation reports
        //    horizontalAccuracy < 0; anything worse than maxAccuracy is too
        //    noisy to be useful for visualization.
        guard loc.horizontalAccuracy >= 0 else {
            return .discard(.invalidFix)
        }
        guard loc.horizontalAccuracy <= maxAccuracy else {
            return .discard(.poorAccuracy(meters: loc.horizontalAccuracy))
        }

        // First-ever accepted fix: no prior anchor, just take it.
        guard let last = lastAccepted else {
            lastAccepted = loc
            return .accept(loc)
        }

        let dt = loc.timestamp.timeIntervalSince(last.timestamp)
        // 2. Out-of-order / duplicate-timestamp samples — CoreLocation
        //    occasionally replays an older cached fix; ignore them.
        guard dt > 0 else {
            return .discard(.staleTimestamp)
        }

        let distFromLast = loc.distance(from: last)

        // 3. Implausible speed — catches hard teleports even if accuracy looks OK.
        let impliedSpeed = distFromLast / dt
        if impliedSpeed > maxSpeed {
            return .discard(.implausibleSpeed(metersPerSecond: impliedSpeed))
        }

        // 5. Spike resolution has priority over min-distance, because the
        //    pending point may itself be the thing we want to drop.
        if let buffered = pending {
            let distLastToPending = buffered.distance(from: last)
            let distPendingToNew = loc.distance(from: buffered)

            // Confirmed A → B(far) → C(near A) spike:
            //   - B was far from A (that's why it was buffered)
            //   - C is back near A
            //   - C is also far from B (B is the outlier, not C)
            let isSpike =
                distLastToPending > spikeJump &&
                distFromLast < spikeReturn &&
                distPendingToNew > spikeJump

            if isSpike {
                pending = nil
                // Only re-emit C if it's meaningfully far from A, otherwise
                // the 10 m filter would have dropped it anyway.
                if distFromLast >= minDistance {
                    let dropped = buffered
                    lastAccepted = loc
                    return .spikeReplaced(dropped: dropped, accepted: loc)
                } else {
                    return .spikeReplaced(dropped: buffered, accepted: nil)
                }
            }

            // Not a spike → the buffered point was real movement. Commit it
            // as the new anchor, then evaluate the current point against that
            // new anchor (min-distance only; speed was already checked vs. A
            // and B sits between A and C in time, so the speed envelope holds).
            pending = nil
            lastAccepted = buffered
            let distFromPending = loc.distance(from: buffered)
            if distFromPending >= minDistance {
                lastAccepted = loc
                return .committedPending(pending: buffered, alsoAccept: loc)
            }
            return .committedPending(pending: buffered, alsoAccept: nil)
        }

        // 4. Min-distance filter.
        if distFromLast < minDistance {
            return .discard(.tooClose)
        }

        // 5. Suspicious jump with no buffer yet → hold it back for one tick.
        if distFromLast > spikeJump {
            pending = loc
            return .buffered
        }

        lastAccepted = loc
        return .accept(loc)
    }
}
