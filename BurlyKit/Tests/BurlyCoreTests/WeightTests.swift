// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
@testable import BurlyCore

@Suite("Weight: canonical kg storage")
struct WeightTests {
    @Test("constructing from kg stores exactly that value")
    func kgConstruction() {
        let w = Weight(kg: 60)
        #expect(w.kg == 60)
    }

    @Test("constructing from pounds converts to kg immediately (45 lb plate)")
    func poundsConvertsToKg() {
        let w = Weight(pounds: 45)
        #expect(abs(w.kg - 20.411_656_65) < 0.000_001)
    }

    @Test("225 lb (a classic barbell benchmark) converts to ~102.058 kg")
    func knownConversion225() {
        let w = Weight(pounds: 225)
        #expect(abs(w.kg - 102.058_283_25) < 0.000_001)
    }

    @Test("reading back as pounds round-trips within floating point tolerance")
    func poundsRoundTrip() {
        let original = 135.0
        let w = Weight(pounds: original)
        #expect(abs(w.pounds - original) < 1e-9)
    }

    @Test("0 kg is the bodyweight convention and is representable")
    func bodyweightConvention() {
        #expect(Weight.bodyweight.kg == 0)
        #expect(Weight(kg: 0) == Weight.bodyweight)
    }

    @Test("Measurement<UnitMass> in pounds converts to IDENTICAL kg as Weight(pounds:) — both route through the exact avoirdupois constant")
    func measurementConversion() {
        // `Weight(_:Measurement<UnitMass>)` special-cases `.pounds` through
        // `Weight(pounds:)`'s exact 0.45359237 constant instead of
        // Foundation's own rounded `UnitMass` coefficient, so these two
        // pound-input paths must agree exactly, not just approximately.
        let measurement = Measurement(value: 45, unit: UnitMass.pounds)
        let fromMeasurement = Weight(measurement)
        let fromDouble = Weight(pounds: 45)
        #expect(fromMeasurement.kg == fromDouble.kg)
    }

    @Test("Measurement<UnitMass> in kilograms round-trips exactly")
    func measurementKilograms() {
        let measurement = Measurement(value: 80, unit: UnitMass.kilograms)
        #expect(Weight(measurement).kg == 80)
    }

    @Test("measurement(in:) reads back in the requested unit")
    func measurementReadback() {
        let w = Weight(kg: 100)
        let pounds = w.measurement(in: .pounds)
        #expect(abs(pounds.value - 220.462_262) < 0.001)
    }

    @Test("measurement(in:) defaults to kilograms")
    func measurementDefaultUnit() {
        let w = Weight(kg: 42.5)
        #expect(w.measurement().value == 42.5)
        #expect(w.measurement().unit == .kilograms)
    }
}
