// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyFixtures
//
// Synthetic Hevy-export-shaped CSV generator, for exercising the future
// CSV-import feature (task m7) without needing real exported data.
//
// ASSUMPTION (to be corrected by m7 against a real Hevy export sample):
// Hevy's CSV export is assumed to use one row per *set* with the columns
//   title, start_time, end_time, exercise_title, set_index, set_type,
//   weight_kg, reps
// where `title` is the workout/session name, `start_time`/`end_time` are
// `YYYY-MM-DD HH:MM:SS` local-time strings shared by every row of a session,
// `exercise_title` and `set_index` (1-based, per exercise) identify the set,
// `set_type` is a Hevy set classification (this generator only emits
// "normal"), and `weight_kg`/`reps` are the logged values (0 kg for
// bodyweight-only exercises, per Burly's convention). m7 must diff this
// against a real export and correct any column name, ordering, or type
// mismatch before wiring up the real importer.
//
// Pure Swift, zero framework imports: CSV is just delimited text and does
// not require Foundation.

public enum HevyCSVGenerator {
    public static let header = "title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps"

    /// Renders `sessions` as Hevy-export-shaped CSV text, one row per set,
    /// with a header row first. Numeric fields use `.` decimal separators
    /// and integer-valued weights are rendered without a fractional part
    /// (e.g. `60`, not `60.0`) to match typical CSV export conventions.
    public static func generate(sessions: [FixtureSession]) -> String {
        var lines: [String] = [header]

        for session in sessions {
            let startText = session.start.formatted
            let endText = session.end.formatted
            for exercise in session.exercises {
                for (index, set) in exercise.sets.enumerated() {
                    let row = [
                        csvField(session.title),
                        startText,
                        endText,
                        csvField(exercise.title),
                        String(index + 1),
                        "normal",
                        formatWeight(set.weightKg),
                        String(set.reps)
                    ].joined(separator: ",")
                    lines.append(row)
                }
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func formatWeight(_ weight: Double) -> String {
        weight == weight.rounded() ? String(Int(weight)) : String(weight)
    }

    /// Quotes a field only if it contains a comma, quote, or newline, per
    /// standard CSV escaping (RFC 4180).
    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

private extension String {
    /// Minimal stand-in for `Foundation`'s `replacingOccurrences`, kept
    /// local (character-by-character scan) so this module has no framework
    /// imports and no minimum-OS requirement beyond the base language.
    func replacingOccurrences(of target: String, with replacement: String) -> String {
        guard !target.isEmpty else { return self }
        let targetChars = Array(target)
        let selfChars = Array(self)
        var result = ""
        result.reserveCapacity(selfChars.count)
        var i = 0
        while i < selfChars.count {
            if i + targetChars.count <= selfChars.count,
               Array(selfChars[i..<(i + targetChars.count)]) == targetChars {
                result += replacement
                i += targetChars.count
            } else {
                result.append(selfChars[i])
                i += 1
            }
        }
        return result
    }
}
