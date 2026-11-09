// SPDX-License-Identifier: MIT
// BurlySyncAdapters — pure hasContentPending completion invariant

import Foundation

/// Pure state behind the WKWatchConnectivityRefreshBackgroundTask lifecycle.
/// Retained task IDs drain only after WCSession is activated, reports no
/// content pending, and everything it already handed over has been applied.
/// Transfer-finish callback order is intentionally absent: it is not a safe
/// completion signal.
///
/// The third fact exists because WCSession's `hasContentPending` turns false
/// once the delegate *received* the content, not once the app applied it.
/// The adapter hands each envelope upward asynchronously (its delivery
/// chain, then the caller's actor, then the store write), so completing the
/// task on `hasContentPending` alone lets watchOS suspend the app with a
/// just-delivered snapshot or digest consumed from WatchConnectivity and
/// never written.
public struct WCBackgroundTaskCompletionState<TaskID: Hashable & Sendable>: Sendable {
    public private(set) var activationState: WCSessionActivation
    public private(set) var hasContentPending: Bool
    /// `true` while the adapter has handed upward content the receiver has
    /// not finished applying.
    public private(set) var hasUndeliveredContent: Bool
    public private(set) var retainedTaskIDs: [TaskID]

    public init(
        activationState: WCSessionActivation = .notActivated,
        hasContentPending: Bool = true,
        hasUndeliveredContent: Bool = false
    ) {
        self.activationState = activationState
        self.hasContentPending = hasContentPending
        self.hasUndeliveredContent = hasUndeliveredContent
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

    public mutating func undeliveredContentChanged(to hasUndeliveredContent: Bool) -> [TaskID] {
        self.hasUndeliveredContent = hasUndeliveredContent
        return drainIfReady()
    }

    private mutating func drainIfReady() -> [TaskID] {
        guard activationState == .activated, !hasContentPending, !hasUndeliveredContent else { return [] }
        let completed = retainedTaskIDs
        retainedTaskIDs.removeAll(keepingCapacity: true)
        return completed
    }
}

/// App-agnostic completion surface wrapped around
/// WKWatchConnectivityRefreshBackgroundTask by the watch app.
@MainActor
public protocol WCRefreshBackgroundTask: AnyObject {
    var completionID: ObjectIdentifier { get }
    func setTaskCompletedWithSnapshot(_ snapshot: Bool)
}

/// Retains concrete background tasks and applies the pure state machine's
/// completion decisions exactly once for each retained task.
@MainActor
public final class WCBackgroundTaskCoordinator {
    private var state: WCBackgroundTaskCompletionState<ObjectIdentifier>
    private var tasks: [ObjectIdentifier: any WCRefreshBackgroundTask] = [:]

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

    public func undeliveredContentChanged(to hasUndeliveredContent: Bool) {
        complete(state.undeliveredContentChanged(to: hasUndeliveredContent))
    }

    private func complete(_ taskIDs: [ObjectIdentifier]) {
        for taskID in taskIDs {
            guard let task = tasks.removeValue(forKey: taskID) else { continue }
            task.setTaskCompletedWithSnapshot(false)
        }
    }
}
