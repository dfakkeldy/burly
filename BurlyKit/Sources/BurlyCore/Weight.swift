// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyCore — Weight
//
// Canonical-kg unit handling (spec §1 acceptance #4). `weightKg: Double` on
// SetRecordData and SetSnapshot is the *only* stored representation of a
// lifted weight anywhere in Burly — on both devices, in every payload that
// crosses the sync wire (§5), and in every fixture. Pounds exist only as a
// display-layer conversion, computed on the way out, never stored.
//
// `Weight` is the single construction point for that field: both
// SetRecordData and SetSnapshot take a `Weight` in their initializer, not a
// raw `Double` — there is no call site anywhere in the app that can hand a
// pounds figure to a kg-typed field by mistake. Converting is mandatory,
// not a discipline someone has to remember.
//
// Zero is a valid, meaningful value: `Weight.bodyweight` (0 kg) is the
// project-wide convention for a bodyweight set (empty/0 weight column on
// Hevy import, §8; bodyweight exercises logged from the watch, §1). It is
// not an error case and callers must not special-case it away.
//
// No Foundation import: converting between kg and lb is arithmetic on a
// documented constant, nothing a framework is needed for. The one
// Foundation-touching extra — accepting `Measurement<UnitMass>` per spec
// §1 acceptance #4 — lives in Weight+Measurement.swift instead, so this
// file (and everything that only needs plain kg/lb) stays framework-free.
public struct Weight: Sendable, Equatable, Hashable, Codable {
    /// The only stored value. Always kilograms.
    public let kg: Double

    /// Constructs directly from a kilogram value — the canonical path.
    public init(kg: Double) {
        self.kg = kg
    }

    /// Constructs from pounds, converting to kg immediately using the
    /// exact international avoirdupois pound (1 lb = 0.45359237 kg). The
    /// conversion happens once, here, at construction — never deferred,
    /// and never re-derived from a rounded display value.
    public init(pounds: Double) {
        self.kg = pounds * Self.kilogramsPerPound
    }

    /// Display-layer conversion, computed fresh on every read at full
    /// precision. Rounding for display (e.g. to the nearest 0.5 lb, per
    /// the watch's configurable increment in §2) is the UI layer's job —
    /// it must never round-trip back into `kg`.
    public var pounds: Double {
        kg / Self.kilogramsPerPound
    }

    /// Exact international avoirdupois pound-to-kilogram factor. `Double`
    /// literal precision is more than sufficient at gym-weight magnitudes.
    public static let kilogramsPerPound: Double = 0.453_592_37

    /// The 0 kg bodyweight convention (see file doc above).
    public static let bodyweight = Weight(kg: 0)
}

/// Thrown by `Weight(validatingKg:)` when a raw `Double` cannot represent a
/// physical weight. Every trusted construction path (`init(kg:)`,
/// `init(pounds:)`, the `Measurement<UnitMass>` initializer) already hands
/// this type values that satisfy these invariants by construction — this
/// error only exists for the one boundary where `weightKg` arrives as an
/// untrusted raw `Double` instead: Decodable. See `SetRecordData` and
/// `SetSnapshot`'s custom `init(from:)` for where this becomes a
/// `DecodingError.dataCorrupted`.
public enum WeightValidationError: Error, Equatable {
    case negative(Double)
    case notFinite(Double)
}

extension Weight {
    /// Validates a raw kg value against the invariants `Weight` otherwise
    /// holds implicitly (finite, non-negative), for use at boundaries where
    /// `weightKg` is decoded as a plain `Double` rather than constructed
    /// through this type directly.
    public init(validatingKg kg: Double) throws {
        guard kg.isFinite else {
            throw WeightValidationError.notFinite(kg)
        }
        guard kg >= 0 else {
            throw WeightValidationError.negative(kg)
        }
        self.init(kg: kg)
    }
}
