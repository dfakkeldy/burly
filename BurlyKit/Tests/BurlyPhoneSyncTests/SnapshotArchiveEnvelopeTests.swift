// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import BurlyCore
import BurlyPersistence
import BurlyPhoneSync
import BurlySync

/// A phone archive reaches the watch picker only if `archivedAt` survives
/// the wire. `SnapshotPayloadBuilderTests` hands the built DTO straight to
/// the watch store; this sends it the way the hosts do: encoded into a
/// `BurlySyncEnvelope` (`PhoneSyncHost`), then decoded at the trust
/// boundary (`WatchSyncHost`) before the watch applies it.
@Suite("Archived exercises through the snapshot envelope")
struct SnapshotArchiveEnvelopeTests {
    @Test("an exercise archived on the phone keeps its archivedAt through envelope encode and decode, and leaves the watch picker")
    @MainActor
    func archiveSurvivesEnvelopeRoundTrip() throws {
        let phone = try SwiftDataStore(kind: .phone, at: .inMemory)
        let watch = try SwiftDataStore(kind: .watch, at: .inMemory)
        let kept = ExerciseData(name: "Kept", muscleGroups: [.chest], origin: .curated)
        let archived = ExerciseData(name: "Old Custom", muscleGroups: [.biceps], origin: .custom)
        try phone.createExercise(kept)
        try phone.createExercise(archived)

        #expect(try watch.replaceWatchWorkingSet(try deliver(SnapshotPayloadBuilder.build(version: 1, from: phone))))
        #expect(Set(try watch.exercises(includingArchived: false).map(\.id)) == [kept.id, archived.id])

        // A fractional date, so a lossy date encoding would show.
        let archivedAt = Date(timeIntervalSince1970: 1_800_000_000.25)
        try phone.archiveExercise(id: archived.id, at: archivedAt)
        let delivered = try deliver(SnapshotPayloadBuilder.build(version: 2, from: phone))

        #expect(delivered.exercises.first(where: { $0.id == archived.id })?.archivedAt == archivedAt)
        #expect(delivered.exercises.first(where: { $0.id == kept.id })?.archivedAt == nil)
        #expect(try watch.replaceWatchWorkingSet(delivered))
        #expect(try watch.exercises(includingArchived: false).map(\.id) == [kept.id])
        #expect(try watch.exercise(id: archived.id)?.archivedAt == archivedAt)
    }

    /// Encodes `snapshot` as the phone host sends it and decodes it as the
    /// watch host receives it.
    private func deliver(_ snapshot: BurlySnapshotPayloadDTO) throws -> BurlySnapshotPayloadDTO {
        let data = try BurlySyncEnvelope(payload: .snapshot(snapshot)).encodedData()
        guard case .decoded(let envelope) = BurlySyncEnvelope.decode(data),
              case .snapshot(let payload) = envelope.payload else {
            Issue.record("Expected a decoded snapshot envelope")
            throw EnvelopeNotDecoded()
        }
        return payload
    }

    private struct EnvelopeNotDecoded: Error {}
}
