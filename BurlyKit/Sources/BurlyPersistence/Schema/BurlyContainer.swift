// SPDX-License-Identifier: GPL-3.0-or-later
// Container factories — the only public way to obtain a Burly ModelContainer.
//
// Both device configurations are built through `BurlyMigrationPlan`
// (§1 acceptance #5). They share one `BurlySchemaV1`; what differs is the
// store file and the content policy each device applies on top of it
// (§1 store shape: the phone keeps full history, the watch keeps a working
// set and prunes acked sessions — §5).

import Foundation
import SwiftData

/// Which device's store to open. Distinct store files so a phone store can
/// never be mistaken for a watch store (they diverge in *content*, and the
/// watch's pruning would silently destroy history if pointed at the wrong one).
public enum BurlyStoreKind: String, Sendable, CaseIterable {
    case phone
    case watch

    /// Configuration name and default store filename stem.
    public var storeName: String {
        switch self {
        case .phone: "Burly-phone"
        case .watch: "Burly-watch"
        }
    }
}

/// Where the store lives.
public enum BurlyStoreLocation: Sendable {
    /// Application Support/Burly/<storeName>.store — the shipping location.
    case applicationDefault
    /// An explicit file URL (used by tests that need a cold reload of the
    /// *same* store, and by any future export/import tooling).
    case file(URL)
    /// No file at all. Tests only.
    case inMemory
}

public enum BurlyContainerError: Error, Equatable {
    /// Application Support was unavailable or the Burly subdirectory could
    /// not be created.
    case defaultStoreDirectoryUnavailable
}

public enum BurlyContainer {
    /// Phone container: full history (§1 store shape).
    public static func phone(
        at location: BurlyStoreLocation = .applicationDefault
    ) throws -> ModelContainer {
        try make(.phone, at: location)
    }

    /// Watch container: working set only — catalog, routines, sessions that
    /// are `.active` or awaiting a sync ack, and the last-performance
    /// digests (§1 store shape). The entity set is the same; the watch's
    /// sync layer is what keeps it small.
    public static func watch(
        at location: BurlyStoreLocation = .applicationDefault
    ) throws -> ModelContainer {
        try make(.watch, at: location)
    }

    public static func make(
        _ kind: BurlyStoreKind,
        at location: BurlyStoreLocation = .applicationDefault
    ) throws -> ModelContainer {
        let schema = Schema(versionedSchema: BurlySchemaV1.self)
        let configuration: ModelConfiguration

        switch location {
        case .inMemory:
            configuration = ModelConfiguration(
                kind.storeName,
                schema: schema,
                isStoredInMemoryOnly: true
            )
        case .file(let url):
            configuration = ModelConfiguration(kind.storeName, schema: schema, url: url)
        case .applicationDefault:
            let url = try defaultStoreURL(for: kind)
            try createDirectory(for: url)
            configuration = ModelConfiguration(kind.storeName, schema: schema, url: url)
        }

        // Always through the plan — never `ModelContainer(for:)` alone.
        return try ModelContainer(
            for: schema,
            migrationPlan: BurlyMigrationPlan.self,
            configurations: configuration
        )
    }

    /// Pure: computes the path, touches nothing on disk. `make` creates the
    /// directory only when it is actually about to open that store.
    static func defaultStoreURL(for kind: BurlyStoreKind) throws -> URL {
        guard
            let support = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        else {
            throw BurlyContainerError.defaultStoreDirectoryUnavailable
        }

        return support
            .appending(path: "Burly", directoryHint: .isDirectory)
            .appending(path: "\(kind.storeName).store", directoryHint: .notDirectory)
    }

    private static func createDirectory(for storeURL: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw BurlyContainerError.defaultStoreDirectoryUnavailable
        }
    }
}
