// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
@testable import BurlyCore

/// Spec §9 acceptance #2: stored kg values render correctly in lb, and —
/// the half a render-only check misses — text entered in lb is stored as
/// the equivalent kg, never as the same number of kg.
@Suite("WeightUnit: display formatting and parsing over canonical kg")
struct WeightUnitTests {
    private let posix = Locale(identifier: "en_US_POSIX")
    private let german = Locale(identifier: "de_DE")

    // MARK: Formatting

    @Test("kg formats to one decimal place with its symbol")
    func kilogramsFormatting() {
        #expect(WeightUnit.kilograms.formatted(Weight(kg: 82.5), locale: posix) == "82.5 kg")
        #expect(WeightUnit.kilograms.formatted(Weight(kg: 90), locale: posix) == "90.0 kg")
    }

    @Test("lb converts the stored kg before formatting (90 kg → 198.4 lb, 100 kg → 220.5 lb)")
    func poundsFormatting() {
        #expect(WeightUnit.pounds.formatted(Weight(kg: 90), locale: posix) == "198.4 lb")
        #expect(WeightUnit.pounds.formatted(Weight(kg: 100), locale: posix) == "220.5 lb")
        #expect(WeightUnit.pounds.formatted(Weight(pounds: 45), locale: posix) == "45.0 lb")
    }

    @Test("0 kg bodyweight renders as 0.0 in both units, the same as before units were configurable")
    func bodyweightFormatting() {
        #expect(WeightUnit.kilograms.formatted(.bodyweight, locale: posix) == "0.0 kg")
        #expect(WeightUnit.pounds.formatted(.bodyweight, locale: posix) == "0.0 lb")
    }

    @Test("formatted numbers never carry grouping separators, so an editor's initial text stays parseable")
    func noGrouping() {
        #expect(WeightUnit.kilograms.formattedNumber(Weight(kg: 1_234.5), locale: posix) == "1234.5")
        #expect(WeightUnit.pounds.formattedNumber(Weight(pounds: 1_500), locale: posix) == "1500.0")
    }

    @Test("formatting follows the supplied locale's decimal separator")
    func localeAwareFormatting() {
        #expect(WeightUnit.kilograms.formattedNumber(Weight(kg: 82.5), locale: german) == "82,5")
    }

    @Test("raw kg quantities (estimates, PR values) convert like weights")
    func rawKilogramFormatting() {
        // 90 kg × 8 reps by Epley = 114 kg = 251.327… lb.
        #expect(WeightUnit.pounds.formatted(kilograms: 114, locale: posix) == "251.3 lb")
        #expect(WeightUnit.kilograms.formatted(kilograms: 114, locale: posix) == "114.0 kg")
    }

    @Test("volume rounds to a whole number in the display unit with no grouping")
    func volumeFormatting() {
        #expect(WeightUnit.kilograms.formattedVolume(kilograms: 2_400) == "2400 kg")
        // 2400 / 0.45359237 = 5291.09…
        #expect(WeightUnit.pounds.formattedVolume(kilograms: 2_400) == "5291 lb")
        #expect(WeightUnit.pounds.formattedVolume(kilograms: 0) == "0 lb")
    }

    @Test("display values are full precision; rounding is only in the formatted text")
    func displayValuePrecision() {
        let weight = Weight(kg: 90)
        #expect(WeightUnit.kilograms.displayValue(of: weight) == 90)
        #expect(WeightUnit.pounds.displayValue(of: weight) == weight.pounds)
        #expect(WeightUnit.pounds.displayValue(fromKilograms: 90) == weight.pounds)
    }

    // MARK: Parsing — the input path

    @Test("typing 180 in lb stores 81.6466… kg, never 180 kg")
    func poundsInputStoresConvertedKilograms() throws {
        let stored = try #require(WeightUnit.pounds.parse("180"))
        #expect(stored == Weight(pounds: 180))
        #expect(abs(stored.kg - 81.646_626_6) < 0.000_001)
        #expect(stored.kg != 180)
    }

    @Test("typing in kg stores exactly that kg")
    func kilogramInput() {
        #expect(WeightUnit.kilograms.parse("82.5") == Weight(kg: 82.5))
    }

    @Test("\"82.5\" parses identically whatever the device locale, and \"82,5\" means the same")
    func localeIndependentParsing() {
        #expect(WeightUnit.kilograms.parse("82.5") == Weight(kg: 82.5))
        #expect(WeightUnit.kilograms.parse("82,5") == Weight(kg: 82.5))
        #expect(WeightUnit.pounds.parse("82,5") == WeightUnit.pounds.parse("82.5"))
    }

    @Test("surrounding whitespace and leading/trailing separators are tolerated")
    func lenientShapes() {
        #expect(WeightUnit.kilograms.parse("  60 ") == Weight(kg: 60))
        #expect(WeightUnit.kilograms.parse(".5") == Weight(kg: 0.5))
        #expect(WeightUnit.kilograms.parse("5.") == Weight(kg: 5))
    }

    @Test("0 parses to the bodyweight convention, not an error")
    func zeroParsesToBodyweight() {
        #expect(WeightUnit.kilograms.parse("0") == .bodyweight)
        #expect(WeightUnit.pounds.parse("0") == .bodyweight)
    }

    @Test(
        "non-weights are rejected rather than guessed at",
        arguments: [
            "", "   ", ".", "-5", "abc", "1,000.5", "1.2.3", "12kg", "1e3", "inf", "nan",
            // A thousand in en_US, one in de_DE: refuse rather than guess.
            "1,000", "1.000", "2,500",
            // Characters with a numeric value that are not decimal digits.
            "Ⅻ", "½", "②",
        ]
    )
    func rejectsNonWeights(text: String) {
        #expect(WeightUnit.kilograms.parse(text) == nil)
        #expect(WeightUnit.pounds.parse(text) == nil)
    }

    @Test("weight(fromDisplayValue:) rejects values that cannot be a physical weight")
    func displayValueValidation() {
        #expect(WeightUnit.pounds.weight(fromDisplayValue: -1) == nil)
        #expect(WeightUnit.pounds.weight(fromDisplayValue: .infinity) == nil)
        #expect(WeightUnit.pounds.weight(fromDisplayValue: .nan) == nil)
        #expect(WeightUnit.pounds.weight(fromDisplayValue: 45) == Weight(pounds: 45))
    }

    // MARK: Round-trips

    @Test(
        "formatting then parsing in the same unit lands within half a display step",
        arguments: WeightUnit.allCases, [0.0, 20, 61.25, 82.5, 90, 102.058_283_25, 250]
    )
    func formatParseRoundTrip(unit: WeightUnit, kilograms: Double) throws {
        let original = Weight(kg: kilograms)
        let reparsed = try #require(unit.parse(unit.formattedNumber(original, locale: posix)))
        // One displayed decimal place: the rounding error is at most 0.05
        // display units.
        #expect(abs(unit.displayValue(of: reparsed) - unit.displayValue(of: original)) <= 0.05 + 1e-9)
    }

    @Test("a comma-locale round-trip parses too (the editor's initial text in de_DE)")
    func commaLocaleRoundTrip() throws {
        let original = Weight(kg: 82.5)
        let text = WeightUnit.kilograms.formattedNumber(original, locale: german)
        #expect(try #require(WeightUnit.kilograms.parse(text)) == original)
    }

    @Test(
        "the editor's starting text round-trips in non-Latin digit locales",
        arguments: ["ar_SA@numbers=arab", "ar_EG@numbers=arab", "fa_IR@numbers=arabext"]
    )
    func nonLatinDigitRoundTrip(identifier: String) throws {
        let locale = Locale(identifier: identifier)
        let original = Weight(kg: 82.5)
        let text = WeightUnit.kilograms.formattedNumber(original, locale: locale)
        // Guard against the test passing trivially if the formatter ever
        // falls back to Latin digits for this locale.
        #expect(text.unicodeScalars.contains { !$0.isASCII }, "Expected non-Latin digits, got \(text)")
        #expect(try #require(WeightUnit.kilograms.parse(text)) == original)
    }

    @Test("Arabic-Indic and Persian digits parse like ASCII ones")
    func nonLatinDigitParsing() {
        #expect(WeightUnit.kilograms.parse("٨٢٫٥") == Weight(kg: 82.5))
        #expect(WeightUnit.kilograms.parse("۸۲٫۵") == Weight(kg: 82.5))
        #expect(WeightUnit.pounds.parse("١٨٠") == WeightUnit.pounds.parse("180"))
    }

    @Test("entering a value in lb and displaying it in lb returns the entered value exactly")
    func poundsEntryDisplayRoundTrip() throws {
        let stored = try #require(WeightUnit.pounds.parse("180"))
        #expect(WeightUnit.pounds.formatted(stored, locale: posix) == "180.0 lb")
        #expect(WeightUnit.kilograms.formatted(stored, locale: posix) == "81.6 kg")
    }

    @Test("raw values are the stable storage strings the phone persists")
    func rawValues() {
        #expect(WeightUnit(rawValue: "kg") == .kilograms)
        #expect(WeightUnit(rawValue: "lb") == .pounds)
        #expect(WeightUnit.kilograms.symbol == "kg")
        #expect(WeightUnit.pounds.symbol == "lb")
    }
}
