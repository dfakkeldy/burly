// SPDX-License-Identifier: GPL-3.0-or-later
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BurlyKit",
    platforms: [
        .iOS(.v26),
        .watchOS(.v26),
        // macOS is not a shipping target. It is declared only so that
        // `swift test` on the developer's Mac has a deployment target new
        // enough for SwiftData (`@Model` requires macOS 14+); without it SPM
        // falls back to macOS 10.13 and BurlyPersistence will not compile
        // for the host. Kept level with the iOS/watchOS floor so no macOS-
        // only availability drift can creep in.
        .macOS(.v26)
    ],
    products: [
        .library(name: "BurlyCore", targets: ["BurlyCore"]),
        .library(name: "BurlyPersistence", targets: ["BurlyPersistence"]),
        .library(name: "BurlySync", targets: ["BurlySync"]),
        .library(name: "BurlySyncMachine", targets: ["BurlySyncMachine"]),
        .library(name: "BurlySyncAdapters", targets: ["BurlySyncAdapters"]),
        .library(name: "BurlyWatchSyncRuntime", targets: ["BurlyWatchSyncRuntime"]),
        .library(name: "BurlyHealth", targets: ["BurlyHealth"]),
        .library(name: "BurlyFixtures", targets: ["BurlyFixtures"]),
        .library(name: "BurlyImport", targets: ["BurlyImport"])
    ],
    targets: [
        .target(
            name: "BurlyCore",
            resources: [
                .process("Resources/catalog-seed-v1.json")
            ]
        ),
        .target(
            name: "BurlyPersistence",
            // BurlySync only for the §5 digest seam (SessionDigestReceipt /
            // SessionDigestApplying) that the watch-kind SwiftDataStore
            // conforms to — see Store/SwiftDataStore+SessionDigest.swift.
            // No transport, queueing, or sync policy crosses this edge.
            dependencies: ["BurlyCore", "BurlySync"]
        ),
        .target(
            name: "BurlySync",
            dependencies: ["BurlyCore", "BurlySyncMachine"]
        ),
        // The §5 protocol state machines (watch outbox/apply, phone
        // ingest/ack/snapshot lifecycle), generic over opaque payloads.
        // **Deliberately dependency-free** (m4-02): the empty dependency
        // list is a build-enforced seam — the machines speak UUID, Int
        // revisions, and opaque payload type parameters only, never a
        // BurlyCore domain type, so Free Lunch can lift this target
        // wholesale. Do not add a dependency edge here; the DTO binding
        // lives in BurlySync, which depends on this target, not the
        // reverse.
        .target(
            name: "BurlySyncMachine"
        ),
        // WCSession-facing transport mechanics and the watch background-task
        // completion invariant. Deliberately dependency-free: envelopes are
        // opaque Data and payload-kind inspection is injected, so this target
        // has no Burly domain or protocol-machine knowledge and can be lifted
        // into Free Lunch unchanged.
        .target(
            name: "BurlySyncAdapters"
        ),
        .target(
            name: "BurlyWatchSyncRuntime",
            dependencies: ["BurlySync", "BurlyPersistence"]
        ),
        .target(
            name: "BurlyHealth",
            dependencies: ["BurlyCore"]
        ),
        // Synthetic fixture generators (workout history, Hevy-shaped CSV)
        // for tests and previews. Shipped as its own library target (not a
        // test-support target) because BurlyPhone/BurlyWatch preview code
        // and later test targets across the package all need to depend on
        // it, and SPM test-support targets aren't importable from normal
        // targets. Depends on nothing but the Swift standard library.
        .target(
            name: "BurlyFixtures"
        ),
        // Hevy CSV import — parsing/mapping layer only (spec §8, task m7-01).
        // Depends on BurlyCore alone (domain types, CatalogSeed/alias table)
        // and CryptoKit (system framework, not a third-party dependency) for
        // the UUIDv5 derivation behind deterministic re-import identity.
        // Deliberately does not depend on BurlyPersistence: wiring imported
        // history into the store is a later M7 task, and this target's
        // public surface (parse a CSV, get back domain values plus a
        // dropped-data summary) is the seam that task builds on.
        .target(
            name: "BurlyImport",
            dependencies: ["BurlyCore"]
        ),
        .testTarget(
            name: "BurlyCoreTests",
            dependencies: ["BurlyCore"]
        ),
        .testTarget(
            name: "BurlyPersistenceTests",
            // BurlySync so the digest-seam integration test can construct a
            // SessionDigestReceipt and drive it through
            // SessionDigestApplying. BurlyFixtures — one of the "later test
            // targets" its own doc comment anticipates — so the m6-01 §7
            // stats-query benchmark can seed 50k SetRecords from
            // `WorkoutHistoryGenerator` instead of hand-rolling a second
            // synthetic-history generator.
            dependencies: ["BurlyPersistence", "BurlySync", "BurlyFixtures"]
        ),
        .testTarget(
            name: "BurlySyncTests",
            // BurlySyncMachine so the DTO-binding tests can name the
            // machine's event and command types the binding produces.
            dependencies: ["BurlySync", "BurlySyncMachine"]
        ),
        // Depends on BurlySyncMachine alone, matching the target it tests:
        // the machine rules, the fake-transport convergence scenarios, and
        // the seam guard all run without BurlyCore ever being linked.
        .testTarget(
            name: "BurlySyncMachineTests",
            dependencies: ["BurlySyncMachine"]
        ),
        .testTarget(
            name: "BurlySyncAdaptersTests",
            dependencies: ["BurlySyncAdapters"]
        ),
        .testTarget(
            name: "BurlyWatchSyncRuntimeTests",
            dependencies: ["BurlyWatchSyncRuntime", "BurlyPersistence", "BurlyCore"]
        ),
        .testTarget(
            name: "BurlyHealthTests",
            dependencies: ["BurlyHealth"]
        ),
        .testTarget(
            name: "BurlyFixturesTests",
            dependencies: ["BurlyFixtures"]
        ),
        .testTarget(
            name: "BurlyImportTests",
            // BurlyFixtures for the shared Hevy-shaped CSV generator (bodyweight,
            // warmup, malformed-row scenarios); BurlyImport is the thing under
            // test.
            dependencies: ["BurlyImport", "BurlyFixtures"]
        )
    ],
    swiftLanguageModes: [.v6]
)
