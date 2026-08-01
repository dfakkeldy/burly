// SPDX-License-Identifier: GPL-3.0-or-later
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BurlyKit",
    platforms: [
        .iOS(.v26),
        .watchOS(.v26)
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
            dependencies: ["BurlyCore"]
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
            dependencies: ["BurlyPersistence"]
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
