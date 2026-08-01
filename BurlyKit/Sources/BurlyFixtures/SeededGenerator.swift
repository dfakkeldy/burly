// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyFixtures
//
// Deterministic pseudo-random number generator used by every fixture
// generator in this module. Pure Swift: `RandomNumberGenerator` is part of
// the standard library, not a framework, so this file needs no imports.
//
// Algorithm: SplitMix64 (Vigna, 2015 public-domain construction). It is not
// cryptographically secure and is not intended to be — fixtures only need
// "looks plausible" data that is 100% reproducible given the same seed.
//
// DECISION: seed 0 is used as-is, with no remap. Earlier revisions remapped
// seed 0 to the golden-gamma constant (0x9E3779B97F4A7C15) to "avoid the
// degenerate all-zero state" — but SplitMix64 has no such degenerate state:
// every `next()` call adds the golden-gamma constant to `state` *before*
// mixing, so even a raw zero state produces a well-mixed, non-zero first
// output. Worse, that remap made seed 0 and seed 0x9E3779B97F4A7C15
// *indistinguishable* (identical state, identical output stream), which is
// a correctness bug for callers who might legitimately pick either value.
// `SeededGeneratorTests` asserts both that seed 0 is non-degenerate and that
// it differs from the golden-gamma seed.

/// A seeded, deterministic random source.
///
/// Two `SeededGenerator`s constructed with the same seed and driven with the
/// same sequence of calls always produce the same sequence of values. This is
/// the property the fixture generators rely on for reproducible test data.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
