// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — SessionSummary, PersonalRecordData, SessionSummaryBuilder
//
// Spec §2 Finish: "'End workout' → summary: duration, total volume, sets,
// any PRs → Finish (primary) / 'Keep going' / 'Discard'."
//
// This is a pure computation over an `ActiveSession`, not a persisted type —
// the summary is a *view* of the session, computed once when "End workout"
// is tapped and again (identically, since nothing mutates in between) when
// "Finish" commits it. Keeping it here rather than inline in the watch UI
// means the arithmetic — which sets count toward volume, what counts as a
// PR — is exercised by Swift Testing rather than only by an xcui screenshot.
//
// ## Why PRs are digest-scoped, not history-scoped
//
// §7 has a full personal-record computation (`ExerciseProgressionStats
// .personalRecords`) over complete history, but that requires
// `BurlyStore.loggedSetSlices`, which only the phone-shaped full-history
// store can answer cheaply — the watch store holds no SetRecord history
// beyond the in-flight session (§1 store shape) and one digest per exercise
// (`ExerciseLastPerformance`). So "any PRs" on the watch necessarily means
// "beat the last time you did this" rather than "beat your all-time best";
// the phone's history screen (§6) is where the all-time answer lives. A
// `nil` digest (never performed before) is not treated as a PR — a first
// time doing an exercise is not a record over nothing.
//
// Imports Foundation for `UUID`/`TimeInterval` only.
import Foundation

/// One exercise that saw a heavier top set this session than its last-
/// performance digest recorded. Scoped to the session *item* (not just the
/// exercise) so a swap that split a part-logged item (`SessionMutator
/// .swapExercise`) can report both halves independently if both PR'd.
public struct PersonalRecordData: Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID { itemID }
    public var itemID: UUID
    public var exerciseID: UUID
    public var weight: Weight
    public var reps: Int

    public init(itemID: UUID, exerciseID: UUID, weight: Weight, reps: Int) {
        self.itemID = itemID
        self.exerciseID = exerciseID
        self.weight = weight
        self.reps = reps
    }
}

/// The §2 Finish summary: duration, total volume, set count, and any PRs.
public struct SessionSummary: Sendable, Equatable {
    /// Wall-clock length of the session so far (or in full, once ended).
    public var duration: TimeInterval

    /// Σ weight × reps over **working sets only** — warmups are excluded,
    /// same convention as §7's volume stat (spec §1: warmup "excluded from
    /// PR/volume stats").
    public var totalVolumeKg: Double

    /// Every logged set, warmups included — §2 says "sets," not "working
    /// sets," and a warmup is still a set that happened.
    public var totalSets: Int

    /// One entry per item whose heaviest working set this session beat its
    /// last-performance digest. Order matches `ActiveSession.session.items`.
    public var personalRecords: [PersonalRecordData]

    public init(
        duration: TimeInterval,
        totalVolumeKg: Double,
        totalSets: Int,
        personalRecords: [PersonalRecordData]
    ) {
        self.duration = duration
        self.totalVolumeKg = totalVolumeKg
        self.totalSets = totalSets
        self.personalRecords = personalRecords
    }

    /// Display-layer conversion, via `Weight`'s exact avoirdupois constant —
    /// never a second, independently-rounded conversion factor (matches
    /// `WeeklyVolume.totalVolumeLb`'s rationale).
    public var totalVolumeLb: Double {
        totalVolumeKg / Weight.kilogramsPerPound
    }

    public var hasPersonalRecords: Bool { !personalRecords.isEmpty }
}

public enum SessionSummaryBuilder {
    /// Computes the summary for `session` as it stands right now.
    ///
    /// Safe to call before `SessionEngine.finish()` (the "End workout"
    /// preview, before the lifter has chosen Finish/Keep going/Discard) or
    /// after it (the committed summary) — the arithmetic is identical
    /// either way, because nothing mutates the session between showing the
    /// preview and committing it. When `session.session.endedAt` is `nil`
    /// (the preview case), `referenceDate` stands in for "now."
    ///
    /// - Parameters:
    ///   - session: the session to summarize, active or just-finished.
    ///   - referenceDate: "now," for duration when the session has not
    ///     been finished yet. Ignored once `endedAt` is set.
    ///   - lastPerformance: digest lookup by exercise id, for PR detection.
    ///     Returning `nil` (no digest, or lookup failure) means "no PR
    ///     baseline" — never treated as an error (ghost-row acceptance's
    ///     "no crash, no stale data" applies here too).
    public static func summarize(
        _ session: ActiveSession,
        referenceDate: Date,
        lastPerformance: (UUID) -> ExerciseLastPerformanceData?
    ) -> SessionSummary {
        let end = session.session.endedAt ?? referenceDate
        let duration = Swift.max(0, end.timeIntervalSince(session.session.startedAt))

        var totalVolumeKg = 0.0
        var totalSets = 0
        var personalRecords: [PersonalRecordData] = []

        for item in session.session.items {
            totalSets += item.sets.count
            let workingSets = item.sets.filter { !$0.isWarmup }
            for set in workingSets {
                totalVolumeKg += set.weight.kg * Double(set.reps)
            }

            guard
                let exerciseID = item.exerciseID,
                let heaviest = workingSets.max(by: { $0.weight.kg < $1.weight.kg })
            else { continue }

            if let priorBestKg = lastPerformance(exerciseID)?.sets
                .filter({ !$0.isWarmup })
                .map(\.weight.kg)
                .max(),
                heaviest.weight.kg > priorBestKg {
                personalRecords.append(
                    PersonalRecordData(
                        itemID: item.id,
                        exerciseID: exerciseID,
                        weight: heaviest.weight,
                        reps: heaviest.reps
                    )
                )
            }
        }

        return SessionSummary(
            duration: duration,
            totalVolumeKg: totalVolumeKg,
            totalSets: totalSets,
            personalRecords: personalRecords
        )
    }
}
