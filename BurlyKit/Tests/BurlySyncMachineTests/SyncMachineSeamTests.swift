// SPDX-License-Identifier: GPL-3.0-or-later
// The m4-02 seam criterion, guarded twice over:
//
// 1. **Build assertion (primary).** The BurlySyncMachine target declares no
//    dependencies in Package.swift, so `import BurlyCore` in any machine
//    source cannot compile at all — and this whole test target depends on
//    BurlySyncMachine alone, so these tests run without BurlyCore linked.
// 2. **Policy guard (this file).** The build assertion silently disappears
//    if someone adds the dependency edge back, so this test checks both
//    halves of the seam: every machine source imports Foundation and
//    nothing else (any spelling, including attribute-prefixed forms like
//    `@_exported import`), and the manifest's BurlySyncMachine target
//    still declares no dependencies (m4-02 review 1 caught the first
//    version of this guard checking only source text, which a
//    manifest-level edge slips past without any import statement).
import Foundation
import Testing

@Suite("m4-02 seam — the machine module knows no Burly type")
struct SyncMachineSeamTests {
    /// `<worktree>/BurlyKit`, resolved from this file's own location so
    /// the guard survives checkout moves.
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BurlySyncMachineTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // BurlyKit
    }

    @Test("every machine source imports Foundation and nothing else")
    func machineSourcesImportOnlyFoundation() throws {
        let sourcesDirectory = packageRoot
            .appendingPathComponent("Sources/BurlySyncMachine", isDirectory: true)

        let sources = try FileManager.default
            .contentsOfDirectory(at: sourcesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // If the directory moved, fail loudly rather than vacuously pass.
        try #require(!sources.isEmpty, "No machine sources found at \(sourcesDirectory.path)")

        for file in sources {
            let importedModules = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n")
                .compactMap(importedModule)

            #expect(
                Set(importedModules).isSubset(of: ["Foundation"]),
                """
                \(file.lastPathComponent) imports \(importedModules) — the sync \
                machines speak UUID/Int/opaque payloads only, so Free Lunch \
                can lift the module wholesale. Bind domain types in \
                BurlySync's adapter layer instead.
                """
            )
        }
    }

    @Test("the manifest's BurlySyncMachine target declares no dependencies")
    func manifestTargetIsDependencyFree() throws {
        let manifest = try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        // The target declaration runs from its `name:` to the next target
        // declaration (or the manifest's end). Textual, but the shape is
        // ours to keep simple; if the declaration is not found at all,
        // fail loudly rather than vacuously pass.
        let markerRange = try #require(
            manifest.range(of: "name: \"BurlySyncMachine\""),
            "Package.swift no longer declares a BurlySyncMachine target"
        )
        let tail = manifest[markerRange.upperBound...]
        let nextDeclaration = [".target(", ".testTarget("]
            .compactMap { tail.range(of: $0)?.lowerBound }
            .min()
        let declaration = nextDeclaration.map { tail[..<$0] } ?? tail

        #expect(
            !declaration.contains("dependencies"),
            """
            The BurlySyncMachine target grew a dependencies list. Its empty \
            dependency list is the build-enforced seam (see Package.swift's \
            comment); linking BurlyCore through the manifest defeats it \
            even with no import statement in the sources.
            """
        )
    }

    /// The module named by an import declaration on this line, or `nil` if
    /// the line is not one. Tolerates attribute prefixes (`@_exported
    /// import X`, `@testable import Y`) — spellings the first version of
    /// this guard missed.
    private func importedModule(of line: Substring) -> String? {
        let tokens = line.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard let importIndex = tokens.firstIndex(of: "import"),
              tokens[..<importIndex].allSatisfy({ $0.hasPrefix("@") }),
              importIndex + 1 < tokens.count
        else { return nil }
        // `import struct Foundation.Date` spells the module second.
        let next = String(tokens[importIndex + 1])
        let kinds = ["struct", "class", "enum", "protocol", "typealias", "func", "let", "var"]
        let moduleToken = kinds.contains(next) && importIndex + 2 < tokens.count
            ? String(tokens[importIndex + 2])
            : next
        return moduleToken.split(separator: ".").first.map(String.init)
    }
}
