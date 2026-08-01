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

/// A seeded, deterministic random source.
///
/// Two `SeededGenerator`s constructed with the same seed and driven with the
/// same sequence of calls always produce the same sequence of values. This is
/// the property the fixture generators rely on for reproducible test data.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        // Avoid the degenerate all-zero state.
        self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
