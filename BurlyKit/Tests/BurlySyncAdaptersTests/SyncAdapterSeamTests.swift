// SPDX-License-Identifier: GPL-3.0-or-later
// The m4-03 seam is guarded at build and policy levels: the target has no
// dependencies, its sources import only Apple transport/Foundation modules,
// and every value crossing the caller-supplied actor boundary is Sendable.

import Foundation
import Testing
@testable import BurlySyncAdapters

@Suite("m4-03 seam — app-agnostic and isolation-explicit")
struct SyncAdapterSeamTests {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("adapter event and command values are Sendable")
    func sendableSurface() {
        requireSendable(WCSessionChannel.self)
        requireSendable(WCSessionTransferMetadata.self)
        requireSendable(WCSessionAdapterEvent.self)
        requireSendable(WatchWCSessionCommand.self)
        requireSendable(PhoneWCSessionCommand.self)
        requireSendable(WCBackgroundTaskCompletionState<ObjectIdentifier>.self)
    }

    @Test("every adapter source imports only Foundation and Apple connectivity frameworks")
    func importsStayAppAgnostic() throws {
        let sourceDirectory = packageRoot
            .appendingPathComponent("Sources/BurlySyncAdapters", isDirectory: true)
        let sources = try FileManager.default
            .contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        try #require(!sources.isEmpty)
        let allowed = Set(["Foundation", "WatchConnectivity", "WatchKit"])
        for file in sources {
            let imports = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n")
                .compactMap(importedModule)
            #expect(
                Set(imports).isSubset(of: allowed),
                "\(file.lastPathComponent) imports \(imports); no Burly module may cross this seam"
            )
        }
    }

    @Test("manifest keeps the adapter target dependency-free")
    func manifestHasNoDependencies() throws {
        let manifest = try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        // Match the target declaration, not the product of the same name.
        // Picking the first bare name occurrence would make this test inspect
        // BurlyCore's declaration and pass vacuously.
        let marker = try #require(manifest.range(
            of: ".target(\n            name: \"BurlySyncAdapters\""
        ))
        let tail = manifest[marker.upperBound...]
        let nextDeclaration = [".target(", ".testTarget("]
            .compactMap { tail.range(of: $0)?.lowerBound }
            .min()
        let declaration = nextDeclaration.map { tail[..<$0] } ?? tail

        #expect(!declaration.contains("dependencies"))
    }

    @Test("import parser recognizes every legal spelling and rejects prose")
    func importParserSpellings() {
        #expect(importedModule(of: "import Foundation") == "Foundation")
        #expect(importedModule(of: "  import BurlyCore") == "BurlyCore")
        #expect(importedModule(of: "@_exported import BurlyCore") == "BurlyCore")
        #expect(importedModule(of: "@testable import BurlySync") == "BurlySync")
        #expect(importedModule(of: "@preconcurrency import WatchKit") == "WatchKit")
        #expect(importedModule(of: "public import BurlyCore") == "BurlyCore")
        #expect(importedModule(of: "package import BurlySync") == "BurlySync")
        #expect(importedModule(of: "internal import Observation") == "Observation")
        #expect(importedModule(of: "fileprivate import CoreData") == "CoreData")
        #expect(importedModule(of: "private import struct BurlySync.Value") == "BurlySync")
        #expect(importedModule(of: "@testable package import BurlyCore") == "BurlyCore")
        #expect(importedModule(of: "@preconcurrency public import WatchKit") == "WatchKit")
        #expect(importedModule(of: "import struct Foundation.Date") == "Foundation")
        #expect(importedModule(of: "import class BurlyCore.SomeClass") == "BurlyCore")
        #expect(importedModule(of: "// import BurlyCore is forbidden") == nil)
        #expect(importedModule(of: "/// no domain imports") == nil)
        #expect(importedModule(of: "let importIndex = 3") == nil)
    }

    private func requireSendable<T: Sendable>(_ type: T.Type) {}

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
        let next = String(tokens[importIndex + 1])
        let kinds = ["struct", "class", "enum", "protocol", "typealias", "func", "let", "var"]
        let moduleToken = kinds.contains(next) && importIndex + 2 < tokens.count
            ? String(tokens[importIndex + 2])
            : next
        return moduleToken.split(separator: ".").first.map(String.init)
    }
}

// Opt in with `-Xswiftc -DBURLY_ADAPTER_NEGATIVE_ISOLATION_COMPILE_CHECK`.
// This must fail: the adapter API cannot be called from an undeclared
// isolation domain without an `await` hop to MainActor.
#if BURLY_ADAPTER_NEGATIVE_ISOLATION_COMPILE_CHECK
private func mustNotCompileOutsideDeclaredIsolation(_ adapter: WCSessionAdapter) {
    adapter.activate()
}
#endif
