// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyStore+ExerciseProgression — the blessed integration path from
// m6-01 fix round 2, review item 3.
//
// `ExerciseProgressionStats.personalRecords(from:displayRange:)` has a
// precondition pure BurlyCore cannot enforce on its own: `points` must be
// an exercise's **all-time** history, never pre-filtered to `displayRange`
// — see that function's doc for why "which sessions count toward a PR" and
// "which sessions a chart currently shows" are two different questions.
// BurlyCore has no store to fetch from, so it cannot fail loudly when a
// caller violates that precondition; a caller that fetches only
// `displayRange`'s sets and hands them straight to `personalRecords` gets a
// value back, just a silently wrong one (a session can misreport as an
// all-time PR the instant an older, out-of-range session already beat it).
//
// This extension is the one obvious, correct path: it always fetches via
// `loggedSetSlices(exerciseID:since: nil, through: nil)` — the exercise-
// bounded, SQL-pushed-down all-time query — regardless of `displayRange`,
// so the precondition can never be violated by a caller going through it.
// `ExerciseProgressionStats.personalRecords` stays public (fixture-truth
// tests in BurlyCoreTests construct `[ExerciseSessionPoint]` by hand and
// need to call it directly, with no store in the picture at all), but any
// consumer with a real `BurlyStore` — the future chart UI m6-02 builds —
// should call this instead of re-deriving the fetch-then-compute sequence.
import Foundation
import BurlyCore

extension BurlyStore {
    /// One exercise's progression points (all-time) and personal records
    /// (filtered to `displayRange`), fetched and computed correctly in one
    /// call — see this file's header for why hand-rolling this sequence is
    /// the mistake this extension exists to make impossible.
    ///
    /// - Parameters:
    ///   - exerciseID: the exercise to chart — forwarded verbatim to
    ///     `loggedSetSlices(exerciseID:since:through:)`.
    ///   - displayRange: the chart's currently-displayed range (spec §7
    ///     #1: 3 m/6 m/1 y/all); `nil` (the default) is the "all" range's
    ///     own behavior — see `ExerciseProgressionStats.personalRecords`'s
    ///     `displayRange` doc.
    ///
    /// - Returns: `points` — every session's progression point across
    ///   **all-time** history, unfiltered, so a caller that also wants to
    ///   draw the trend line for `displayRange` can filter this itself by
    ///   `date`; `records` — personal records already filtered to
    ///   `displayRange`.
    public func exerciseProgression(
        exerciseID: UUID,
        displayRange: ClosedRange<Date>? = nil
    ) throws -> (points: [ExerciseSessionPoint], records: [PersonalRecord]) {
        let slices = try loggedSetSlices(exerciseID: exerciseID, since: nil, through: nil)
        let points = ExerciseProgressionStats.sessionPoints(from: slices)
        let records = ExerciseProgressionStats.personalRecords(from: points, displayRange: displayRange)
        return (points, records)
    }
}
