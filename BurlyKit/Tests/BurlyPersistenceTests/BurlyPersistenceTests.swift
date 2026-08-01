// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import BurlyPersistence

@Suite("BurlyPersistence compiles and links")
struct BurlyPersistenceTests {
    @Test("placeholder is reachable")
    func placeholderIsReachable() {
        #expect(BurlyPersistence.placeholder == "BurlyPersistence")
    }
}
