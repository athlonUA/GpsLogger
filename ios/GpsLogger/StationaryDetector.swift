import Foundation
import CoreLocation

/// Second-stage noise gate layered on top of `LocationFilter`.
///
/// When the user is physically still, GPS still produces jitter: fixes that
/// drift several meters around the real position, occasionally enough to
/// clear the 10 m distance filter and look like a short walk. Accuracy gating
/// alone does not catch this — the fixes are "accurate" in the CoreLocation
/// sense, they are just scattered around a fixed point.
///
/// The detector watches the stream of fixes that `LocationFilter` has already
/// accepted and decides whether each one represents real movement or
/// stationary jitter that should be suppressed.
///
/// Algorithm (anchor-based sliding cluster):
///
/// 1. While not stationary, hold a single *candidate anchor* — the fix that
///    started the current cluster.
/// 2. Every new accepted fix is compared against the anchor:
///      - within `stationaryRadius` → the cluster is extended; the fix is
///        still emitted (real movement has not been ruled out yet).
///      - outside `stationaryRadius` → the cluster is broken; the new fix
///        becomes the fresh candidate anchor and is emitted.
/// 3. As soon as the candidate anchor has persisted for
///    `stationaryWindowSeconds` without being broken, the user is declared
///    stationary. The current fix is suppressed (the anchor and the points
///    between are already on the record) and the anchor is frozen as the
///    cluster center.
/// 4. While stationary, every new fix is suppressed unless it lies farther
///    than `resumeRadius` from the cluster center, at which point the user
///    is considered moving again and normal recording resumes.
///
/// Coordinate values are never averaged or smoothed — the detector only
/// decides accept/suppress and passes the original `CLLocation` through.
struct StationaryDetector {
    enum Decision: Equatable {
        /// Forward the point to storage.
        case accept
        /// Drop the point as stationary jitter.
        case suppress
    }

    private let windowSeconds: TimeInterval
    private let stationaryRadius: CLLocationDistance
    private let resumeRadius: CLLocationDistance
    private let gapResetSeconds: TimeInterval

    /// First fix of the current candidate cluster while not yet stationary.
    /// Reset whenever a fix lands outside `stationaryRadius`.
    private(set) var candidateAnchor: CLLocation?

    /// Frozen cluster center once stationary mode is active. `nil` means we
    /// are still in "moving / evaluating" mode.
    private(set) var stationaryCenter: CLLocation?

    /// Timestamp of the most recent fix we processed, whether accepted or
    /// suppressed. Used to invalidate the candidate / stationary state
    /// after a long signal-loss gap — see the gap-reset branch in
    /// `consume(_:)`.
    private(set) var lastSeen: Date?

    init(
        windowSeconds: TimeInterval = Config.stationaryWindowSeconds,
        stationaryRadius: CLLocationDistance = Config.stationaryRadiusMeters,
        resumeRadius: CLLocationDistance = Config.stationaryResumeMeters,
        gapResetSeconds: TimeInterval = Config.resumeGapSeconds
    ) {
        self.windowSeconds = windowSeconds
        self.stationaryRadius = stationaryRadius
        self.resumeRadius = resumeRadius
        self.gapResetSeconds = gapResetSeconds
    }

    mutating func reset() {
        candidateAnchor = nil
        stationaryCenter = nil
        lastSeen = nil
    }

    mutating func consume(_ loc: CLLocation) -> Decision {
        // Gap-reset guard. `windowSeconds` is supposed to be evidence that
        // the user was physically inside `stationaryRadius` for that long,
        // which requires a continuous stream of fixes inside the cluster.
        // If `LocationFilter` rejected every sample during a GPS blackout
        // (tunnel, indoor, canopy), the candidate anchor quietly sits
        // untouched — and then the first returning fix gets classified
        // "stationary for 5 minutes" purely because of the clock delta,
        // even though the user may have been walking the entire time. We
        // observed exactly this in production (2026-04-17 session): after
        // a 5-minute blackout, the four real movement fixes at
        // 16:45:06–16:45:31 were suppressed as stationary-jitter because
        // the anchor from 16:40:01 had "aged" past `windowSeconds`.
        //
        // Fix: if no fix was processed within `gapResetSeconds`, treat the
        // returning fix as a fresh candidate anchor and drop any cached
        // stationary center. This aligns with `LocationFilter`'s own
        // `resumeGapSeconds` concept — both modules agree on what counts
        // as "we lost the user" and reset state symmetrically.
        if let last = lastSeen,
           loc.timestamp.timeIntervalSince(last) > gapResetSeconds {
            candidateAnchor = loc
            stationaryCenter = nil
            lastSeen = loc.timestamp
            return .accept
        }
        lastSeen = loc.timestamp

        // Phase B — already stationary. Hold the suppression until we see a
        // fix clearly outside the cluster.
        if let center = stationaryCenter {
            if loc.distance(from: center) > resumeRadius {
                stationaryCenter = nil
                candidateAnchor = loc
                return .accept
            }
            return .suppress
        }

        // Phase A — evaluating whether the user has gone stationary.
        guard let anchor = candidateAnchor else {
            candidateAnchor = loc
            return .accept
        }

        // A fix outside the cluster breaks the candidate — this fix is the
        // start of a brand-new potential cluster. Forward it; the clock
        // restarts from here.
        if loc.distance(from: anchor) > stationaryRadius {
            candidateAnchor = loc
            return .accept
        }

        // Still inside the cluster. If the candidate has been sustained for
        // at least `windowSeconds`, we are now stationary — freeze the
        // anchor as the cluster center and suppress this fix.
        let age = loc.timestamp.timeIntervalSince(anchor.timestamp)
        if age < 0 {
            // System clock jumped backwards between the anchor's capture
            // and this fix (NTP adjustment, DST transition quirk, or a
            // CoreLocation cached replay with an older timestamp). The
            // age comparison would never fire and the detector would
            // stall in Phase A forever. Reset the candidate to the
            // newer fix and restart the window.
            candidateAnchor = loc
            return .accept
        }
        if age >= windowSeconds {
            stationaryCenter = anchor
            candidateAnchor = nil
            return .suppress
        }

        return .accept
    }
}
