// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import BurlySyncAdapters

@Suite("WC background-task hasContentPending invariant")
struct WCBackgroundTaskCompletionTests {
    @Test("tasks never complete before activation and queue drain")
    func noEarlyCompletion() {
        var state = WCBackgroundTaskCompletionState<Int>()

        #expect(state.retain(1).isEmpty)
        #expect(state.activationChanged(to: .activated).isEmpty)
        #expect(state.contentPendingChanged(to: true).isEmpty)
        #expect(state.retainedTaskIDs == [1])
        #expect(state.contentPendingChanged(to: false) == [1])
        #expect(state.retainedTaskIDs.isEmpty)
    }

    @Test("false pending arriving before activation still waits")
    func outOfOrderGateChanges() {
        var state = WCBackgroundTaskCompletionState<Int>()

        #expect(state.retain(7).isEmpty)
        #expect(state.retain(7).isEmpty)
        #expect(state.contentPendingChanged(to: false).isEmpty)
        #expect(state.activationChanged(to: .inactive).isEmpty)
        #expect(state.activationChanged(to: .activated) == [7])
        #expect(state.activationChanged(to: .activated).isEmpty)
        #expect(state.contentPendingChanged(to: false).isEmpty)
    }

    @Test("burst of queued transfers drains every retained task exactly once")
    func burstDrain() {
        let count = 256
        var state = WCBackgroundTaskCompletionState<Int>(
            activationState: .activated,
            hasContentPending: true
        )

        for id in 0..<count {
            #expect(state.retain(id).isEmpty)
        }
        // Finish callbacks can arrive in any order; the pure state does not
        // consume them. Only WCSession's aggregate queue fact opens the gate.
        #expect(state.retainedTaskIDs.count == count)

        let completed = state.contentPendingChanged(to: false)
        #expect(completed == Array(0..<count))
        #expect(Set(completed).count == count)
        #expect(state.retainedTaskIDs.isEmpty)
        #expect(state.contentPendingChanged(to: false).isEmpty)
    }

    @Test("new task completes immediately when WCSession is already drained")
    func alreadyDrained() {
        var state = WCBackgroundTaskCompletionState<Int>(
            activationState: .activated,
            hasContentPending: false
        )

        #expect(state.retain(42) == [42])
        #expect(state.retainedTaskIDs.isEmpty)
    }

    @Test("coordinator retains a burst, completes false once each, and leaks none")
    @MainActor
    func coordinatorBurst() {
        let coordinator = WCBackgroundTaskCoordinator(
            activationState: .notActivated,
            hasContentPending: true
        )
        let tasks = (0..<128).map { _ in FakeRefreshBackgroundTask() }

        tasks.forEach(coordinator.retain)
        coordinator.contentPendingChanged(to: false)
        #expect(tasks.allSatisfy { $0.snapshots.isEmpty })
        #expect(coordinator.retainedTaskCount == tasks.count)

        coordinator.activationChanged(to: .activated)
        #expect(tasks.allSatisfy { $0.snapshots == [false] })
        #expect(coordinator.retainedTaskCount == 0)

        coordinator.contentPendingChanged(to: false)
        coordinator.activationChanged(to: .activated)
        #expect(tasks.allSatisfy { $0.snapshots == [false] })
    }

    @Test("two wrappers around one system task retain and complete only once")
    @MainActor
    func duplicateWrapperIdentity() {
        let coordinator = WCBackgroundTaskCoordinator(
            activationState: .notActivated,
            hasContentPending: true
        )
        let systemTask = FakeSystemRefreshBackgroundTask()
        let firstWrapper = FakeRefreshBackgroundTask(wrapping: systemTask)
        let secondWrapper = FakeRefreshBackgroundTask(wrapping: systemTask)

        #expect(firstWrapper !== secondWrapper)
        #expect(firstWrapper.completionID == secondWrapper.completionID)

        coordinator.retain(firstWrapper)
        coordinator.retain(secondWrapper)
        #expect(coordinator.retainedTaskCount == 1)

        coordinator.sessionStateChanged(
            activationState: .activated,
            hasContentPending: false
        )
        #expect(systemTask.snapshots == [false])
        #expect(coordinator.retainedTaskCount == 0)

        coordinator.sessionStateChanged(
            activationState: .activated,
            hasContentPending: false
        )
        #expect(systemTask.snapshots == [false])
    }
}
