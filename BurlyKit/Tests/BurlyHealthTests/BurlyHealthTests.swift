// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import BurlyHealth

@Suite("BurlyHealth compiles and links")
struct BurlyHealthTests {
    @Test("placeholder is reachable")
    func placeholderIsReachable() {
        #expect(BurlyHealth.placeholder == "BurlyHealth")
    }
}
