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
        .library(name: "BurlyHealth", targets: ["BurlyHealth"]),
        .library(name: "BurlyFixtures", targets: ["BurlyFixtures"])
    ],
    targets: [
        .target(
            name: "BurlyCore"
        ),
        .target(
            name: "BurlyPersistence",
            // BurlySync only for the ack seam (SessionAckReceipt /
            // SessionAckApplying) that the watch-kind SwiftDataStore
            // conforms to — see Store/SwiftDataStore+SessionAck.swift.
            // No transport, queueing, or sync policy crosses this edge.
            dependencies: ["BurlyCore", "BurlySync"]
        ),
        .target(
            name: "BurlySync",
            dependencies: ["BurlyCore"]
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
        .testTarget(
            name: "BurlyCoreTests",
            dependencies: ["BurlyCore"]
        ),
        .testTarget(
            name: "BurlyPersistenceTests",
            // BurlySync so the ack-seam integration test can construct a
            // SessionAckReceipt and drive it through SessionAckApplying.
            dependencies: ["BurlyPersistence", "BurlySync"]
        ),
        .testTarget(
            name: "BurlySyncTests",
            dependencies: ["BurlySync"]
        ),
        .testTarget(
            name: "BurlyHealthTests",
            dependencies: ["BurlyHealth"]
        ),
        .testTarget(
            name: "BurlyFixturesTests",
            dependencies: ["BurlyFixtures"]
        )
    ],
    swiftLanguageModes: [.v6]
)
