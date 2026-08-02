// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyImport — DeterministicUUID
//
// UUIDv5 derivation (RFC 4122 §4.3, name-based, SHA-1) for every identifier
// this module invents from CSV content: session, session-item, set, and
// custom-exercise IDs. Deriving from content instead of calling `UUID()` is
// the entire mechanism behind spec §8's "re-importing the same file, or an
// overlapping newer export, upserts instead of duplicating": the same
// input bytes always hash to the same UUID, so parsing the same export
// twice — or two overlapping exports that share some of the same
// workouts — produces identical IDs for the parts that are actually the
// same underlying data.
//
// Uses CryptoKit for SHA-1: a system framework (not a third-party
// dependency) available across the iOS 26 / watchOS 26 / macOS 26 floor
// this package already targets. `Insecure.SHA1` is CryptoKit's own name for
// the algorithm — the "insecure" label is about SHA-1's unsuitability for
// cryptographic signing, not about UUIDv5, which uses SHA-1 by definition
// and has no security requirement here: these are stable identifiers, not
// secrets.
import CryptoKit
import Foundation

enum DeterministicUUID {
    /// Namespace UUID for everything this module derives. Generated once
    /// (`uuidgen`) and fixed forever — regenerating it would silently
    /// change every derived ID, breaking the re-import-produces-identical-
    /// IDs guarantee for every previously imported file. Never reuse this
    /// value for anything outside Hevy-import ID derivation, and never
    /// change it.
    private static let namespace = UUID(uuidString: "BEFDD1C9-A7A5-40C0-85D1-801A18BC7564")!

    /// RFC 4122 §4.3 UUIDv5: SHA-1(namespace bytes ++ name UTF-8 bytes),
    /// then the version nibble (byte 6 high bits) forced to 0101 and the
    /// variant bits (byte 8 high bits) forced to 10 per the spec. The same
    /// `name` always yields the same UUID; different `name`s are
    /// astronomically unlikely to collide (SHA-1 collision resistance).
    ///
    /// `name` is expected to already be namespaced by call site (see
    /// `HevyCSVImporter`'s "session\u{1}...", "exercise\u{1}...", etc.
    /// prefixes) so that, say, a session and a set can never hash to the
    /// same input by coincidence of their raw field values lining up.
    static func v5(name: String) -> UUID {
        var bytes = [UInt8]()
        bytes.reserveCapacity(16 + name.utf8.count)
        withUnsafeBytes(of: namespace.uuid) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: Array(name.utf8))

        var digest = Array(Insecure.SHA1.hash(data: Data(bytes)))
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80

        let uuidBytes: uuid_t = (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        )
        return UUID(uuid: uuidBytes)
    }
}
