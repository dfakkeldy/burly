// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §4 lifecycle rules, "Stale-session guard": on watch app activation,
// if the active session's last logged set is more than 1 h old, offer
// finish (with the original timestamps) or discard. Never auto-ends.
import Foundation

public enum StaleSessionGuard {
    /// One hour (Dan, 2026-08-01). Strictly greater than this is stale.
    public static let threshold: TimeInterval = 60 * 60

    /// The last thing the lifter did: the latest logged set, or the start
    /// for a session with nothing logged yet. Finishing a stale session
    /// ends it here.
    public static func lastActivity(of session: ActiveSession) -> Date {
        session.allSets.map(\.completedAt).max() ?? session.session.startedAt
    }

    public static func isStale(_ session: ActiveSession, now: Date) -> Bool {
        now.timeIntervalSince(lastActivity(of: session)) > threshold
    }
}
