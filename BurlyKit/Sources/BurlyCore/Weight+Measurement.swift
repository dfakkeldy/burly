// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — Weight + Foundation Measurement
//
// Spec §1 acceptance #4 requires the weight-construction API to "accept
// Measurement<UnitMass>, stores converted kg." That is the one place in
// BurlyCore that earns a Foundation import: `Measurement`/`UnitMass` are
// Foundation types, and confining them to this file keeps every other
// BurlyCore file — including Weight.swift itself — free of any framework
// import, so the bulk of the module still compiles and tests as pure
// Swift in milliseconds (architecture doc: "Zero framework imports → tests
// run on macOS in ms").
//
// Tradeoff, stated plainly: this is a deliberate, narrow Foundation
// dependency, taken only because the spec names `Measurement<UnitMass>`
// explicitly as an accepted input shape. Nothing it does is otherwise
// necessary — `Weight(pounds:)` in Weight.swift already covers the same
// conversion with no framework at all. Isolating it here means "does
// BurlyCore import Foundation" has exactly one honest answer: this file,
// for this reason.
import Foundation

extension Weight {
    /// Constructs from a `Measurement<UnitMass>` of any unit, converting to
    /// kg immediately (spec §1 acceptance #4).
    public init(_ measurement: Measurement<UnitMass>) {
        self.init(kg: measurement.converted(to: .kilograms).value)
    }

    /// Reads back as a `Measurement<UnitMass>`, in kilograms by default.
    public func measurement(in unit: UnitMass = .kilograms) -> Measurement<UnitMass> {
        Measurement(value: kg, unit: .kilograms).converted(to: unit)
    }
}
