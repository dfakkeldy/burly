// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyImport — HevyCSVSchema
//
// Header-driven column resolution instead of fixed column positions. Real
// Hevy exports carry more columns (description, superset_id, exercise_notes,
// distance_km, duration_seconds, rpe) than `BurlyFixtures.HevyCSVGenerator`'s
// minimal 8-column shape does; resolving columns by name lets one parser
// handle both without caring which optional columns are present, in what
// order, or whether extras Burly doesn't know about are mixed in. Only the
// columns Burly actually needs to build a set are "required" — everything
// else is opportunistic.
//
// Imports Foundation only for `String.trimmingCharacters(in:)`.
import Foundation

enum HevyCSVSchema {
    /// Columns without which a row cannot be turned into anything at all.
    /// `set_index` is deliberately not required (or even consulted for
    /// ordering — see `HevyCSVImporter`): a real export's numbering scheme
    /// is unverified (m7-03), so set order is taken from row order in the
    /// file instead of trusting this column's value.
    static let requiredColumns = [
        "title", "start_time", "end_time", "exercise_title", "set_type", "weight_kg", "reps"
    ]
}

/// Resolves a parsed header row into named column indices, built once per
/// import and reused for every data row.
struct HevyCSVHeader {
    private let columnIndex: [String: Int]
    let columnCount: Int

    /// A header name is matched case-insensitively and trimmed — Hevy's
    /// own header casing is not something Burly controls any more than an
    /// exercise title's casing is (spec §8's case-insensitivity mandate
    /// applies to the whole file, not just exercise names). A duplicate
    /// column name (a header oddity, not expected in practice) resolves to
    /// its first occurrence rather than being treated as fatal.
    init(fields: [String]) {
        columnCount = fields.count
        var map: [String: Int] = [:]
        for (index, raw) in fields.enumerated() {
            let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, map[key] == nil else { continue }
            map[key] = index
        }
        columnIndex = map
    }

    var missingRequiredColumns: [String] {
        HevyCSVSchema.requiredColumns.filter { columnIndex[$0] == nil }
    }

    /// The trimmed value of `column` in `fields`, or `nil` if the column
    /// isn't present in this file's header, is out of range for this
    /// specific row (a wrong-column-count row the caller will reject on
    /// other grounds), or is present but empty. Callers can't distinguish
    /// "column missing" from "column present but blank" through this
    /// method — for every column BurlyImport reads, those two cases are
    /// handled identically (weight_kg: both mean bodyweight; the optional
    /// metadata columns: both mean "nothing to drop-and-count").
    func value(_ column: String, in fields: [String]) -> String? {
        guard let index = columnIndex[column], index < fields.count else { return nil }
        let raw = fields[index].trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? nil : raw
    }
}
