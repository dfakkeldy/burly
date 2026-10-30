// SPDX-License-Identifier: GPL-3.0-or-later
// Schema 2: the phone's display unit and global rest default ride every
// snapshot, read from the host app when the snapshot is built.
import Foundation
import Testing
import BurlyCore
import BurlyPersistence
import BurlySync
@testable import BurlyPhoneSync

@MainActor
@Suite("Snapshot carries the phone's watch-facing settings")
struct WatchSettingsSnapshotTests {
    @Test("the builder copies the settings and clamps the rest default onto the §3 grid")
    func builderCopiesSettings() throws {
        let store = try makePhoneStore()
        let snapshot = try SnapshotPayloadBuilder.build(
            version: 1,
            from: store,
            settings: PhoneWatchSettings(displayUnit: .pounds, restDefault: 100)
        )
        #expect(snapshot.displayUnit == .pounds)
        #expect(snapshot.restDefault == 105)
    }

    @Test("each push reads the settings at build time, so a change reaches the next snapshot")
    func pushReadsCurrentSettings() async throws {
        let store = try makePhoneStore()
        let transport = FakeTransport()
        let current = SettingsBox(PhoneWatchSettings(displayUnit: .kilograms, restDefault: 90))
        let coordinator = PhoneSyncCoordinator(
            store: store,
            transport: transport,
            digestPublisher: FakeDigestPublisher(),
            statePersisting: InMemoryPhoneSyncStatePersisting(),
            clock: TestClock(),
            scheduler: ManualTriggerScheduler(),
            watchSettings: { current.value }
        )

        try await coordinator.applicationDidLaunch()
        current.value = PhoneWatchSettings(displayUnit: .pounds, restDefault: 180)
        try await coordinator.applicationDidLaunch()

        let payloads = await transport.transmissions.map(\.payload)
        #expect(payloads.map(\.displayUnit) == [.kilograms, .pounds])
        #expect(payloads.map(\.restDefault) == [90, 180])
    }

    @Test("a phone snapshot applied on the watch persists both settings")
    func phoneToWatchSettingsEndToEnd() throws {
        let phone = try makePhoneStore()
        let snapshot = try SnapshotPayloadBuilder.build(
            version: 2,
            from: phone,
            settings: PhoneWatchSettings(displayUnit: .pounds, restDefault: 45)
        )
        let encoded = try BurlySyncEnvelope(payload: .snapshot(snapshot)).encodedData()
        guard case let .decoded(envelope) = BurlySyncEnvelope.decode(encoded),
              case let .snapshot(received) = envelope.payload
        else {
            Issue.record("snapshot did not survive the wire")
            return
        }

        let watch = try SwiftDataStore(kind: .watch, at: .inMemory)
        #expect(try watch.replaceWatchWorkingSet(received))
        #expect(try watch.watchSyncState().displayUnit == .pounds)
        #expect(try watch.watchSyncState().restDefault == 45)
    }
}

/// The host app's preferences, as the coordinator's settings closure sees them.
@MainActor
private final class SettingsBox {
    var value: PhoneWatchSettings

    init(_ value: PhoneWatchSettings) {
        self.value = value
    }
}
