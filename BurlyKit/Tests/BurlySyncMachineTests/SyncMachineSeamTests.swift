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
//    nothing else (attribute-prefixed forms like `@_exported import` and
//    access-level forms like `public import` included — the parser is
//    itself pinned below), and the manifest's BurlySyncMachine target
//    still declares no dependencies (m4-02 review 1 caught the first
//    version of this guard checking only source text, which a
//    manifest-level edge slips past without any import statement;
//    review 2 caught `public import` slipping past the source scan).
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

        // Anchor on `.target(` plus its name so the same-named product cannot
        // satisfy this search. The declaration then runs to the next target
        // (or the manifest's end), so inserting `dependencies:` into the real
        // target necessarily makes the expectation below fail.
        let markerRange = try #require(
            manifest.range(of: ".target(\n            name: \"BurlySyncMachine\""),
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

    @Test("the import parser recognizes every legal import spelling and rejects prose")
    func importParserRecognizesAllSpellings() {
        // The guard is only as strong as this parser, so the parser is
        // pinned directly (m4-02 review 2, #4: `public import Combine`
        // slipped past a version that only tolerated `@`-attributes
        // before `import`).
        #expect(importedModule(of: "import Foundation") == "Foundation")
        #expect(importedModule(of: "  import BurlyCore") == "BurlyCore")
        #expect(importedModule(of: "@_exported import BurlyCore") == "BurlyCore")
        #expect(importedModule(of: "@testable import BurlySync") == "BurlySync")
        #expect(importedModule(of: "public import Combine") == "Combine")
        #expect(importedModule(of: "package import BurlyCore") == "BurlyCore")
        #expect(importedModule(of: "internal import Observation") == "Observation")
        #expect(importedModule(of: "fileprivate import CoreData") == "CoreData")
        #expect(importedModule(of: "private import SwiftData") == "SwiftData")
        #expect(importedModule(of: "@preconcurrency public import WatchKit") == "WatchKit")
        #expect(importedModule(of: "import struct Foundation.Date") == "Foundation")
        #expect(importedModule(of: "import class BurlyCore.SomeClass") == "BurlyCore")

        // Prose and comments that merely contain the word are not imports.
        #expect(importedModule(of: "// import BurlyCore would break the seam") == nil)
        #expect(importedModule(of: "/// never import domain types here") == nil)
        #expect(importedModule(of: "let importIndex = 3") == nil)
    }

    /// The module named by an import declaration on this line, or `nil` if
    /// the line is not one. Tolerates attribute prefixes (`@_exported
    /// import X`, `@testable import Y`, `@preconcurrency import Z`) and
    /// access-level modifiers (`public import X`, `private import Y`, …) —
    /// the latter a spelling the previous version of this guard missed
    /// (m4-02 review 2, #4): an SDK module like Combine needs no manifest
    /// dependency, so `public import Combine` passed both guards.
    private func importedModule(of line: Substring) -> String? {
        let accessModifiers: Set<Substring> = [
            "public", "package", "internal", "fileprivate", "private", "open"
        ]
        let tokens = line.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard let importIndex = tokens.firstIndex(of: "import"),
              tokens[..<importIndex].allSatisfy({ $0.hasPrefix("@") || accessModifiers.contains($0) }),
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
