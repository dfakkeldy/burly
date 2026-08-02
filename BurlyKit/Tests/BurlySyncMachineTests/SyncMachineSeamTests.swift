// SPDX-License-Identifier: GPL-3.0-or-later
// The m4-02 seam criterion, guarded twice over:
//
// 1. **Build assertion (primary).** The BurlySyncMachine target declares no
//    dependencies in Package.swift, so `import BurlyCore` in any machine
//    source cannot compile at all — and this whole test target depends on
//    BurlySyncMachine alone, so these tests run without BurlyCore linked.
// 2. **Policy guard (this file).** If someone later adds the dependency
//    edge, the build assertion silently disappears; this test still fails,
//    and names the rule they are breaking.
import Foundation
import Testing

@Suite("m4-02 seam — the machine module knows no Burly type")
struct SyncMachineSeamTests {
    @Test("every machine source imports Foundation and nothing else")
    func machineSourcesImportOnlyFoundation() throws {
        let sourcesDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BurlySyncMachineTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // BurlyKit
            .appendingPathComponent("Sources/BurlySyncMachine", isDirectory: true)

        let sources = try FileManager.default
            .contentsOfDirectory(at: sourcesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // If the directory moved, fail loudly rather than vacuously pass.
        try #require(!sources.isEmpty, "No machine sources found at \(sourcesDirectory.path)")

        for file in sources {
            let imports = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("import ") }

            #expect(
                Set(imports).isSubset(of: ["import Foundation"]),
                """
                \(file.lastPathComponent) imports \(imports) — the sync \
                machines speak UUID/Int/opaque payloads only, so Free Lunch \
                can lift the module wholesale. Bind domain types in \
                BurlySync's adapter layer instead.
                """
            )
        }
    }
}
