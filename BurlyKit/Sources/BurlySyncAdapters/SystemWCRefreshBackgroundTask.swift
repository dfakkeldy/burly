// SPDX-License-Identifier: GPL-3.0-or-later
// BurlySyncAdapters — WatchKit background-task wrapper

#if os(watchOS)
import Foundation
@preconcurrency import WatchKit

/// Wrap in the app delegate's `handle(_:)`, retain through WCSessionAdapter,
/// and let the hasContentPending coordinator complete it.
@MainActor
public final class SystemWCRefreshBackgroundTask: WCRefreshBackgroundTask {
    private let task: WKWatchConnectivityRefreshBackgroundTask

    public init(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        self.task = task
    }

    /// Identity belongs to the system task, not this disposable wrapper.
    /// Re-wrapping one wake therefore remains one completion obligation.
    public var completionID: ObjectIdentifier { ObjectIdentifier(task) }

    public func setTaskCompletedWithSnapshot(_ snapshot: Bool) {
        task.setTaskCompletedWithSnapshot(snapshot)
    }
}

extension WCSessionAdapter {
    /// App-delegate entry point for every Watch Connectivity background wake.
    public func retainBackgroundTask(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        retainBackgroundTask(SystemWCRefreshBackgroundTask(task))
    }
}
#endif
