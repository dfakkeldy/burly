// SPDX-License-Identifier: GPL-3.0-or-later
// State for the Hevy import screen (spec §8 flow; task m7-02): intro ->
// choose a file -> read and parse off the main actor -> preview -> import
// with progress -> summary.
//
// The preview and the write come from one `HevyImportPlan` (BurlyImport),
// so the summary can only show what the preview promised (§8 acceptance
// #4). The one way they could drift is the store changing while the
// preview sits on screen (a watch session syncing in, say); `importPlanned`
// re-plans immediately before writing and, if the numbers moved, shows the
// fresh preview again instead of writing something the user didn't see.
//
// Nothing here touches HealthKit (§8: "No HKWorkout writes for imports";
// acceptance #3): writes go through `PhoneHomeViewModel`'s strict store
// creates, and the plan forces every session's `healthKitWorkoutID` to nil.

import Foundation
import BurlyCore
import BurlyImport
import Observation

@MainActor
@Observable
final class HevyImportModel {
    enum Phase {
        case intro
        case reading
        case preview(HevyImportPlan)
        case importing(workoutsWritten: Int, workoutsTotal: Int)
        case finished(plan: HevyImportPlan, outcome: HevyImportOutcome)
        /// Spec §8: "only an unrecognizable header aborts."
        case unrecognizedHeader(missingColumns: [String])
        case unreadable(String)
        /// The file parsed, but the store read behind the plan threw. Kept
        /// apart from `.unreadable` (m7-02 review): the file is fine, and
        /// after a partial import some workouts did land, so "couldn't read
        /// that file, nothing was imported" would be false twice over.
        case historyCheckFailed(afterPartialImport: Bool)
    }

    private(set) var phase: Phase = .intro
    /// Set when `importPlanned` found the store had changed under the
    /// preview and replaced it, so the screen can say why the numbers moved.
    private(set) var previewWasRefreshed = false

    /// Hevy's CSV carries no time zone (m7-01 finding 6.1), so the parse
    /// needs an assumption; this screen uses the phone's own zone and says
    /// so on the preview, because a wrong zone shifts workout days.
    let timeZone: TimeZone

    private let viewModel: PhoneHomeViewModel
    private var parsed: ParsedExport?

    private struct ParsedExport: Sendable {
        let result: HevyImportResult
        let catalog: CatalogSeed
    }

    init(viewModel: PhoneHomeViewModel, timeZone: TimeZone = .current) {
        self.viewModel = viewModel
        self.timeZone = timeZone
    }

    var isImporting: Bool {
        if case .importing = phase { return true }
        return false
    }

    var isFinished: Bool {
        if case .finished = phase { return true }
        return false
    }

    /// "Atlantic Time", "Central European Time", … — the generic name, since
    /// an export spans both sides of a daylight-saving change.
    var timeZoneName: String {
        timeZone.localizedName(for: .generic, locale: .current) ?? timeZone.identifier
    }

    // MARK: - Reading

    /// Reads a file the document picker handed back. The URL is security-
    /// scoped (it points outside the sandbox), so access is opened and
    /// closed around the read, off the main actor.
    func readFile(at url: URL) async {
        await read { try Self.readSecurityScoped(url) }
    }

    func readData(_ data: Data) async {
        await read { data }
    }

    func reportFailure(_ error: Error) {
        phase = .unreadable(error.localizedDescription)
    }

    func startOver() {
        parsed = nil
        previewWasRefreshed = false
        phase = .intro
    }

    private func read(_ load: @escaping @Sendable () throws -> Data) async {
        phase = .reading
        previewWasRefreshed = false
        parsed = nil
        let timeZone = timeZone
        let export: ParsedExport
        do {
            // Parsing a multi-year export is real work; keep it off the main
            // actor. Only the plan (which reads the store) comes back to it.
            export = try await Task.detached(priority: .userInitiated) {
                let data = try load()
                let catalog = try CatalogSeed.loadBundled()
                let result = try HevyCSVImporter.parse(csvData: data, catalog: catalog, timeZone: timeZone)
                return ParsedExport(result: result, catalog: catalog)
            }.value
        } catch HevyImportError.unrecognizedHeader(let missingColumns) {
            phase = .unrecognizedHeader(missingColumns: missingColumns)
            return
        } catch {
            phase = .unreadable(error.localizedDescription)
            return
        }
        parsed = export
        do {
            phase = .preview(try viewModel.planHevyImport(export.result, catalog: export.catalog))
        } catch {
            phase = .historyCheckFailed(afterPartialImport: false)
        }
    }

    nonisolated private static func readSecurityScoped(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        return try Data(contentsOf: url)
    }

    // MARK: - Importing

    /// Writes the previewed plan, one row graph per step so the progress bar
    /// moves and the app stays responsive. Also the "Try again" path after a
    /// failure part-way: re-planning skips whatever already landed.
    func importPlanned() async {
        guard let parsed else { return }
        let shownPreview: HevyImportPreview?
        switch phase {
        case .preview(let plan):
            shownPreview = plan.preview
        case .finished(_, let outcome) where outcome.isComplete == false:
            shownPreview = nil
        default:
            return
        }

        let plan: HevyImportPlan
        do {
            plan = try viewModel.planHevyImport(parsed.result, catalog: parsed.catalog)
        } catch {
            // From a partial-failure summary, some workouts are already in
            // History; the screen must not claim otherwise.
            phase = .historyCheckFailed(afterPartialImport: shownPreview == nil)
            return
        }
        // Stale-preview guard: write only what the user just looked at. A
        // retry after a partial failure has no preview to honor, so it shows
        // the fresh one (what is still missing) and waits for a tap.
        guard let shownPreview, plan.preview == shownPreview else {
            previewWasRefreshed = shownPreview != nil
            phase = .preview(plan)
            return
        }
        guard plan.preview.isNothingNew == false else { return }

        var cursor = HevyImportCommitCursor(plan: plan)
        let total = plan.preview.newWorkoutCount
        phase = .importing(workoutsWritten: 0, workoutsTotal: total)
        while cursor.isFinished == false {
            viewModel.writeNextHevyImportStep(&cursor)
            phase = .importing(workoutsWritten: cursor.sessionsWritten, workoutsTotal: total)
            // Each step is one SwiftData save on the main actor. Suspending
            // briefly between them lets SwiftUI draw the progress and handle
            // input; a plain `Task.yield()` can resume before the run loop
            // gets a turn.
            try? await Task.sleep(for: .milliseconds(1))
        }
        // Refresh whether or not every write landed: whatever did land is
        // real history now and History/Stats should show it.
        viewModel.refreshAfterHevyImport()
        phase = .finished(plan: plan, outcome: cursor.outcome)
    }
}
