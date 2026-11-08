// SPDX-License-Identifier: MIT
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
// Units: Hevy writes weight and distance in the unit the account is set to,
// and names the column for it — `weight_kg`/`distance_km` for metric
// accounts, `weight_lbs`/`distance_miles` for imperial ones (corroborated by
// two independent third-party Hevy importers; not Hevy documentation, and
// still to be confirmed against Dan's own export, m7-03). Exactly one weight
// column must be present; its unit decides how the value is converted to
// Burly's kilograms. Distance is only ever tested for "is it positive"
// (cardio detection), so either distance column works and no conversion is
// needed.
//
// Imports BurlyCore for `Weight`, and Foundation for
// `String.trimmingCharacters(in:)`.
import BurlyCore
import Foundation

/// Which weight column a Hevy export carries, i.e. which unit its weights
/// are written in.
enum HevyWeightUnit: Equatable {
    case kilograms
    case pounds

    /// The header column holding weights in this unit.
    var columnName: String {
        switch self {
        case .kilograms: return HevyCSVSchema.weightKilogramsColumn
        case .pounds: return HevyCSVSchema.weightPoundsColumn
        }
    }

    /// Converts a value read from this unit's column to a `Weight`, or
    /// `nil` if `Weight` rejects the result (negative, NaN, infinite).
    /// Pounds are multiplied by `Weight.kilogramsPerPound` at full
    /// precision — the same arithmetic as `Weight(pounds:)` — so a value
    /// like 225 lb lands on the exact kilogram figure the rest of Burly
    /// would compute for it.
    func weight(from value: Double) -> Weight? {
        switch self {
        case .kilograms: return try? Weight(validatingKg: value)
        case .pounds: return try? Weight(validatingKg: value * Weight.kilogramsPerPound)
        }
    }
}

enum HevyCSVSchema {
    static let weightKilogramsColumn = "weight_kg"
    static let weightPoundsColumn = "weight_lbs"
    static let distanceKilometersColumn = "distance_km"
    static let distanceMilesColumn = "distance_miles"

    /// How a missing weight column is named in
    /// `HevyImportError.unrecognizedHeader(missingColumns:)`: either unit's
    /// column satisfies the requirement. Worded as one item, so it still
    /// reads as one in a comma-separated list of missing columns.
    static let weightColumnRequirement = "\(weightKilogramsColumn) (or \(weightPoundsColumn))"

    /// Columns without which a row cannot be turned into anything at all,
    /// besides the weight column (see `weightColumnRequirement`): exactly
    /// one of `weight_kg`/`weight_lbs` is also required.
    static let requiredColumns = [
        "title", "start_time", "end_time", "exercise_title", "set_type", "reps"
    ]

    /// Optional columns this importer deliberately reads or explicitly
    /// accounts for by name, beyond the required set above. `set_index` is
    /// deliberately not used for set *ordering* — see `HevyCSVImporter`'s
    /// doc comment on why row order is trusted instead, since a real
    /// export's numbering scheme is unverified (m7-03) — but its presence
    /// is still read here so a nonempty value is visibly reported as
    /// discarded (finding 4.4) rather than silently ignored.
    static let knownOptionalColumns = [
        "description", "superset_id", "exercise_notes", "duration_seconds", "rpe", "set_index"
    ]

    /// The unit-dependent columns: one of the weight columns is required,
    /// and the distance columns are optional. Both pairs are recognized so
    /// neither unit's column is ever counted as an unknown column.
    static let unitColumns = [
        weightKilogramsColumn, weightPoundsColumn, distanceKilometersColumn, distanceMilesColumn
    ]

    /// Every column name this importer recognizes at all, required or
    /// optional. Any header column NOT in this set is "unknown" to Burly's
    /// schema (finding 4.3): a nonempty value in such a column is counted
    /// as dropped rather than silently ignored, without aborting the
    /// import.
    static let knownColumns = Set(requiredColumns + knownOptionalColumns + unitColumns)
}

/// Resolves a parsed header row into named column indices, built once per
/// import and reused for every data row.
struct HevyCSVHeader {
    private let columnIndex: [String: Int]
    /// How many header columns are a weight column (`weight_kg` or
    /// `weight_lbs`), counting repeats. More than one means Burly can't
    /// tell which column holds the real weights — the lookup below would
    /// silently read the first and ignore the rest.
    private let weightColumnCount: Int
    let columnCount: Int
    /// EVERY header column's index (not deduplicated by name) whose
    /// trimmed/lowercased name isn't recognized by
    /// `HevyCSVSchema.knownColumns` — finding 4.3, and the round-2 fix for
    /// duplicate unknown column names undercounting their dropped values
    /// (see doc below).
    let unknownColumnIndices: [Int]

    /// A header name is matched case-insensitively and trimmed — Hevy's
    /// own header casing is not something Burly controls any more than an
    /// exercise title's casing is (spec §8's case-insensitivity mandate
    /// applies to the whole file, not just exercise names). A duplicate
    /// KNOWN column name (a header oddity, not expected in practice)
    /// resolves to its first occurrence for `value(_:in:)` lookups rather
    /// than being treated as fatal — `columnIndex` intentionally keeps
    /// only the first index per name for that reason. The weight column is
    /// the exception: any repeat of it is refused (see
    /// `hasAmbiguousWeightColumns`), because a blank first copy would
    /// import a loaded set as bodyweight.
    ///
    /// `unknownColumnIndices` deliberately does NOT dedupe by name the
    /// same way: two duplicate UNKNOWN columns (e.g. a header with `tempo`
    /// twice) can each carry their own nonempty value in a given row, and
    /// m7-01 review round 2 found that counting drops by deduplicated NAME
    /// silently discarded every occurrence after the first. Every unknown
    /// column's own index is tracked independently so each one's value (if
    /// present) is counted.
    init(fields: [String]) {
        columnCount = fields.count
        var map: [String: Int] = [:]
        var unknownIndices: [Int] = []
        var weightColumns = 0
        for (index, raw) in fields.enumerated() {
            let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { continue }
            if key == HevyCSVSchema.weightKilogramsColumn || key == HevyCSVSchema.weightPoundsColumn {
                weightColumns += 1
            }
            if map[key] == nil {
                map[key] = index
            }
            if !HevyCSVSchema.knownColumns.contains(key) {
                unknownIndices.append(index)
            }
        }
        columnIndex = map
        weightColumnCount = weightColumns
        unknownColumnIndices = unknownIndices
    }

    /// Which unit the file's weights are in, or `nil` unless exactly one
    /// of `weight_kg`/`weight_lbs` is present: a file with neither has no
    /// weights to read, and a file with both is ambiguous (see
    /// `hasAmbiguousWeightColumns`).
    var weightUnit: HevyWeightUnit? {
        let kilograms = columnIndex[HevyCSVSchema.weightKilogramsColumn] != nil
        let pounds = columnIndex[HevyCSVSchema.weightPoundsColumn] != nil
        switch (kilograms, pounds) {
        case (true, false): return .kilograms
        case (false, true): return .pounds
        default: return nil
        }
    }

    /// More than one weight column is present: both units, or one unit's
    /// column repeated. Burly can't tell which column the values should
    /// come from, and guessing would silently import every weight 2.2x too
    /// heavy or too light (or a loaded set as bodyweight, if the first
    /// repeat is blank), so the import is refused. Real Hevy exports carry
    /// exactly one.
    var hasAmbiguousWeightColumns: Bool {
        weightColumnCount > 1
    }

    /// Required columns the header lacks. A file with neither weight
    /// column reports them as one entry, `weight_kg (or weight_lbs)`,
    /// placed just before `reps` (their order in a real export). A file
    /// with no header at all reports the same list as an empty header.
    var missingRequiredColumns: [String] {
        var missing = HevyCSVSchema.requiredColumns.filter { columnIndex[$0] == nil }
        if columnIndex[HevyCSVSchema.weightKilogramsColumn] == nil, columnIndex[HevyCSVSchema.weightPoundsColumn] == nil {
            missing.insert(HevyCSVSchema.weightColumnRequirement, at: missing.firstIndex(of: "reps") ?? missing.endIndex)
        }
        return missing
    }

    /// The trimmed value of `column` in `fields`, or `nil` if the column
    /// isn't present in this file's header, is out of range for this
    /// specific row (a wrong-column-count row the caller will reject on
    /// other grounds), or is present but empty. Callers can't distinguish
    /// "column missing" from "column present but blank" through this
    /// method — for every column BurlyImport reads, those two cases are
    /// handled identically (the weight column: both mean bodyweight; the optional
    /// metadata columns: both mean "nothing to drop-and-count").
    func value(_ column: String, in fields: [String]) -> String? {
        guard let index = columnIndex[column], index < fields.count else { return nil }
        let raw = fields[index].trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? nil : raw
    }

    /// The trimmed value at a raw column `index` (as opposed to `value`'s
    /// lookup-by-name), or `nil` if the index is out of range for this row
    /// or the value is empty. Used for `unknownColumnIndices`, which are
    /// tracked per raw index rather than per (possibly duplicated) name —
    /// see the "duplicate unknown columns" doc on `unknownColumnIndices`.
    func value(atIndex index: Int, in fields: [String]) -> String? {
        guard index < fields.count else { return nil }
        let raw = fields[index].trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? nil : raw
    }
}
