// SPDX-License-Identifier: GPL-3.0-or-later
// Loads the iPhone shell's shared state from the phone store (spec m5-01):
// the History, Routines, and Stats tabs all render from this one load.
//
// The shell's appearance load is deliberately bounded (m5-01 review
// finding 3): it asks existence/count questions — `hasRoutines()` and
// `loggedSessionCount()` — never full graphs. A decade-old phone store
// holds ~40-50k rows; hydrating every routine's items and every session's
// items→sets just to draw empty states and a workout count was the review's
// exact complaint. The tabs that render rows load them from the store's
// existing surfaces only when that tab is shown (`loadRoutinesForDisplay`
// / `loadSessionsForDisplay`).
//
// The two domains carry independent `LoadState`s (m5-01 review finding 4):
// a failed routine query must not disable History or Stats, and a failed
// session query must not disable Routines — each tab renders only its own
// domain's state, so one failure never replaces valid content in an
// unrelated tab.

import Foundation
import BurlyCore
import BurlyPersistence
import Observation

@MainActor
@Observable
final class PhoneHomeViewModel {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    // Routines domain (Routines tab).
    private(set) var routinesState: LoadState = .loading
    private(set) var hasRoutines = false
    private(set) var routineRows: [RoutineData] = []

    // Exercise catalog domain. This is loaded only by the catalog browser;
    // unlike session history it is the bounded, roughly-100-row §9 catalog.
    private(set) var catalogState: LoadState = .loading
    private(set) var catalogExercises: [ExerciseData] = []

    // Logged-session domain (History and Stats tabs).
    private(set) var sessionsState: LoadState = .loading
    private(set) var loggedSessionCount = 0
    private(set) var sessionRows: [SessionData] = []

    // Stats domain. Unlike the shell's count-only snapshot above, this is
    // loaded only when Stats appears and uses the §7 bounded query surfaces.
    private(set) var statsState: LoadState = .loading
    private(set) var stats: PhoneStatsDashboard?

    private let store: BurlyStore

    init(store: BurlyStore) {
        self.store = store
    }

    // MARK: - Bounded shell snapshot (finding 3)

    /// The shell's appearance/foreground snapshot: existence and count
    /// only, from the bounded queries — never full graphs. Each domain
    /// loads independently (finding 4), so one failing query does not
    /// disable the other domain's tabs.
    func load() {
        loadRoutines()
        loadSessions()
    }

    /// Routines existence, at routine-table cost.
    func loadRoutines() {
        routinesState = .loading
        do {
            hasRoutines = try store.hasRoutines()
            routinesState = .loaded
        } catch {
            routinesState = .failed(String(describing: error))
        }
    }

    /// Logged-session count, at flat-session-row cost (the Stats scalar).
    func loadSessions() {
        sessionsState = .loading
        do {
            loggedSessionCount = try store.loggedSessionCount()
            sessionsState = .loaded
        } catch {
            sessionsState = .failed(String(describing: error))
        }
    }

    // MARK: - Per-tab display loads (rows only when the tab is shown)

    /// Routines rows — the store's own §9 surface. Called only when the
    /// Routines tab is shown (its `.task`) or its Retry is tapped, never
    /// from the shell's appearance load (finding 3).
    func loadRoutinesForDisplay() {
        routinesState = .loading
        do {
            hasRoutines = try store.hasRoutines()
            routineRows = try store.routines(includingArchived: false)
            routinesState = .loaded
        } catch {
            routinesState = .failed(String(describing: error))
        }
    }

    // MARK: - Routines authoring (§9)

    /// Creates a phone-authored routine at the end of the user's current
    /// order. The store owns the write; this coordinator owns the caller
    /// policy the store deliberately leaves open: dense manual indices.
    @discardableResult
    func createRoutine(named rawName: String) throws -> RoutineData {
        let name = try validatedName(rawName, kind: "routine")
        let current = try store.routines(includingArchived: false)
        let draft = RoutineData(
            name: name,
            orderIndex: current.count,
            items: [],
            updatedAt: .now
        )
        try store.createRoutine(draft)
        let rows = try store.routines(includingArchived: false)
        routineRows = rows
        hasRoutines = !rows.isEmpty
        routinesState = .loaded
        guard let created = rows.first(where: { $0.id == draft.id }) else {
            throw PhoneRoutineError.createdRoutineMissing
        }
        return created
    }

    /// Applies the editor's complete working copy. Item ordering is made
    /// dense here, alongside list ordering, rather than being inferred by a
    /// SwiftUI `List` or by relationship order in SwiftData.
    func saveRoutine(
        id: UUID,
        name rawName: String,
        items: [RoutineItemData]
    ) throws {
        let name = try validatedName(rawName, kind: "routine")
        guard var routine = try store.routine(id: id) else {
            throw PhoneRoutineError.routineMissing
        }
        routine.name = name
        routine.items = normalizedItems(items)
        try store.updateRoutine(routine)
        try refreshRoutinesAfterMutation()
    }

    /// Reorders the visible active routine list and persists every affected
    /// manual index. `BurlyStore` documents this as caller policy, so it
    /// cannot live in the SwiftUI view that happened to initiate the move.
    func reorderRoutines(from offsets: IndexSet, to destination: Int) throws {
        var reordered = routineRows
        reordered.move(fromOffsets: offsets, toOffset: destination)
        for index in reordered.indices {
            var routine = reordered[index]
            routine.orderIndex = index
            try store.updateRoutine(routine)
        }
        try refreshRoutinesAfterMutation()
    }

    func archiveRoutine(id: UUID) throws {
        try store.archiveRoutine(id: id, at: .now)
        try refreshRoutinesAfterMutation()
    }

    /// Presentation drafts can ask the coordinator to construct a new item
    /// with the product default. The store still validates the exercise id on
    /// save, before touching persisted routine data.
    func newRoutineItem(for exerciseID: UUID, after items: [RoutineItemData]) -> RoutineItemData {
        RoutineItemData(exerciseID: exerciseID, order: items.count)
    }

    func movedRoutineItems(
        _ items: [RoutineItemData],
        from offsets: IndexSet,
        to destination: Int
    ) -> [RoutineItemData] {
        var moved = items
        moved.move(fromOffsets: offsets, toOffset: destination)
        return normalizedItems(moved)
    }

    func movingRoutineItem(
        id: UUID,
        by offset: Int,
        in items: [RoutineItemData]
    ) -> [RoutineItemData] {
        guard let source = items.firstIndex(where: { $0.id == id }) else { return items }
        let destination = source + offset
        guard items.indices.contains(destination) else { return items }
        // `move(fromOffsets:toOffset:)` interprets the insertion position
        // after removing its source, hence the one-slot adjustment downward.
        let insertionOffset = offset > 0 ? destination + 1 : destination
        return movedRoutineItems(
            items,
            from: IndexSet(integer: source),
            to: insertionOffset
        )
    }

    func adjustedRoutineItem(_ item: RoutineItemData, setCountDelta: Int) -> RoutineItemData {
        var adjusted = item
        adjusted.defaultSetCount = max(1, adjusted.defaultSetCount + setCountDelta)
        return adjusted
    }

    func restOverriddenRoutineItem(
        _ item: RoutineItemData,
        with restOverride: TimeInterval?
    ) -> RoutineItemData {
        var adjusted = item
        adjusted.restOverride = restOverride
        return adjusted
    }

    func removingRoutineItem(id: UUID, from items: [RoutineItemData]) -> [RoutineItemData] {
        normalizedItems(items.filter { $0.id != id })
    }

    // MARK: - Catalog authoring (§9)

    /// Catalog loading is intentionally on-demand. The bundled catalog is
    /// small and the store's own surface hides archived rows for browser and
    /// picker use.
    func loadCatalogForDisplay() {
        catalogState = .loading
        do {
            catalogExercises = try store.exercises(includingArchived: false)
            catalogState = .loaded
        } catch {
            catalogState = .failed(String(describing: error))
        }
    }

    @discardableResult
    func createCustomExercise(named rawName: String, muscleGroups: [MuscleGroup]) throws -> ExerciseData {
        let name = try validatedName(rawName, kind: "exercise")
        guard !muscleGroups.isEmpty else {
            throw PhoneRoutineError.noMuscleGroups
        }
        let exercise = ExerciseData(
            name: name,
            muscleGroups: muscleGroups,
            origin: .custom
        )
        try store.createExercise(exercise)
        let rows = try store.exercises(includingArchived: false)
        catalogExercises = rows
        catalogState = .loaded
        guard let created = rows.first(where: { $0.id == exercise.id }) else {
            throw PhoneRoutineError.createdExerciseMissing
        }
        return created
    }

    func archiveExercise(id: UUID) throws {
        try store.archiveExercise(id: id, at: .now)
        catalogExercises = try store.exercises(includingArchived: false)
        catalogState = .loaded
    }

    private func refreshRoutinesAfterMutation() throws {
        routineRows = try store.routines(includingArchived: false)
        hasRoutines = !routineRows.isEmpty
        routinesState = .loaded
    }

    private func normalizedItems(_ items: [RoutineItemData]) -> [RoutineItemData] {
        items.enumerated().map { index, item in
            var normalized = item
            normalized.order = index
            return normalized
        }
    }

    private func validatedName(_ rawName: String, kind: String) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PhoneRoutineError.emptyName(kind: kind) }
        return name
    }

    /// History rows — the store's own §6 history surface. Called only when
    /// the History tab is shown (its `.task`) or its Retry is tapped, never
    /// from the shell's appearance load (finding 3).
    func loadSessionsForDisplay() {
        sessionsState = .loading
        do {
            loggedSessionCount = try store.loggedSessionCount()
            sessionRows = try store.sessions(state: .logged)
            sessionsState = .loaded
        } catch {
            sessionsState = .failed(String(describing: error))
        }
    }

    // MARK: - Stats (§7; bounded store queries + BurlyCore computation)

    /// Loads the four phone-only §7 charts. This is intentionally a
    /// separate, on-demand load: the shell needs only a session count, while
    /// Stats needs its own bounded set/date projections. Keep all store
    /// access here on the main actor; views only format these results.
    func loadStats(
        progressionRange: PhoneStatsProgressionRange,
        volumeRange: PhoneStatsVolumeRange,
        muscleWindowWeeks: Int = 4,
        exerciseID: UUID? = nil
    ) {
        statsState = .loading

        let referenceDate = Date()
        let calendar = Calendar.autoupdatingCurrent
        do {
            // The catalog is intentionally small (~100 rows), and supplies
            // both the progression picker and muscle-tag attribution.
            let exercises = try store.exercises(includingArchived: true)
            let selectedExercise = exerciseID.flatMap { requestedID in
                exercises.first(where: { $0.id == requestedID })
            } ?? exercises.first(where: { $0.name == "Back Squat" }) ?? exercises.first

            let displayRange = progressionRange.dateRange(asOf: referenceDate, calendar: calendar)
            let progression: PhoneStatsProgression
            if let selectedExercise {
                // This blessed store integration fetches the complete
                // single-exercise history before marking PRs, then filters
                // records to the displayed range. Do not replace it with a
                // date-bounded raw slice query: that would create false PRs.
                let result = try store.exerciseProgression(
                    exerciseID: selectedExercise.id,
                    displayRange: displayRange
                )
                progression = PhoneStatsProgression(
                    exercise: selectedExercise,
                    points: result.points.filter { point in
                        displayRange?.contains(point.date) ?? true
                    },
                    records: result.records
                )
            } else {
                progression = .empty
            }

            let volumeSlices = try store.loggedSetSlices(
                window: .weeks(volumeRange.weekCount),
                through: referenceDate,
                calendar: calendar
            )
            let volumeWindow = CalendarBucketing.trailingWeekWindow(
                weekCount: volumeRange.weekCount,
                asOf: referenceDate,
                calendar: calendar
            )
            let volume = PhoneStatsDashboard.denseVolume(
                VolumeStats.weeklyVolume(from: volumeSlices, calendar: calendar),
                from: volumeWindow.since,
                through: referenceDate,
                calendar: calendar
            )

            let muscleSlices = try store.loggedSetSlices(
                window: .weeks(muscleWindowWeeks),
                through: referenceDate,
                calendar: calendar
            )
            let muscleGroupsByExerciseID = Dictionary(
                uniqueKeysWithValues: exercises.map { ($0.id, $0.muscleGroups) }
            )
            let muscleSplit = MuscleSplitStats.fractionalSplit(
                from: muscleSlices,
                muscleGroupsByExerciseID: muscleGroupsByExerciseID
            )

            let consistencyWindow = CalendarBucketing.trailingWeekWindow(
                weekCount: PhoneStatsDashboard.consistencyWeekCount,
                asOf: referenceDate,
                calendar: calendar
            )
            let sessionDates = try store.loggedSessionDates(
                since: consistencyWindow.since,
                through: consistencyWindow.through
            )
            let consistency = ConsistencyStats.summarize(
                sessionDates: sessionDates,
                since: consistencyWindow.since,
                asOf: referenceDate,
                calendar: calendar
            )

            stats = PhoneStatsDashboard(
                exercises: exercises,
                progression: progression,
                volume: volume,
                muscleSplit: muscleSplit,
                consistency: consistency,
                consistencyWeeks: PhoneStatsDashboard.denseConsistencyWeeks(
                    consistency.weeks,
                    from: consistencyWindow.since,
                    through: referenceDate,
                    calendar: calendar
                ),
                calendarDots: PhoneStatsDashboard.calendarDots(
                    from: consistency.calendarDots,
                    asOf: referenceDate,
                    calendar: calendar
                )
            )
            statsState = .loaded
        } catch {
            stats = nil
            statsState = .failed(String(describing: error))
        }
    }
}

/// Authoring validation belongs beside the coordinator that turns phone UI
/// intent into store operations, rather than being scattered among buttons
/// and sheets. The messages are safe to show in the editor's error alert.
enum PhoneRoutineError: LocalizedError {
    case emptyName(kind: String)
    case noMuscleGroups
    case routineMissing
    case createdRoutineMissing
    case createdExerciseMissing

    var errorDescription: String? {
        switch self {
        case .emptyName(let kind): "Enter a \(kind) name."
        case .noMuscleGroups: "Choose at least one muscle group."
        case .routineMissing: "This routine is no longer available."
        case .createdRoutineMissing: "The new routine could not be reloaded."
        case .createdExerciseMissing: "The new exercise could not be reloaded."
        }
    }
}

/// Range choice for the progression chart. This is presentation state only;
/// `BurlyStore.exerciseProgression` remains responsible for PR correctness.
enum PhoneStatsProgressionRange: String, CaseIterable, Identifiable {
    case threeMonths
    case sixMonths
    case oneYear
    case all

    var id: Self { self }

    var title: String {
        switch self {
        case .threeMonths: "3M"
        case .sixMonths: "6M"
        case .oneYear: "1Y"
        case .all: "All"
        }
    }

    func dateRange(asOf date: Date, calendar: Calendar) -> ClosedRange<Date>? {
        let component: Calendar.Component
        let amount: Int
        switch self {
        case .threeMonths:
            component = .month
            amount = -3
        case .sixMonths:
            component = .month
            amount = -6
        case .oneYear:
            component = .year
            amount = -1
        case .all:
            return nil
        }
        let start = calendar.date(byAdding: component, value: amount, to: date) ?? date
        return start...date
    }
}

enum PhoneStatsVolumeRange: String, CaseIterable, Identifiable {
    case eightWeeks
    case twentySixWeeks
    case fiftyTwoWeeks

    var id: Self { self }

    var title: String {
        switch self {
        case .eightWeeks: "8W"
        case .twentySixWeeks: "26W"
        case .fiftyTwoWeeks: "52W"
        }
    }

    var weekCount: Int {
        switch self {
        case .eightWeeks: 8
        case .twentySixWeeks: 26
        case .fiftyTwoWeeks: 52
        }
    }
}

struct PhoneStatsProgression {
    let exercise: ExerciseData?
    let points: [ExerciseSessionPoint]
    let records: [PersonalRecord]

    static let empty = PhoneStatsProgression(exercise: nil, points: [], records: [])
}

struct PhoneStatsVolumePoint: Identifiable {
    let weekStart: Date
    let totalVolumeKg: Double

    var id: Date { weekStart }
}

struct PhoneStatsCalendarDot: Identifiable {
    let date: Date
    let hasSession: Bool

    var id: Date { date }
}

struct PhoneStatsConsistencyWeek: Identifiable {
    let weekStart: Date
    let count: Int

    var id: Date { weekStart }
}

struct PhoneStatsDashboard {
    static let consistencyWeekCount = 8
    static let calendarDotDayCount = 28

    let exercises: [ExerciseData]
    let progression: PhoneStatsProgression
    let volume: [PhoneStatsVolumePoint]
    let muscleSplit: MuscleSplitSummary
    let consistency: ConsistencySummary
    let consistencyWeeks: [PhoneStatsConsistencyWeek]
    let calendarDots: [PhoneStatsCalendarDot]

    static func denseVolume(
        _ buckets: [WeeklyVolume],
        from start: Date,
        through referenceDate: Date,
        calendar: Calendar
    ) -> [PhoneStatsVolumePoint] {
        let values = Dictionary(uniqueKeysWithValues: buckets.map { ($0.weekStart, $0.totalVolumeKg) })
        return weekStarts(from: start, through: referenceDate, calendar: calendar).map {
            PhoneStatsVolumePoint(weekStart: $0, totalVolumeKg: values[$0, default: 0])
        }
    }

    static func calendarDots(
        from sessionDays: [Date],
        asOf referenceDate: Date,
        calendar: Calendar
    ) -> [PhoneStatsCalendarDot] {
        let activeDays = Set(sessionDays)
        let window = CalendarBucketing.trailingDayWindow(
            dayCount: calendarDotDayCount,
            asOf: referenceDate,
            calendar: calendar
        )
        return dayStarts(from: window.since, through: referenceDate, calendar: calendar).map {
            PhoneStatsCalendarDot(date: $0, hasSession: activeDays.contains($0))
        }
    }

    static func denseConsistencyWeeks(
        _ buckets: [WeeklySessionCount],
        from start: Date,
        through referenceDate: Date,
        calendar: Calendar
    ) -> [PhoneStatsConsistencyWeek] {
        let values = Dictionary(uniqueKeysWithValues: buckets.map { ($0.weekStart, $0.sessionCount) })
        return weekStarts(from: start, through: referenceDate, calendar: calendar).map {
            PhoneStatsConsistencyWeek(weekStart: $0, count: values[$0, default: 0])
        }
    }

    static func weekStarts(from start: Date, through end: Date, calendar: Calendar) -> [Date] {
        var starts: [Date] = []
        var cursor = CalendarBucketing.weekStart(for: start, calendar: calendar)
        let final = CalendarBucketing.weekStart(for: end, calendar: calendar)
        while cursor <= final {
            starts.append(cursor)
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: cursor), next > cursor else {
                break
            }
            cursor = next
        }
        return starts
    }

    static func dayStarts(from start: Date, through end: Date, calendar: Calendar) -> [Date] {
        var starts: [Date] = []
        var cursor = CalendarBucketing.dayStart(for: start, calendar: calendar)
        let final = CalendarBucketing.dayStart(for: end, calendar: calendar)
        while cursor <= final {
            starts.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else {
                break
            }
            cursor = next
        }
        return starts
    }
}

#if DEBUG
extension PhoneHomeViewModel {
    /// A loaded view model over an empty in-memory store, for SwiftUI
    /// previews: a fresh phone store answers "nothing yet," so previews show
    /// the real empty states. Kept out of `#Preview` closures because a
    /// `try!` inside a result builder trips a compiler diagnostic bug.
    static var previewLoaded: PhoneHomeViewModel {
        let viewModel = PhoneHomeViewModel(store: try! SwiftDataStore.phone(at: .inMemory))
        viewModel.load()
        return viewModel
    }
}
#endif
