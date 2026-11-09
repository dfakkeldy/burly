// SPDX-License-Identifier: MIT
import Testing
@testable import BurlySync

@Suite("BurlySync compiles and links")
struct BurlySyncTests {
    @Test("placeholder is reachable")
    func placeholderIsReachable() {
        #expect(BurlySync.placeholder == "BurlySync")
    }
}
