// SPDX-License-Identifier: MIT
// Spec §2 mid-session edits: the swap/add "catalog picker: recents →
// curated → customs". Pure ordering over the catalog the watch already
// holds, so the watch view model only has to supply what "recent" means
// for this session.
import Foundation

public enum ExercisePickerOrder {
    /// How many exercises the recents head holds before the catalog
    /// groups start. Long enough for a full routine, short enough that the
    /// curated list is still one crown turn away.
    public static let recentLimit = 8

    /// - Parameters:
    ///   - exercises: the catalog, already without archived exercises.
    ///   - sessionExerciseIDs: the exercises in the session being logged,
    ///     in session order. These lead the recents: a lifter adding or
    ///     swapping mid-workout most often wants one already in play.
    ///   - lastPerformedAt: the digest's `performedAt` for an exercise, or
    ///     `nil` when the watch has none. Digest recents follow, newest
    ///     first.
    ///   - excluding: an exercise to leave out, such as the one a swap
    ///     would replace (swapping an exercise for itself does nothing).
    /// - Returns: recents (capped at `recentLimit`), then curated
    ///   exercises, then customs and imports, each group by name. Unnamed
    ///   watch placeholders (`needsNaming`) are left out: they all read
    ///   "Custom exercise", and "Custom (name later)" makes a fresh one.
    public static func ordered(
        _ exercises: [ExerciseData],
        sessionExerciseIDs: [UUID],
        lastPerformedAt: (UUID) -> Date?,
        excluding excludedID: UUID? = nil,
        recentLimit: Int = recentLimit
    ) -> [ExerciseData] {
        let candidates = exercises.filter {
            !$0.needsNaming && $0.archivedAt == nil && $0.id != excludedID
        }
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var recentIDs: [UUID] = []
        func appendRecent(_ id: UUID) {
            guard recentIDs.count < recentLimit, byID[id] != nil, !recentIDs.contains(id) else { return }
            recentIDs.append(id)
        }
        sessionExerciseIDs.forEach(appendRecent)
        candidates
            .compactMap { exercise in lastPerformedAt(exercise.id).map { (exercise, $0) } }
            .sorted { lhs, rhs in
                lhs.1 != rhs.1 ? lhs.1 > rhs.1 : byName(lhs.0, rhs.0)
            }
            .forEach { appendRecent($0.0.id) }

        let recentSet = Set(recentIDs)
        let rest = candidates.filter { !recentSet.contains($0.id) }
        let curated = rest.filter { $0.origin == .curated }.sorted(by: byName)
        let customs = rest.filter { $0.origin != .curated }.sorted(by: byName)
        return recentIDs.compactMap { byID[$0] } + curated + customs
    }

    private static func byName(_ lhs: ExerciseData, _ rhs: ExerciseData) -> Bool {
        switch lhs.name.localizedCaseInsensitiveCompare(rhs.name) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
