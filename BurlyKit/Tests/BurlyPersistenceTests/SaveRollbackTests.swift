// SPDX-License-Identifier: GPL-3.0-or-later
// m1-06 review round E — a failed save must not leave pending changes
// behind for someone else's save to commit.
//
// Preflight (finding M1) makes a *rejected* call leave nothing behind: it
// throws before the first insert. This is the other half. A save can fail
// after the mutations are staged — the volume is gone, the file is
// unwritable, the disk is full — and with autosave off and one long-lived
// `ModelContext` per store, the staged rows stay pending afterwards. The
// next successful `save()`, from an unrelated method, commits them. That is
// worse than the preflight case: the caller has already been told the
// operation failed, and the change lands anyway, minutes later, attributed
// to nothing.
//
// `SwiftDataStore.commit()` is the single `save()` every mutating method
// routes through, and it calls `rollback()` before rethrowing.
//
// ## How the failure is induced
//
// By moving the store's directory out from under an open container. The
// method under test is `archiveExercise`, chosen deliberately: its fetch
// resolves an object the context registered moments earlier and can serve
// without touching the file, so the mutation (`archivedAt = date`) really
// is staged before the save is attempted. Then the directory is moved back
// and the same store keeps working, which is what makes the leak
// observable — a permanently broken store could not commit anything later
// and the test would pass vacuously.
//
// The failure genuinely lands on the save rather than on the fetch —
// SwiftData logs `DefaultStore save failed … Code=134030` while this suite
// runs, which is the induced error being reported, not a problem with the
// test. **Expect CoreData error logging in this suite's output; it is the
// point.**
//
// This was checked against its own inverse while it was written: with
// `context.rollback()` removed from `commit()`, the final assertion reads
// back the archived date instead of `nil`. It is a real guard, not a
// tautology.

import Foundation
import SwiftData
import Testing
import BurlyCore
@testable import BurlyPersistence

@Suite("m1-06 round E — a failed save rolls back")
struct SaveRollbackTests {

    /// Runs `body` with the store's directory moved aside, then restores it.
    /// The store stays usable afterwards; only writes attempted inside the
    /// closure fail.
    private func withStoreFileUnreachable(
        at url: URL,
        _ body: () throws -> Void
    ) throws {
        let directory = url.deletingLastPathComponent()
        let aside = directory.deletingLastPathComponent()
            .appending(path: directory.lastPathComponent + "-aside", directoryHint: .isDirectory)

        try FileManager.default.moveItem(at: directory, to: aside)
        defer {
            // SwiftData may have recreated an empty directory at the
            // original path while the real one was away; the restore has to
            // win, so clear the path first.
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.moveItem(at: aside, to: directory)
        }
        try body()
    }

    @Test("a mutation whose save fails is discarded, not left pending for the next successful save to commit")
    func failedSaveDoesNotLeakIntoTheNextSuccessfulOne() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let store = try SwiftDataStore(kind: .phone, at: .file(url), clock: TestClock())
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)
        #expect(try store.exercise(id: bench.id)?.archivedAt == nil)

        let archivedAt = Fixture.epoch.addingTimeInterval(3_600)
        try withStoreFileUnreachable(at: url) {
            // Staged, then unsaveable. The caller is told it failed.
            #expect(throws: (any Error).self) {
                try store.archiveExercise(id: bench.id, at: archivedAt)
            }
        }

        // An unrelated, successful call on the same store — the moment a
        // still-pending `archivedAt` would be committed under cover of
        // someone else's transaction.
        let row = Fixture.exercise(name: "Row", muscleGroups: [.upperBack])
        try store.createExercise(row)

        // The archive did not happen. It was reported as failed and it is
        // absent — the two agree.
        #expect(try store.exercise(id: bench.id)?.archivedAt == nil)
        #expect(try store.exercises(includingArchived: false).map(\.name) == ["Bench Press", "Row"])
    }

    @Test("the discard is durable: a cold reopen agrees the failed mutation never landed")
    func failedSaveIsAbsentAfterAColdReopen() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let bench = Fixture.exercise(name: "Bench Press")
        let archivedAt = Fixture.epoch.addingTimeInterval(3_600)

        do {
            let store = try SwiftDataStore(kind: .phone, at: .file(url), clock: TestClock())
            try store.createExercise(bench)

            try withStoreFileUnreachable(at: url) {
                #expect(throws: (any Error).self) {
                    try store.archiveExercise(id: bench.id, at: archivedAt)
                }
            }

            try store.createExercise(Fixture.exercise(name: "Row", muscleGroups: [.upperBack]))
        }

        let reopened = try SwiftDataStore(kind: .phone, at: .file(url))
        #expect(try reopened.exercise(id: bench.id)?.archivedAt == nil)
        #expect(try reopened.exercises(includingArchived: true).count == 2)
    }

    @Test("the store is still usable after a failed save — rollback recovers the context rather than poisoning it")
    func storeKeepsWorkingAfterAFailedSave() throws {
        let url = try makeTemporaryStoreURL()
        defer { removeStoreFiles(at: url) }

        let store = try SwiftDataStore(kind: .phone, at: .file(url), clock: TestClock())
        let bench = Fixture.exercise(name: "Bench Press")
        try store.createExercise(bench)

        try withStoreFileUnreachable(at: url) {
            #expect(throws: (any Error).self) {
                try store.archiveExercise(id: bench.id, at: Fixture.epoch.addingTimeInterval(60))
            }
        }

        // Retrying the very operation that failed now succeeds and commits
        // properly: `rollback()` returns the context to its last-saved
        // state, it does not detach it.
        let archivedAt = Fixture.epoch.addingTimeInterval(7_200)
        try store.archiveExercise(id: bench.id, at: archivedAt)
        #expect(try store.exercise(id: bench.id)?.archivedAt == archivedAt)

        let reopened = try SwiftDataStore(kind: .phone, at: .file(url))
        #expect(try reopened.exercise(id: bench.id)?.archivedAt == archivedAt)
    }
}
