// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyPhoneSync — SessionDigestGenerator
//
// The generator `SessionDigestReceipt`'s doc names and defers to M4 for: "the
// generator owes a property test: for any history and any ack set, the
// emitted `lastPerformance` covers every exercise the phone has any sets
// for." This is that generator.
//
// ## The contract, restated as code
//
// `lastPerformance` must be the **complete latest-per-exercise derivation
// over the phone's full current `.logged` history at generation time** — not
// a delta, not "what changed", the whole thing. The watch trusts this and
// cannot verify it (see `SessionDigestReceipt`'s doc for why checking is
// worse than trusting): an absent entry is read as "history holds nothing
// for that exercise" and drives a prune. So this file's one job is to make
// that true, every time, including the degenerate case — an empty store
// (nothing ever logged, or everything since deleted) legitimately produces
// an empty `lastPerformance`, and that must be emittable even alongside a
// non-empty `ackedSessionIDs` (the acked-then-deleted sequence
// `BurlyStore.applyDigest`'s doc walks through). Nothing here validates
// `ackedSessionIDs` against `lastPerformance` — they are two independent
// machine-owned/derived facts, exactly as `PhoneSyncMachine.Command
// .publishDigest`'s two parameters are.
//
// ## Bounded, not looped (m4-04)
//
// This reads `BurlyStore.allLoggedSetSlices()` exactly **once** — the flat,
// non-relationship-hydrating shape every other §7 query uses, restricted to
// `.logged` sessions, at a cost proportional to total logged `SetRecord`
// count. It does not loop `loggedSetSlices(exerciseID:since:through:)` once
// per catalog exercise: that method already fetches the entire table
// internally per call (see its doc), so a per-exercise loop would pay for
// the whole table once per exercise instead of once total.
import Foundation
import BurlyCore
import BurlyPersistence
import BurlySync

public enum SessionDigestGenerator {
    /// Derives and builds the full §5 `digest` payload: the machine-owned
    /// `snapshotVersion`/`ackedSessionIDs` (`PhoneSyncMachine.Command
    /// .publishDigest`'s two facts) plus `lastPerformance`, derived from
    /// `store`'s full current `.logged` history **at the moment this runs**
    /// — never a cached or earlier-fetched slice list, which is what makes
    /// "at generation time" true rather than aspirational.
    @MainActor
    public static func generate(
        from store: any BurlyStore,
        snapshotVersion: Int,
        ackedSessionIDs: Set<UUID>
    ) throws -> BurlyDigestPayloadDTO {
        let slices = try store.allLoggedSetSlices()
        return BurlyDigestPayloadDTO(
            snapshotVersion: snapshotVersion,
            lastPerformance: latestPerformancePerExercise(from: slices),
            ackedSessionIDs: ackedSessionIDs
        )
    }

    /// The pure derivation, separated from the store fetch so the property
    /// test can drive it directly against hand-built (and randomized)
    /// `[SetRecordSlice]` inputs without paying for a real store round-trip
    /// on every trial, and so an independent oracle can be checked against
    /// exactly this function's output.
    ///
    /// For each distinct, non-`nil` `exerciseID` present in `slices`: finds
    /// the session with the latest `sessionStartedAt` that has any set
    /// against that exercise (ties broken by session id, descending, for
    /// full determinism — see `isNewer` below), and returns every slice
    /// belonging to *that* (exercise, session) pair as the entry's `sets`.
    ///
    /// **Sets are ordered by their own `order` field — their position
    /// within the exercise — not by `completedAt`** (m4-04 review round 1,
    /// major 9). §2's ghost row is explicit about what this list means:
    /// "last session's numbers **for this set index**", so the field whose
    /// entire purpose is positional identity is the correct primary key,
    /// not a wall-clock timestamp that is *usually* monotonic with position
    /// but is not guaranteed to be (a §6 set edit, or two `SessionItem`s for
    /// the same exercise with interleaved completion times, can both make
    /// `order` and `completedAt` disagree). `completedAt` remains the
    /// tie-break for the case `order` alone cannot resolve — two sets
    /// sharing one `order` value because they come from *different* items
    /// referencing the same exercise (the "same exercise twice in one
    /// session" shape) — and the set's own `id` breaks any tie that
    /// survives even that.
    ///
    /// A slice with a `nil` exerciseID is excluded — a digest is keyed by
    /// exercise (§5), and no payload could ever carry an entry for one (see
    /// `BurlyStore.applyDigest`'s doc, "a set logged against an item with no
    /// exercise reference is prunable"). The result's own order is
    /// `exerciseID` ascending (by UUID string) purely so two calls over
    /// equal input always produce byte-identical output — the same reason
    /// `BurlyDigestPayloadDTO.init` sorts `ackedSessionIDs`.
    public static func latestPerformancePerExercise(
        from slices: [SetRecordSlice]
    ) -> [ExerciseLastPerformanceData] {
        var winners: [UUID: (sessionID: UUID, startedAt: Date)] = [:]
        var byExerciseAndSession: [ExerciseSessionKey: [SetRecordSlice]] = [:]

        for slice in slices {
            guard let exerciseID = slice.exerciseID else { continue }
            let key = ExerciseSessionKey(exerciseID: exerciseID, sessionID: slice.sessionID)
            byExerciseAndSession[key, default: []].append(slice)

            let candidate = (sessionID: slice.sessionID, startedAt: slice.sessionStartedAt)
            if let current = winners[exerciseID] {
                if isNewer(candidate, than: current) {
                    winners[exerciseID] = candidate
                }
            } else {
                winners[exerciseID] = candidate
            }
        }

        return winners.map { exerciseID, winner in
            let key = ExerciseSessionKey(exerciseID: exerciseID, sessionID: winner.sessionID)
            let sets = (byExerciseAndSession[key] ?? [])
                .sortedByOrderThenCompletedAtThenID()
                .map { SetSnapshot(weight: $0.set.weight, reps: $0.set.reps, isWarmup: $0.set.isWarmup) }
            return ExerciseLastPerformanceData(
                exerciseID: exerciseID,
                performedAt: winner.startedAt,
                sets: sets
            )
        }
        .sorted { $0.exerciseID.uuidString < $1.exerciseID.uuidString }
    }

    private struct ExerciseSessionKey: Hashable {
        let exerciseID: UUID
        let sessionID: UUID
    }

    /// `candidate` wins over `current` when it started later, or — on an
    /// exact `startedAt` tie, which real wall-clock timestamps rarely
    /// produce but synthetic or coarse ones can — when its session id sorts
    /// higher as a string. Either way the choice is a pure function of the
    /// input, never of fetch order.
    private static func isNewer(
        _ candidate: (sessionID: UUID, startedAt: Date),
        than current: (sessionID: UUID, startedAt: Date)
    ) -> Bool {
        if candidate.startedAt != current.startedAt {
            return candidate.startedAt > current.startedAt
        }
        return candidate.sessionID.uuidString > current.sessionID.uuidString
    }
}

/// The ghost-row set ordering (m4-04 review round 1, major 9): primarily by
/// each set's own `order` — its position within the exercise, matching §2's
/// "for this set index" — then by `completedAt`, then by the set's own
/// stable `id`, so two sets that somehow share both `order` and
/// `completedAt` still resolve deterministically. Note this is
/// *deliberately not* `Array<SetRecordSlice>
/// .sortedForDeterministicSummation()` (BurlyCore, `internal`, used by §7's
/// summation-only accumulators, where `order` is irrelevant and
/// `completedAt` is the only meaningful axis) — that helper answers a
/// different question ("what total, regardless of visitation order") than
/// this one ("what is this set's position").
private extension Array where Element == SetRecordSlice {
    func sortedByOrderThenCompletedAtThenID() -> [SetRecordSlice] {
        sorted { lhs, rhs in
            if lhs.set.order != rhs.set.order {
                return lhs.set.order < rhs.set.order
            }
            if lhs.set.completedAt != rhs.set.completedAt {
                return lhs.set.completedAt < rhs.set.completedAt
            }
            return lhs.set.id.uuidString < rhs.set.id.uuidString
        }
    }
}
