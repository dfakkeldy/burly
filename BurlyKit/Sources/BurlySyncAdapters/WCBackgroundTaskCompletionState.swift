// SPDX-License-Identifier: GPL-3.0-or-later
// BurlySyncAdapters — pure hasContentPending completion invariant

import Foundation

/// Pure state behind the WKWatchConnectivityRefreshBackgroundTask lifecycle.
/// Retained task IDs drain only after WCSession is activated and reports no
/// content pending. Transfer-finish callback order is intentionally absent:
/// it is not a safe completion signal.
public struct WCBackgroundTaskCompletionState<TaskID: Hashable & Sendable>: Sendable {
    public private(set) var activationState: WCSessionActivation
    public private(set) var hasContentPending: Bool
    public private(set) var retainedTaskIDs: [TaskID]

    public init(
        activationState: WCSessionActivation = .notActivated,
        hasContentPending: Bool = true
    ) {
        self.activationState = activationState
        self.hasContentPending = hasContentPending
        retainedTaskIDs = []
    }

    public mutating func retain(_ taskID: TaskID) -> [TaskID] {
        if !retainedTaskIDs.contains(taskID) {
            retainedTaskIDs.append(taskID)
        }
        return drainIfReady()
    }

    public mutating func activationChanged(to state: WCSessionActivation) -> [TaskID] {
        activationState = state
        return drainIfReady()
    }

    public mutating func contentPendingChanged(to hasContentPending: Bool) -> [TaskID] {
        self.hasContentPending = hasContentPending
        return drainIfReady()
    }

    /// Updates the two WCSession gate facts as one observation. Production
    /// uses this path so out-of-order KVO callbacks can never combine a fresh
    /// activation state with stale pending-content state.
    public mutating func sessionStateChanged(
        activationState: WCSessionActivation,
        hasContentPending: Bool
    ) -> [TaskID] {
        self.activationState = activationState
        self.hasContentPending = hasContentPending
        return drainIfReady()
    }

    private mutating func drainIfReady() -> [TaskID] {
        guard activationState == .activated, !hasContentPending else { return [] }
        let completed = retainedTaskIDs
        retainedTaskIDs.removeAll(keepingCapacity: true)
        return completed
    }
}

/// App-agnostic completion surface wrapped around
/// WKWatchConnectivityRefreshBackgroundTask by the watch app.
@MainActor
public protocol WCRefreshBackgroundTask: AnyObject {
    var completionID: UUID { get }
    func setTaskCompletedWithSnapshot(_ snapshot: Bool)
}

/// Retains concrete background tasks and applies the pure state machine's
/// completion decisions exactly once for each retained task.
@MainActor
public final class WCBackgroundTaskCoordinator {
    private var state: WCBackgroundTaskCompletionState<UUID>
    private var tasks: [UUID: any WCRefreshBackgroundTask] = [:]

    public init(
        activationState: WCSessionActivation = .notActivated,
        hasContentPending: Bool = true
    ) {
        state = WCBackgroundTaskCompletionState(
            activationState: activationState,
            hasContentPending: hasContentPending
        )
    }

    public var retainedTaskCount: Int { tasks.count }

    public func retain(_ task: any WCRefreshBackgroundTask) {
        guard tasks[task.completionID] == nil else { return }
        tasks[task.completionID] = task
        complete(state.retain(task.completionID))
    }

    public func activationChanged(to activationState: WCSessionActivation) {
        complete(state.activationChanged(to: activationState))
    }

    public func contentPendingChanged(to hasContentPending: Bool) {
        complete(state.contentPendingChanged(to: hasContentPending))
    }

    public func sessionStateChanged(
        activationState: WCSessionActivation,
        hasContentPending: Bool
    ) {
        complete(state.sessionStateChanged(
            activationState: activationState,
            hasContentPending: hasContentPending
        ))
    }

    private func complete(_ taskIDs: [UUID]) {
        for taskID in taskIDs {
            guard let task = tasks.removeValue(forKey: taskID) else { continue }
            task.setTaskCompletedWithSnapshot(false)
        }
    }
}
