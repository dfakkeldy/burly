// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore
//
// Pure Swift domain layer for Burly (architecture doc, §module layout):
// framework-free value types that cross module and device boundaries. No
// SwiftData `@Model` classes live here — those are BurlyPersistence's
// (task m1-02), mapping to/from the structs below at the store boundary.
//
// ## Naming scheme
//
// Every value type mirroring a spec §1 SwiftData entity is named
// `<Entity>Data` — ExerciseData, RoutineData, RoutineItemData, SessionData,
// SessionItemData, SetRecordData, ExerciseLastPerformanceData. The suffix
// reads "the data behind <Entity>" and keeps these visually distinct from
// BurlyPersistence's forthcoming `@Model` types of the bare entity names.
// `SetSnapshot` (mirroring `ExerciseLastPerformance.sets`, already a value
// struct in the spec) keeps its spec name — there is no `@Model` twin to
// disambiguate from.
//
// Relationship fields that are object references in the spec
// (`exercise: Exercise?`) become `<name>ID: UUID?` here — cross-device
// references are by UUID, never by object identity (architecture doc).
// Field names, types, and optionality otherwise mirror spec §1 exactly;
// no invented fields.
//
// Every type takes a default `id: UUID = UUID()` parameter for convenient
// construction at test/call sites that don't care about a specific id.
// Every other default mirrors one the spec itself states (e.g.
// `defaultSetCount = 3`, `isWarmup = false`, `items = []`, `revision = 1`,
// `state = .active`) — nothing invented beyond that.
//
// ## Units
//
// `weightKg: Double` is the only stored weight representation, everywhere
// (spec §1 acceptance #4). See Weight.swift for the construction API
// (SetRecordData and SetSnapshot only accept weight via `Weight`, never a
// raw `Double`) and the 0 kg = bodyweight convention.
//
// ## Imports
//
// Foundation appears only where the spec's identity (`UUID`) or timestamp
// (`Date`, `TimeInterval`) fields require it, confined file-by-file — see
// each file's header comment for the specific reason.
// `Weight+Measurement.swift` is the one file that imports Foundation for
// something other than identity/time (`Measurement<UnitMass>`, required by
// acceptance #4); every other BurlyCore file that needs Foundation needs
// it only for UUID/Date/TimeInterval. The pure enums (MuscleGroup,
// ExerciseOrigin, SessionState, SessionOrigin) and Weight.swift itself
// import nothing at all.
public enum BurlyCore {
    public static let placeholder = "BurlyCore"
}
