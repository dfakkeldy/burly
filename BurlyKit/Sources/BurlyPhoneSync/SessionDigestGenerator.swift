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
// Every `lastPerformance` entry is the **exact latest-per-exercise
// derivation over the phone's full current `.logged` history at generation
// time** — not a delta, not "what changed". Which exercises get an entry is
// bounded, in two steps, because the digest rides `updateApplicationContext`
// and that channel refuses a payload over roughly 64 KB (an undocumented
// limit; WCError `payloadTooLarge`). An unbounded digest made a heavy
// history (a multi-year Hevy import) fail every publish, silently and
// forever: no acks, so no pruning on the watch.
//
// 1. **The watch's working set.** Only exercises the current snapshot
//    carries (`WatchWorkingSet`: the non-archived catalog plus archived
//    exercises a live routine still uses). The watch cannot start or add
//    anything else, so it can never show a ghost row for anything else.
// 2. **A byte budget** (`applicationContextByteBudget`). Hevy imports its
//    exercises non-archived, so step 1 alone still leaves hundreds of
//    entries. When the encoded envelope would exceed the budget, entries
//    are kept in order of use — exercises a routine starts with first, then
//    the most recently performed — until the next one would not fit.
//
// The watch upserts the entries it receives and never deletes a row for an
// exercise a digest leaves out (`BurlyStore.applyDigest`), so an absent
// entry means "no update", not "erase". It is still a claim the watch acts
// on: it prunes an acknowledged session whatever the entries say, and an
// exercise whose latest numbers were in that session would be left with
// older ones. The ordering is what makes that safe in practice: an
// acknowledged session is at most §5's 30-day ack retention old, so its
// exercises rank among the most recently performed and are the last to be
// trimmed.
//
// The degenerate case still holds: an empty store (nothing ever logged, or
// everything since deleted) produces an empty `lastPerformance`, emittable
// alongside a non-empty `ackedSessionIDs` (the acked-then-deleted sequence
// `BurlyStore.applyDigest`'s doc walks through). `ackedSessionIDs` is never
// trimmed: it is what lets the watch prune, and §5's 30-day retention in
// `PhoneSyncMachine` already bounds it to the sessions a watch delivered in
// that window (Hevy-imported sessions are never acknowledged). Nothing here
// validates the acks against `lastPerformance`; they are two independent
// facts, exactly as `PhoneSyncMachine.Command.publishDigest`'s two
// parameters are.
//
// ## A narrow read, not full history (issue #24)
//
// This used to read `BurlyStore.allLoggedSetSlices()`, every logged set the
// phone holds, on the main actor at every history change and launch: 8.4 s
// at 50k sets on hosted CI, for 12 entries. It now asks the store only for
// each working-set exercise's latest session
// (`BurlyStore.latestLoggedSetSlices(forExercises:)`), which picks winners
// with the same `LatestLoggedSession.isLater` rule this file's derivation
// uses, so the derivation below returns exactly what it would have returned
// over full history.
import Foundation
import BurlyCore
import BurlyPersistence
import BurlySync
import os

public enum SessionDigestGenerator {
    /// The encoded-envelope ceiling `generate` trims `lastPerformance` to:
    /// 48 KB, a quarter under the roughly 64 KB that Watch Connectivity's
    /// application context accepts, leaving room for the dictionary
    /// wrapping the envelope and for an uncertain limit Apple does not
    /// document.
    public static let applicationContextByteBudget = 48 * 1024

    /// Derives and builds the §5 `digest` payload: the machine-owned
    /// `snapshotVersion`/`ackedSessionIDs` (`PhoneSyncMachine.Command
    /// .publishDigest`'s two facts), `lastPerformance` for the watch's
    /// working set, and each non-archived routine's last-performed date, all
    /// read from `store` **at the moment this runs**, never from a cached or
    /// earlier read, which is what makes "at generation time" true rather
    /// than aspirational.
    ///
    /// The returned payload's encoded envelope stays within `byteBudget`
    /// unless the acks and routine dates alone exceed it (they are never
    /// trimmed; see the file doc).
    @MainActor
    public static func generate(
        from store: any BurlyStore,
        snapshotVersion: Int,
        ackedSessionIDs: Set<UUID>,
        byteBudget: Int = applicationContextByteBudget
    ) throws -> BurlyDigestPayloadDTO {
        let workingSet = try WatchWorkingSet(from: store)
        let slices = try store.latestLoggedSetSlices(forExercises: Set(workingSet.exercises.map(\.id)))
        let routineIDs = Set(workingSet.routines.map(\.id))
        let routineDates = try store.routineLastPerformedDates()
            .filter { routineIDs.contains($0.key) }
            .map { BurlyRoutineLastPerformedDTO(routineID: $0.key, performedAt: $0.value) }
            .sorted { $0.routineID.uuidString < $1.routineID.uuidString }
        let payload = BurlyDigestPayloadDTO(
            snapshotVersion: snapshotVersion,
            lastPerformance: latestPerformancePerExercise(from: slices),
            ackedSessionIDs: ackedSessionIDs.sorted { $0.uuidString < $1.uuidString },
            routineLastPerformed: routineDates
        )
        return try fitting(payload, within: byteBudget, routineExerciseIDs: workingSet.routineExerciseIDs)
    }

    /// `payload` itself when its encoded envelope fits `budget`; otherwise
    /// the same payload with `lastPerformance` cut to the entries that fit,
    /// kept in this order: exercises in `routineExerciseIDs` first, then by
    /// `performedAt`, newest first, then by exercise id. The kept entries
    /// stay sorted by exercise id, like every digest, so equal input always
    /// encodes to equal bytes.
    ///
    /// Sizes are measured, not estimated: each entry is encoded once with
    /// the same encoder the envelope uses, and JSON array encoding adds
    /// exactly one comma per extra element, so the sum is the envelope's
    /// size. The result is checked by encoding it anyway.
    static func fitting(
        _ payload: BurlyDigestPayloadDTO,
        within budget: Int,
        routineExerciseIDs: Set<UUID>
    ) throws -> BurlyDigestPayloadDTO {
        let fullSize = try envelopeByteCount(payload)
        guard fullSize > budget else { return payload }

        let ranked = payload.lastPerformance.sorted { lhs, rhs in
            let lhsInRoutine = routineExerciseIDs.contains(lhs.exerciseID)
            let rhsInRoutine = routineExerciseIDs.contains(rhs.exerciseID)
            if lhsInRoutine != rhsInRoutine { return lhsInRoutine }
            if lhs.performedAt != rhs.performedAt { return lhs.performedAt > rhs.performedAt }
            return lhs.exerciseID.uuidString < rhs.exerciseID.uuidString
        }
        let encoder = JSONEncoder()
        var used = try envelopeByteCount(payload.replacingLastPerformance([]))
        var kept: [ExerciseLastPerformanceData] = []
        for entry in ranked {
            let cost = try encoder.encode(entry).count + (kept.isEmpty ? 0 : 1)
            guard used + cost <= budget else { break }
            used += cost
            kept.append(entry)
        }

        var trimmed = payload.replacingLastPerformance(
            kept.sorted { $0.exerciseID.uuidString < $1.exerciseID.uuidString }
        )
        // The arithmetic above is exact; this only guards a future encoder
        // change that would break it.
        while try envelopeByteCount(trimmed) > budget, !kept.isEmpty {
            kept.removeLast()
            trimmed = payload.replacingLastPerformance(
                kept.sorted { $0.exerciseID.uuidString < $1.exerciseID.uuidString }
            )
        }
        PhoneSyncLog.logger.notice("digest trimmed to \(kept.count, privacy: .public) of \(payload.lastPerformance.count, privacy: .public) exercises: \(fullSize, privacy: .public) bytes exceeded the \(budget, privacy: .public)-byte budget")
        return trimmed
    }

    /// The byte count of `payload`'s envelope exactly as
    /// `PhoneWCSessionBridge.publishDigest` encodes it.
    static func envelopeByteCount(_ payload: BurlyDigestPayloadDTO) throws -> Int {
        try BurlySyncEnvelope(payload: .digest(payload)).encodedData().count
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
    /// full determinism — `LatestLoggedSession.isLater`, the rule the
    /// store's narrow read shares), and returns every slice
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
                if LatestLoggedSession.isLater(
                    (startedAt: candidate.startedAt, sessionID: candidate.sessionID),
                    than: (startedAt: current.startedAt, sessionID: current.sessionID)
                ) {
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
}

private extension BurlyDigestPayloadDTO {
    func replacingLastPerformance(_ entries: [ExerciseLastPerformanceData]) -> BurlyDigestPayloadDTO {
        BurlyDigestPayloadDTO(
            snapshotVersion: snapshotVersion,
            lastPerformance: entries,
            ackedSessionIDs: ackedSessionIDs,
            routineLastPerformed: routineLastPerformed
        )
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
