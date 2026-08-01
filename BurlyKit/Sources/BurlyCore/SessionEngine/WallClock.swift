// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — WallClock
//
// The one time source the session engine reads. Everything in
// SessionEngine/ that needs "now" takes a `WallClock` rather than calling
// `Date()`, so every state machine is exhaustively testable by advancing a
// fake clock — including the cases that only happen after a suspension gap
// (spec §3: "process suspension, Always-On, or relaunch never drifts it").
//
// Why `Date` and not Swift's `Clock`/`ContinuousClock`: §3 requires
// *wall-clock* semantics. The rest timer is a stored `endDate` that must
// stay correct across process death and relaunch, and `SetRecord
// .completedAt` is a persisted `Date`. A monotonic instant type cannot be
// stored and compared across launches, so it is the wrong primitive here.
// Deliberately not named `Clock`: that name is taken by the standard
// library's `Clock` protocol, and shadowing it inside a module that other
// modules `import` would be a live ambiguity hazard.
//
// Imports Foundation for `Date` only.
import Foundation

/// A source of the current wall-clock instant.
///
/// Conformances must be `Sendable`; the engine types that hold one are
/// value types that cross isolation boundaries.
public protocol WallClock: Sendable {
    var now: Date { get }
}

/// The production clock: the system wall clock.
public struct SystemWallClock: WallClock {
    public init() {}

    public var now: Date { Date() }
}
