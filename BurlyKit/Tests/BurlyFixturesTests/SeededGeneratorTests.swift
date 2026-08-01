// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import BurlyFixtures

@Suite("SeededGenerator")
struct SeededGeneratorTests {
    @Test("seed 0 produces a well-mixed, non-zero first value")
    func zeroSeedIsNotDegenerate() {
        var rng = SeededGenerator(seed: 0)
        #expect(rng.next() != 0)
    }

    @Test("seed 0 and the golden-gamma constant seed produce different sequences")
    func zeroSeedDiffersFromGoldenGammaSeed() {
        var zero = SeededGenerator(seed: 0)
        var goldenGamma = SeededGenerator(seed: 0x9E37_79B9_7F4A_7C15)
        let zeroValues = (0..<5).map { _ in zero.next() }
        let goldenGammaValues = (0..<5).map { _ in goldenGamma.next() }
        #expect(zeroValues != goldenGammaValues)
    }

    @Test("same seed reproduces the same sequence")
    func determinism() {
        var a = SeededGenerator(seed: 123)
        var b = SeededGenerator(seed: 123)
        let valuesA = (0..<10).map { _ in a.next() }
        let valuesB = (0..<10).map { _ in b.next() }
        #expect(valuesA == valuesB)
    }
}
