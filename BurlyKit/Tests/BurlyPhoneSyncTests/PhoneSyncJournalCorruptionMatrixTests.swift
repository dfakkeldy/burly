// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import BurlySync
import BurlySyncMachine
@testable import BurlyPhoneSync

@MainActor
@Suite("m4-08 — phone-sync journal corruption matrix")
struct PhoneSyncJournalCorruptionMatrixTests {
    private func makeTemporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "burly-phone-sync-journal-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "state.jsonl", directoryHint: .notDirectory)
    }

    @Test("an absent journal is a clean first launch")
    func absentJournalIsFirstLaunch() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try FileBackedPhoneSyncStatePersisting(url: url).load() == nil)
    }

    @Test("a clean journal loads its newest state without a recovery flag")
    func cleanJournalLoadsNewestState() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let expected = PhoneSyncRuntimeState(
            machineState: .init(latestSnapshotVersion: 3, lastTransferGeneration: 4),
            lastDailyPushAt: Date(timeIntervalSince1970: 123)
        )
        let persisting = FileBackedPhoneSyncStatePersisting(url: url)
        try persisting.save(expected)

        let loaded = try #require(try persisting.load())
        #expect(loaded.runtimeState == expected)
        #expect(loaded.recoveredFromCorruption == false)
    }

    @Test("a present journal with zero valid lines is unrecoverable")
    func presentZeroValidLineJournalIsUnrecoverable() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a journal record\n{also broken".utf8).write(to: url)

        #expect(throws: PhoneSyncStateUnrecoverableError()) {
            _ = try FileBackedPhoneSyncStatePersisting(url: url).load()
        }
    }

    @Test("an empty but present journal is unrecoverable, not first launch")
    func emptyPresentJournalIsUnrecoverable() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))

        #expect(throws: PhoneSyncStateUnrecoverableError()) {
            _ = try FileBackedPhoneSyncStatePersisting(url: url).load()
        }
    }

    @Test("a torn trailing line loads the newest complete checksum-valid state")
    func tornTrailingLineLoadsNewestValidState() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sessionID = UUID()
        let expected = PhoneSyncRuntimeState(
            machineState: BurlyPhoneSyncMachine.State(
                ackAge: [sessionID: 42],
                latestSnapshotVersion: 7,
                lastTransferGeneration: 11
            ),
            lastDailyPushAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let persisting = FileBackedPhoneSyncStatePersisting(url: url)
        try persisting.save(expected)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"seq":2,"fullRuntimeState":broken"#.utf8))
        try handle.close()

        let loaded = try #require(try persisting.load())
        #expect(loaded.runtimeState == expected)
        #expect(loaded.recoveredFromCorruption)
    }

    @Test("a historical invalid line does not mark a later clean load as recovered")
    func historicalInvalidLineDoesNotRemainSticky() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let persisting = FileBackedPhoneSyncStatePersisting(url: url)
        try persisting.save(.init(machineState: .init(
            latestSnapshotVersion: 1, lastTransferGeneration: 1
        )))
        var journal = try Data(contentsOf: url)
        journal.append(Data("invalid historical line\n".utf8))
        journal.append(try JSONEncoder().encode(FileBackedPhoneSyncStatePersisting.Record(
            seq: 2,
            runtimeState: .init(machineState: .init(
                latestSnapshotVersion: 2, lastTransferGeneration: 2
            ))
        )))
        journal.append(UInt8(ascii: "\n"))
        try journal.write(to: url)

        let loaded = try #require(try persisting.load())
        #expect(loaded.runtimeState.machineState.latestSnapshotVersion == 2)
        #expect(loaded.runtimeState.machineState.lastTransferGeneration == 2)
        #expect(loaded.recoveredFromCorruption == false)
    }

    @Test("a checksum-corrupt newest line falls back to the newest valid full state without losing valid identity maxima")
    func corruptNewestLinePreservesValidMaxima() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let firstID = UUID()
        let secondID = UUID()
        let newestID = UUID()
        let persisting = FileBackedPhoneSyncStatePersisting(url: url)
        try persisting.save(.init(machineState: .init(
            ackAge: [firstID: 1], latestSnapshotVersion: 9, lastTransferGeneration: 1
        )))
        try persisting.save(.init(machineState: .init(
            ackAge: [secondID: 2], latestSnapshotVersion: 2, lastTransferGeneration: 8
        )))
        try persisting.save(.init(machineState: .init(
            ackAge: [newestID: 3], latestSnapshotVersion: 3, lastTransferGeneration: 4
        )))

        let journalData = try Data(contentsOf: url)
        var lines = journalData.split(separator: UInt8(ascii: "\n")).map { Data($0) }
        var newest = try JSONDecoder().decode(FileBackedPhoneSyncStatePersisting.Record.self, from: lines.removeLast())
        newest.checksum = String(repeating: "0", count: 16)
        lines.append(try JSONEncoder().encode(newest))
        let corrupted = lines.reduce(into: Data()) { data, line in
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        try corrupted.write(to: url)

        let loaded = try #require(try persisting.load())
        #expect(loaded.runtimeState.machineState.ackAge == [secondID: 2])
        #expect(loaded.runtimeState.machineState.latestSnapshotVersion == 9)
        #expect(loaded.runtimeState.machineState.lastTransferGeneration == 8)
        #expect(loaded.recoveredFromCorruption)
    }

    @Test("a checksum-valid Int.max record is skipped and cannot win either identity maximum")
    func intMaxRecordIsSkippedNotRestored() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let persisting = FileBackedPhoneSyncStatePersisting(url: url)
        try persisting.save(.init(machineState: .init(
            latestSnapshotVersion: 7, lastTransferGeneration: 8
        )))
        let hostile = try JSONEncoder().encode(FileBackedPhoneSyncStatePersisting.Record(
            seq: 1,
            runtimeState: .init(machineState: .init(
                latestSnapshotVersion: Int.max, lastTransferGeneration: Int.max
            ))
        ))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: hostile)
        try handle.write(contentsOf: Data([UInt8(ascii: "\n")]))
        try handle.close()

        let loaded = try #require(try persisting.load())
        #expect(loaded.runtimeState.machineState.latestSnapshotVersion == 7)
        #expect(loaded.runtimeState.machineState.lastTransferGeneration == 8)
        #expect(loaded.recoveredFromCorruption)
    }

    @Test("compaction replaces the journal with one full-state line and preserves both maxima")
    func compactionPreservesBothMaxima() throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let persisting = FileBackedPhoneSyncStatePersisting(url: url)
        try persisting.save(.init(machineState: .init(
            latestSnapshotVersion: 50, lastTransferGeneration: 1
        )))
        try persisting.save(.init(machineState: .init(
            latestSnapshotVersion: 2, lastTransferGeneration: 60
        )))
        for index in 2...200 {
            try persisting.save(.init(
                machineState: .init(latestSnapshotVersion: 3, lastTransferGeneration: 4),
                lastDailyPushAt: Date(timeIntervalSince1970: TimeInterval(index))
            ))
        }

        let bytes = try Data(contentsOf: url)
        #expect(bytes.count(where: { $0 == UInt8(ascii: "\n") }) == 1)
        let loaded = try #require(try persisting.load())
        #expect(loaded.runtimeState.lastDailyPushAt == Date(timeIntervalSince1970: 200))
        #expect(loaded.runtimeState.machineState.latestSnapshotVersion == 50)
        #expect(loaded.runtimeState.machineState.lastTransferGeneration == 60)
    }

    @Test("legacy two-file state migrates once into the journal and removes both old files")
    func legacyTwoFileStateMigratesOnce() throws {
        let journalURL = makeTemporaryURL()
        let directory = journalURL.deletingLastPathComponent()
        let legacyStateURL = directory.appending(path: "state.json", directoryHint: .notDirectory)
        let legacyHighWaterURL = directory.appending(path: "state.highwater.jsonl", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sessionID = UUID()
        let legacyRuntime = PhoneSyncRuntimeState(
            machineState: .init(
                ackAge: [sessionID: 12], latestSnapshotVersion: 5, lastTransferGeneration: 6
            ),
            lastDailyPushAt: Date(timeIntervalSince1970: 456)
        )
        try JSONEncoder().encode(FileBackedPhoneSyncStatePersisting.Snapshot(legacyRuntime)).write(to: legacyStateURL)
        try Data(
            "{\"version\":9,\"generation\":4}\n{\"version\":3,\"generation\":11}\n".utf8
        ).write(to: legacyHighWaterURL)

        let migrating = FileBackedPhoneSyncStatePersisting(
            url: journalURL,
            legacyStateURL: legacyStateURL,
            legacyHighWaterURL: legacyHighWaterURL
        )
        let loaded = try #require(try migrating.load())
        #expect(loaded.runtimeState.machineState.ackAge == [sessionID: 12])
        #expect(loaded.runtimeState.machineState.latestSnapshotVersion == 9)
        #expect(loaded.runtimeState.machineState.lastTransferGeneration == 11)
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
        #expect(FileManager.default.fileExists(atPath: legacyStateURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: legacyHighWaterURL.path) == false)

        let relaunched = try #require(try FileBackedPhoneSyncStatePersisting(url: journalURL).load())
        #expect(relaunched.runtimeState == loaded.runtimeState)
    }
}
