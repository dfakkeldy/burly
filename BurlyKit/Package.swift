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
        .library(name: "BurlyHealth", targets: ["BurlyHealth"])
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
        )
    ],
    swiftLanguageModes: [.v6]
)
