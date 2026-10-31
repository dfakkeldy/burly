// SPDX-License-Identifier: GPL-3.0-or-later
// BurlySyncAdapters — actor sink that forwards to a main-actor runtime

import Foundation

/// The `WCSessionAdapterEventSink` a main-actor runtime hands the adapter.
///
/// The sink protocol is `Actor` on purpose (the adapter serializes delivery
/// onto the caller's actor), but the protocol coordinators that consume the
/// events are `@MainActor`, because their stores are. This actor is the
/// one hop between the two: it keeps the adapter's ordering (each event is
/// awaited before the next is accepted) and runs the handler on the main
/// actor.
public actor WCSessionEventForwarder: WCSessionAdapterEventSink {
    private let handler: @MainActor @Sendable (WCSessionAdapterEvent) async -> Void

    public init(_ handler: @escaping @MainActor @Sendable (WCSessionAdapterEvent) async -> Void) {
        self.handler = handler
    }

    public func receive(_ event: WCSessionAdapterEvent) async {
        await handler(event)
    }
}
