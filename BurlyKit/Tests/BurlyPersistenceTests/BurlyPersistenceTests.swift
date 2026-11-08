// SPDX-License-Identifier: MIT
import Testing
@testable import BurlyPersistence

@Suite("BurlyPersistence compiles and links")
struct BurlyPersistenceTests {
    @Test("placeholder is reachable")
    func placeholderIsReachable() {
        #expect(BurlyPersistence.placeholder == "BurlyPersistence")
    }
}
