// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import BurlyImport

@Suite("DeterministicUUID")
struct DeterministicUUIDTests {
    @Test("the same name always produces the same UUID")
    func sameNameSameUUID() {
        #expect(DeterministicUUID.v5(name: "session\u{1}Push Day\u{1}2025-06-15 08:00:00")
            == DeterministicUUID.v5(name: "session\u{1}Push Day\u{1}2025-06-15 08:00:00"))
    }

    @Test("different names produce different UUIDs")
    func differentNamesDifferentUUIDs() {
        let a = DeterministicUUID.v5(name: "session\u{1}Push Day\u{1}2025-06-15 08:00:00")
        let b = DeterministicUUID.v5(name: "session\u{1}Pull Day\u{1}2025-06-15 08:00:00")
        #expect(a != b)
    }

    @Test("a name that only differs by kind prefix still produces a different UUID (no cross-kind collision)")
    func kindPrefixDisambiguates() {
        let asSession = DeterministicUUID.v5(name: "session\u{1}X")
        let asExercise = DeterministicUUID.v5(name: "exercise\u{1}X")
        #expect(asSession != asExercise)
    }

    @Test("derived UUIDs carry version 5 and RFC 4122 variant bits")
    func versionAndVariantBits() {
        let uuid = DeterministicUUID.v5(name: "anything")
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        #expect((bytes[6] & 0xF0) == 0x50) // version 5
        #expect((bytes[8] & 0xC0) == 0x80) // RFC 4122 variant
    }
}
