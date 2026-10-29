// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — WeightUnit
//
// The display-unit half of spec §9's Settings "display unit (kg/lb)" row
// and acceptance §9 #2 ("stored kg values render correctly in lb
// everywhere"). Storage never changes: `Weight.kg` stays the only stored
// representation (see Weight.swift). This type is the one place the phone
// turns a canonical-kg value into display text, and display text back into
// a canonical `Weight`.
//
// The input direction is the dangerous one. A naive unit toggle that only
// relabels a text field — while its Save still does `Weight(kg: Double(text))`
// — silently stores 180 kg when a lifter in pounds mode types 180. Routing
// every parse through `parse(_:)` on the *same* unit that formatted the
// field makes the two directions symmetric by construction: the conversion
// goes through `Weight(pounds:)`'s exact avoirdupois constant, never a
// second copy of it.
//
// Rounding is display-only (Weight.swift: "it must never round-trip back
// into `kg`"). Callers that show a rounded value in an editable field must
// keep the original `Weight` when the text is untouched, rather than
// re-parsing the rounded display string.

import Foundation

public enum WeightUnit: String, CaseIterable, Sendable, Codable {
    case kilograms = "kg"
    case pounds = "lb"

    /// The short unit symbol shown after a number ("82.5 kg").
    public var symbol: String { rawValue }

    // MARK: - Conversion

    /// `weight` expressed in this unit, at full precision.
    public func displayValue(of weight: Weight) -> Double {
        switch self {
        case .kilograms: weight.kg
        case .pounds: weight.pounds
        }
    }

    /// A raw kilogram quantity that is not itself a `Weight` — an Epley
    /// estimate, a PR value, or a volume total (kg × reps) — expressed in
    /// this unit. Volume converts by the same factor because reps are
    /// unitless.
    public func displayValue(fromKilograms kilograms: Double) -> Double {
        switch self {
        case .kilograms: kilograms
        case .pounds: kilograms / Weight.kilogramsPerPound
        }
    }

    /// The canonical `Weight` for a number the user entered in this unit,
    /// or `nil` if it cannot be a physical weight (negative or not finite).
    /// Pounds convert through `Weight(pounds:)`, so this and `Weight.pounds`
    /// share one constant.
    public func weight(fromDisplayValue value: Double) -> Weight? {
        guard value.isFinite, value >= 0 else { return nil }
        switch self {
        case .kilograms: return Weight(kg: value)
        case .pounds: return Weight(pounds: value)
        }
    }

    // MARK: - Parsing

    /// Parses user-entered text as a weight in this unit, independent of
    /// the device locale.
    ///
    /// Accepts decimal digits with at most one decimal separator, either `.`
    /// or `,` — the decimal pad shows the locale's separator, so a lifter
    /// in a comma locale types `82,5` while the field's own formatted value
    /// may read `82.5`, and both must mean the same thing. Digits from any
    /// Unicode decimal numbering system count, and the Arabic decimal
    /// separator (U+066B) counts as `.`, because `formattedNumber` writes
    /// the editor's starting text in the locale's own digits (`٨٢٫٥` in
    /// Arabic regions) and Save must read back what the field showed
    /// (review finding on the settings branch).
    ///
    /// Grouping separators are deliberately not accepted, which is why
    /// `formattedNumber` never emits them. Text that could be either is
    /// rejected rather than guessed at: a second separator, or a single
    /// separator followed by exactly three digits — `1,000` is a thousand
    /// in en_US and one in de_DE, and storing the wrong one silently
    /// rewrites history. One-decimal formatted text never has that shape.
    /// Surrounding whitespace is ignored. Returns `nil` for empty,
    /// negative, ambiguous, or otherwise non-numeric text.
    public func parse(_ text: String) -> Weight? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var normalized = ""
        var separatorCount = 0
        var digitsAfterSeparator = 0
        for character in trimmed {
            if let digit = Self.decimalDigit(character) {
                normalized.append(String(digit))
                if separatorCount > 0 { digitsAfterSeparator += 1 }
                continue
            }
            switch character {
            case ".", ",", "\u{066B}":
                separatorCount += 1
                normalized.append(".")
            default:
                return nil
            }
        }
        guard separatorCount <= 1,
              !(separatorCount == 1 && digitsAfterSeparator == 3),
              normalized != ".",
              let value = Double(normalized) else {
            return nil
        }
        return weight(fromDisplayValue: value)
    }

    /// The value 0–9 of a single-scalar character from any Unicode decimal
    /// digit system (general category Nd), or `nil`. Restricting to `Nd`
    /// keeps out characters that merely have a numeric value, such as
    /// Roman numerals, circled numbers, or vulgar fractions.
    private static func decimalDigit(_ character: Character) -> Int? {
        let scalars = character.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first,
              scalar.properties.numericType == .decimal,
              let value = scalar.properties.numericValue,
              let digit = Int(exactly: value), (0...9).contains(digit) else { return nil }
        return digit
    }

    // MARK: - Formatting

    /// The number alone, to one decimal place and without grouping
    /// separators ("82.5", "198.4", "0.0"). This is also the text an
    /// editable weight field starts with, so it must stay parseable by
    /// `parse(_:)` in every locale — hence no grouping, and hence `parse`
    /// reading non-ASCII decimal digits and U+066B.
    public func formattedNumber(_ weight: Weight, locale: Locale = .autoupdatingCurrent) -> String {
        oneDecimal(displayValue(of: weight), locale: locale)
    }

    /// The number with its unit ("82.5 kg", "198.4 lb"). The 0 kg
    /// bodyweight convention renders as "0.0 kg" / "0.0 lb", exactly as the
    /// History set rows rendered it before units were configurable.
    public func formatted(_ weight: Weight, locale: Locale = .autoupdatingCurrent) -> String {
        "\(formattedNumber(weight, locale: locale)) \(symbol)"
    }

    /// A raw kilogram quantity (estimate, PR value) converted into this
    /// unit, to one decimal place with its symbol.
    public func formatted(kilograms: Double, locale: Locale = .autoupdatingCurrent) -> String {
        "\(oneDecimal(displayValue(fromKilograms: kilograms), locale: locale)) \(symbol)"
    }

    /// A session or weekly volume total (Σ kg × reps), rounded to a whole
    /// number in this unit with no grouping — the History list's existing
    /// "2400 kg" shape.
    public func formattedVolume(kilograms: Double) -> String {
        "\(Int(displayValue(fromKilograms: kilograms).rounded())) \(symbol)"
    }

    private func oneDecimal(_ value: Double, locale: Locale) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(1))
                .grouping(.never)
                .locale(locale)
        )
    }
}
