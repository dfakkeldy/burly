// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise — spec §1 entity.
//
// `@Model` classes are deliberately **internal** to BurlyPersistence
// (architecture doc: "domain↔storage mapping behind a small protocol").
// That module-internal access, plus `BurlyStore`'s public surface never
// naming an `@Model` type in a signature (see BurlyStore.swift), is what
// actually seals them inside this module — `BurlyCore.ExerciseData` is
// what callers see.
//
// This is *not* a Sendable-driven compiler backstop (m1-06 review, finding
// m3): the current SDK's `@Model` macro attaches `Sendable` to every model
// class, so nothing in the type system would stop a value of this type
// from crossing an actor boundary if one ever escaped the sealed API
// above. Containment is the module boundary itself, not non-Sendability;
// isolation discipline for a store in use is caller-owned (see
// BurlyStore.swift's Threading note). A dedicated confinement mechanism
// is a later-milestone decision, not made here.

import Foundation
import SwiftData
import BurlyCore

@Model
final class Exercise {
    /// Spec §1: all entities are UUID-keyed and unique on `id`.
    @Attribute(.unique) var id: UUID
    var name: String
    var muscleGroups: [MuscleGroup]
    var origin: ExerciseOrigin
    /// True only for watch-created placeholders (§1, §2 "Custom (name later)").
    var needsNaming: Bool
    /// Spec §1: exercises are archived, **never deleted**, once referenced.
    var archivedAt: Date?

    // The two inverse relationships below are the *only* place the
    // Exercise↔item edges are declared (the child sides stay bare — the
    // `@Relationship` macro belongs on exactly one side of a pair). Being
    // explicit here matters: SwiftData infers inverses unreliably, and two
    // different child types both point at Exercise.
    //
    // `.deny` states §1's integrity rule — an Exercise referenced by a
    // routine item or session item must not be hard-deleted.
    //
    // **It is a declaration of intent, not a working lock.** Measured on
    // Swift 6.3.3 / macOS 27 (2026-08-01): `context.delete(exercise)` on a
    // referenced Exercise saves without error and behaves like `.nullify` —
    // the exercise row goes and the items are left pointing at nothing.
    // `StoreAPISurfaceTests` pins that behavior so we notice if a future
    // SwiftData starts enforcing it.
    //
    // The real guarantee for §1 acceptance #3 is therefore the one the spec
    // actually asks for: `BurlyStore` exposes **no** exercise-delete method,
    // so the call cannot be written. Do not add one.
    @Relationship(deleteRule: .deny, inverse: \RoutineItem.exercise)
    var routineItems: [RoutineItem] = []

    @Relationship(deleteRule: .deny, inverse: \SessionItem.exercise)
    var sessionItems: [SessionItem] = []

    init(
        id: UUID,
        name: String,
        muscleGroups: [MuscleGroup],
        origin: ExerciseOrigin,
        needsNaming: Bool,
        archivedAt: Date?
    ) {
        self.id = id
        self.name = name
        self.muscleGroups = muscleGroups
        self.origin = origin
        self.needsNaming = needsNaming
        self.archivedAt = archivedAt
    }
}
