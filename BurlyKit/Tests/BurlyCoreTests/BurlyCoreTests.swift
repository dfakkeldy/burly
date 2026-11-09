// SPDX-License-Identifier: MIT
import Testing
@testable import BurlyCore

@Suite("BurlyCore compiles and links")
struct BurlyCoreTests {
    @Test("placeholder is reachable")
    func placeholderIsReachable() {
        #expect(BurlyCore.placeholder == "BurlyCore")
    }
}
