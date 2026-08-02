// SPDX-License-Identifier: GPL-3.0-or-later
// Spec §2 Finish: "summary: duration, total volume, sets, any PRs."
import Testing
import Foundation
@testable import BurlyCore

@Suite("Session summary — §2 Finish totals")
struct SessionSummaryTests {
    @Test("Duration, volume, and set count over a plain three-set session")
    func basicTotals() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = SessionEngine(
            session: SessionBuilder.session(
                from: Fixture.routine(ids: ids, setCounts: [3], restOverrides: [nil]),
                clock: clock,
                makeID: ids.make
            ),
            clock: clock
        )
        let itemID = engine.session.items[0].id

        try engine.logSet(itemID: itemID, weight: Weight(kg: 60), reps: 8, makeID: ids.make)
        clock.advance(120)
        try engine.logSet(itemID: itemID, weight: Weight(kg: 60), reps: 8, makeID: ids.make)
        clock.advance(120)
        try engine.logSet(itemID: itemID, weight: Weight(kg: 62.5), reps: 6, makeID: ids.make)
        clock.advance(60)

        let summary = SessionSummaryBuilder.summarize(
            engine.session, referenceDate: clock.now, lastPerformance: { _ in nil }
        )

        let expectedVolumeKg: Double = 60.0 * 8.0 + 60.0 * 8.0 + 62.5 * 6.0
        #expect(summary.duration == 300)
        #expect(summary.totalSets == 3)
        #expect(summary.totalVolumeKg == expectedVolumeKg)
        #expect(summary.personalRecords.isEmpty)
    }

    @Test("Warmup sets count toward totalSets but not totalVolumeKg")
    func warmupsExcludedFromVolume() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = SessionEngine(
            session: SessionBuilder.session(
                from: Fixture.routine(ids: ids, setCounts: [2], restOverrides: [nil]),
                clock: clock,
                makeID: ids.make
            ),
            clock: clock
        )
        let itemID = engine.session.items[0].id

        try engine.logSet(itemID: itemID, weight: Weight(kg: 20), reps: 15, isWarmup: true, makeID: ids.make)
        try engine.logSet(itemID: itemID, weight: Weight(kg: 60), reps: 8, makeID: ids.make)

        let summary = SessionSummaryBuilder.summarize(
            engine.session, referenceDate: clock.now, lastPerformance: { _ in nil }
        )

        #expect(summary.totalSets == 2)
        #expect(summary.totalVolumeKg == 60 * 8)
    }

    @Test("A heavier working set than the digest's best is a PR; warmups never contribute to the PR check")
    func personalRecordDetection() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = SessionEngine(
            session: SessionBuilder.session(
                from: Fixture.routine(ids: ids, setCounts: [2], restOverrides: [nil]),
                clock: clock,
                makeID: ids.make
            ),
            clock: clock
        )
        let itemID = engine.session.items[0].id
        let exerciseID = engine.session.item(itemID)!.exerciseID!
        let digest = Fixture.digest(exerciseID: exerciseID, weightsKg: [60, 65], reps: [8, 6])

        // A warmup heavier than the old best must not count as a PR.
        try engine.logSet(itemID: itemID, weight: Weight(kg: 70), reps: 5, isWarmup: true, makeID: ids.make)
        try engine.logSet(itemID: itemID, weight: Weight(kg: 67.5), reps: 5, makeID: ids.make)

        let summary = SessionSummaryBuilder.summarize(
            engine.session, referenceDate: clock.now, lastPerformance: { $0 == exerciseID ? digest : nil }
        )

        #expect(summary.personalRecords.count == 1)
        #expect(summary.personalRecords.first?.itemID == itemID)
        #expect(summary.personalRecords.first?.weight == Weight(kg: 67.5))
        #expect(summary.personalRecords.first?.reps == 5)
    }

    @Test("Never performed before (no digest) is not a PR")
    func noDigestIsNotAPersonalRecord() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = SessionEngine(
            session: SessionBuilder.session(
                from: Fixture.routine(ids: ids, setCounts: [1], restOverrides: [nil]),
                clock: clock,
                makeID: ids.make
            ),
            clock: clock
        )
        let itemID = engine.session.items[0].id

        try engine.logSet(itemID: itemID, weight: Weight(kg: 100), reps: 5, makeID: ids.make)

        let summary = SessionSummaryBuilder.summarize(
            engine.session, referenceDate: clock.now, lastPerformance: { _ in nil }
        )

        #expect(summary.personalRecords.isEmpty)
    }

    @Test("Meeting, not beating, the digest's best is not a PR")
    func tyingIsNotAPersonalRecord() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = SessionEngine(
            session: SessionBuilder.session(
                from: Fixture.routine(ids: ids, setCounts: [1], restOverrides: [nil]),
                clock: clock,
                makeID: ids.make
            ),
            clock: clock
        )
        let itemID = engine.session.items[0].id
        let exerciseID = engine.session.item(itemID)!.exerciseID!
        let digest = Fixture.digest(exerciseID: exerciseID, weightsKg: [80], reps: [5])

        try engine.logSet(itemID: itemID, weight: Weight(kg: 80), reps: 5, makeID: ids.make)

        let summary = SessionSummaryBuilder.summarize(
            engine.session, referenceDate: clock.now, lastPerformance: { $0 == exerciseID ? digest : nil }
        )

        #expect(summary.personalRecords.isEmpty)
    }

    @Test("Using endedAt once the session is finished, ignoring referenceDate")
    func finishedSessionUsesEndedAt() throws {
        let ids = SequentialIDs()
        let clock = ManualClock()
        var engine = SessionEngine(
            session: SessionBuilder.session(
                from: Fixture.routine(ids: ids, setCounts: [1], restOverrides: [nil]),
                clock: clock,
                makeID: ids.make
            ),
            clock: clock
        )
        let itemID = engine.session.items[0].id
        try engine.logSet(itemID: itemID, weight: Weight(kg: 40), reps: 10, makeID: ids.make)
        clock.advance(600)
        try engine.finish()
        clock.advance(999) // Should not affect the computed duration any further.

        let summary = SessionSummaryBuilder.summarize(
            engine.session, referenceDate: clock.now, lastPerformance: { _ in nil }
        )

        #expect(summary.duration == 600)
    }

    @Test("An empty session (no items) summarizes to zeros without crashing")
    func emptySessionSummarizesToZero() {
        let ids = SequentialIDs()
        let clock = ManualClock()
        let engine = SessionEngine(session: SessionBuilder.emptySession(clock: clock, makeID: ids.make), clock: clock)

        let summary = SessionSummaryBuilder.summarize(
            engine.session, referenceDate: clock.now, lastPerformance: { _ in nil }
        )

        #expect(summary.totalSets == 0)
        #expect(summary.totalVolumeKg == 0)
        #expect(summary.personalRecords.isEmpty)
        #expect(summary.duration == 0)
    }
}
