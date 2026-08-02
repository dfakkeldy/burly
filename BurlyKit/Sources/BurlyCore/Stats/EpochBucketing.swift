// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — EpochBucketing
//
// Shared day/week bucketing for §7's volume and consistency charts.
//
// Bucket boundaries are anchored to the Unix epoch (1970-01-01T00:00:00Z),
// not the user's local calendar. A `Foundation.Calendar`-based "start of
// week" is timezone- and locale-dependent (and DST-sensitive right at the
// day boundary), which would make the same fixture disagree with itself
// depending on which timezone it runs in — poison for a fixture-truth test
// suite that hand-computes an expected number once and expects it to hold
// on every machine, including CI. Spec §7 says "weekly" and does not say
// "calendar week" or "Monday-start week" — this is task m6-01's
// interpretation of that gap; see the task handoff for the call.
//
// `Date`/`TimeInterval` are absolute instants (elapsed seconds since the
// epoch), so this arithmetic is exact and portable regardless of where it
// runs — no `Calendar`, no `TimeZone`, nothing environment-dependent.
import Foundation

enum EpochBucketing {
    static let dayLength: TimeInterval = 24 * 60 * 60
    static let weekLength: TimeInterval = 7 * dayLength

    /// The `Date` at the start of the epoch-aligned bucket (of `length`
    /// seconds) that `date` falls in — always `<= date`, and always an
    /// exact multiple of `length` seconds since the epoch.
    static func bucketStart(for date: Date, length: TimeInterval) -> Date {
        let index = (date.timeIntervalSince1970 / length).rounded(.down)
        return Date(timeIntervalSince1970: index * length)
    }
}
