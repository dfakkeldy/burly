// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
@testable import BurlyCore

/// Hostile-JSON and default-symmetry coverage for the custom `init(from:)`
/// implementations added on top of Swift's synthesized `Decodable` (m1-01
/// review): closing the `weightKg` validation hole on `SetRecordData` and
/// `SetSnapshot`, and applying §1's documented defaults when a field is
/// absent from the payload rather than only when it's absent from a Swift
/// call site.
@Suite("Domain Decodable hardening: weight validation and §1 default symmetry")
struct DomainDecodingTests {
    // MARK: - Closing the Decodable weight hole (SetRecordData, SetSnapshot)

    @Test("SetRecordData rejects a negative weightKg at decode time")
    func setRecordRejectsNegativeWeight() {
        let json = """
        {"id":"\(UUID().uuidString)","order":0,"weightKg":-1,"reps":5,"isWarmup":false,"completedAt":700000000}
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SetRecordData.self, from: json)
        }
    }

    @Test("SetRecordData rejects a weightKg literal that cannot be represented as a finite Double (1e400 style)")
    func setRecordRejectsUnrepresentableWeight() {
        let json = """
        {"id":"\(UUID().uuidString)","order":0,"weightKg":1e400,"reps":5,"isWarmup":false,"completedAt":700000000}
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SetRecordData.self, from: json)
        }
    }

    @Test("SetSnapshot rejects a negative weightKg at decode time")
    func setSnapshotRejectsNegativeWeight() {
        let json = """
        {"weightKg":-1,"reps":5,"isWarmup":false}
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SetSnapshot.self, from: json)
        }
    }

    @Test("SetSnapshot rejects a weightKg literal that cannot be represented as a finite Double (1e400 style)")
    func setSnapshotRejectsUnrepresentableWeight() {
        let json = """
        {"weightKg":1e400,"reps":5,"isWarmup":false}
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SetSnapshot.self, from: json)
        }
    }

    @Test("SetRecordData still decodes a valid, non-negative finite weightKg")
    func setRecordAcceptsValidWeight() throws {
        let json = """
        {"id":"\(UUID().uuidString)","order":0,"weightKg":102.058,"reps":5,"isWarmup":false,"completedAt":700000000}
        """.data(using: .utf8)!
        let value = try JSONDecoder().decode(SetRecordData.self, from: json)
        #expect(value.weightKg == 102.058)
    }

    // MARK: - §1 default symmetry: decodeIfPresent + default on the owning types

    @Test("RoutineData decodes items as [] when absent from the payload")
    func routineDataDecodesMissingItemsAsEmpty() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Push Day","orderIndex":0,"updatedAt":700000000}
        """.data(using: .utf8)!
        let value = try JSONDecoder().decode(RoutineData.self, from: json)
        #expect(value.items.isEmpty)
    }

    @Test("RoutineItemData decodes defaultSetCount as 3 when absent from the payload")
    func routineItemDataDecodesMissingDefaultSetCountAsThree() throws {
        let json = """
        {"id":"\(UUID().uuidString)","order":0}
        """.data(using: .utf8)!
        let value = try JSONDecoder().decode(RoutineItemData.self, from: json)
        #expect(value.defaultSetCount == 3)
    }

    @Test("SessionData decodes items/revision/state to their §1 defaults when absent from the payload")
    func sessionDataDecodesMissingFieldsToDefaults() throws {
        let json = """
        {"id":"\(UUID().uuidString)","startedAt":700000000,"origin":"live"}
        """.data(using: .utf8)!
        let value = try JSONDecoder().decode(SessionData.self, from: json)
        #expect(value.items.isEmpty)
        #expect(value.revision == 1)
        #expect(value.state == .active)
    }

    @Test("SessionItemData decodes sets as [] when absent from the payload")
    func sessionItemDataDecodesMissingSetsAsEmpty() throws {
        let json = """
        {"id":"\(UUID().uuidString)","order":0}
        """.data(using: .utf8)!
        let value = try JSONDecoder().decode(SessionItemData.self, from: json)
        #expect(value.sets.isEmpty)
    }

    @Test("SetRecordData decodes isWarmup as false when absent from the payload")
    func setRecordDataDecodesMissingIsWarmupAsFalse() throws {
        let json = """
        {"id":"\(UUID().uuidString)","order":0,"weightKg":60,"reps":8,"completedAt":700000000}
        """.data(using: .utf8)!
        let value = try JSONDecoder().decode(SetRecordData.self, from: json)
        #expect(value.isWarmup == false)
    }

    @Test("SetSnapshot decodes isWarmup as false when absent from the payload")
    func setSnapshotDecodesMissingIsWarmupAsFalse() throws {
        let json = """
        {"weightKg":60,"reps":8}
        """.data(using: .utf8)!
        let value = try JSONDecoder().decode(SetSnapshot.self, from: json)
        #expect(value.isWarmup == false)
    }
}
