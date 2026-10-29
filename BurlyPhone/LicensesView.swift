// SPDX-License-Identifier: GPL-3.0-or-later
// About → Licenses (spec §9 Settings "about/licenses (GPL text)"). Shows the
// complete license Burly ships under: the GPL-3.0-or-later text and the App
// Store distribution exception, read from the repository-root LICENSE and
// LICENSE-APP-STORE-EXCEPTION.md files that the BurlyPhone target bundles
// as resources — the same bytes as the repository, not a retyped copy that
// could drift.
//
// Both files are hard-wrapped at ~72 columns for terminals. Rendered as-is,
// those line breaks turn ragged at large Dynamic Type sizes, so the text is
// reflowed into paragraphs (blank-line separated) and laid out lazily — the
// GPL alone is ~200 paragraphs.

import SwiftUI

struct LicensesView: View {
    private let exception = LicenseDocument.load(resource: "LICENSE-APP-STORE-EXCEPTION", extension: "md")
    private let gpl = LicenseDocument.load(resource: "LICENSE", extension: nil)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                summary

                sectionHeading("App Store exception", identifier: "licenses.exceptionHeading")
                documentBody(exception, identifierPrefix: "licenses.exception")

                sectionHeading("GNU General Public License, version 3", identifier: "licenses.gplHeading")
                documentBody(gpl, identifierPrefix: "licenses.gpl")
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Plain-language orientation before the legal text. It summarizes; the
    /// full text below is what actually governs.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("In short")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Burly is free software. You can use it, study how it works, change it, and share it, including your changed versions, under the GNU General Public License, version 3 or later. If you share Burly or a changed version, you must share its source code under the same license.")
            Text("An extra permission lets Burly, including changed versions, be linked with Apple's frameworks and distributed through Apple's App Store and TestFlight, which the GPL alone does not allow. The condition is that the complete source code stays available to everyone under the GPL. It takes none of your GPL freedoms away.")
            Text("Burly comes with no warranty. This summary is not legal advice; the full text below is what applies.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("licenses.summary")
    }

    private func sectionHeading(_ title: String, identifier: String) -> some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .padding(.top, 12)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func documentBody(_ document: LicenseDocument?, identifierPrefix: String) -> some View {
        if let document {
            ForEach(document.paragraphs) { paragraph in
                paragraphView(paragraph)
            }
        } else {
            // Bundling is a build-configuration fact, so this is a "should
            // never happen" path — but if it does, say where the text lives
            // rather than showing an empty screen.
            Text("The license text couldn't be loaded. It is also published with Burly's source code at \(SettingsView.sourceCodeURL.absoluteString).")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("\(identifierPrefix).unavailable")
        }
    }

    @ViewBuilder
    private func paragraphView(_ paragraph: LicenseDocument.Paragraph) -> some View {
        switch paragraph.kind {
        case .heading:
            Text(paragraph.text)
                .font(.headline)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .body:
            Text(paragraph.text)
                .font(.callout)
        case .rule:
            Divider()
        }
    }
}

/// A license file split into reflowed paragraphs. Kept as a plain value so
/// the reflow rules are easy to read and reason about in one place.
struct LicenseDocument {
    struct Paragraph: Identifiable {
        enum Kind {
            case heading
            case body
            case rule
        }

        let id: Int
        let kind: Kind
        let text: AttributedString
    }

    let paragraphs: [Paragraph]

    static func load(resource: String, extension fileExtension: String?, bundle: Bundle = .main) -> LicenseDocument? {
        guard let url = bundle.url(forResource: resource, withExtension: fileExtension),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return LicenseDocument(text: text, interpretsMarkdown: fileExtension == "md")
    }

    /// Blank lines separate paragraphs; the line breaks inside a paragraph
    /// are terminal wrapping and become spaces. For the Markdown exception,
    /// `#` headings and `---` rules get their own kinds and inline Markdown
    /// (bold, links, code) is rendered; the GPL is plain text throughout.
    init(text: String, interpretsMarkdown: Bool) {
        var blocks: [[String]] = [[]]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !(blocks.last?.isEmpty ?? true) { blocks.append([]) }
            } else {
                blocks[blocks.count - 1].append(trimmed)
            }
        }

        var paragraphs: [Paragraph] = []
        for lines in blocks where !lines.isEmpty {
            let joined = lines.joined(separator: " ")
            let kind: Paragraph.Kind
            var source = joined
            if interpretsMarkdown, joined.allSatisfy({ $0 == "-" }), joined.count >= 3 {
                kind = .rule
                source = ""
            } else if interpretsMarkdown, joined.hasPrefix("#") {
                kind = .heading
                source = String(joined.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
            } else {
                kind = .body
            }
            paragraphs.append(Paragraph(
                id: paragraphs.count,
                kind: kind,
                text: Self.attributed(source, interpretsMarkdown: interpretsMarkdown)
            ))
        }
        self.paragraphs = paragraphs
    }

    private static func attributed(_ source: String, interpretsMarkdown: Bool) -> AttributedString {
        guard interpretsMarkdown,
              let rendered = try? AttributedString(
                markdown: source,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
              ) else {
            return AttributedString(source)
        }
        // A relative link ("[`LICENSE`](LICENSE)" in the exception) points
        // at a sibling file in the repository; in the app it has nowhere to
        // go, so openURL would fail silently on a tap. Keep its text, drop
        // the link. Absolute links (the GitHub autolink) stay tappable.
        return rendered.transformingAttributes(\.link) { link in
            if link.value?.scheme == nil { link.value = nil }
        }
    }
}

#Preview {
    NavigationStack {
        LicensesView()
    }
}
