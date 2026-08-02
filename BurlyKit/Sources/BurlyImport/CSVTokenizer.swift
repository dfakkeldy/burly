// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyImport — CSVTokenizer
//
// Hand-rolled RFC-4180-ish tokenizer: no third-party CSV library, per the
// task's constraint that the input format is fixed and known. Splits raw
// CSV text into rows of raw string fields. A field wrapped in double quotes
// may contain commas, newlines, and `""` as an escaped literal quote — the
// same shape `BurlyFixtures.HevyCSVGenerator` produces on the way out.
//
// This is a pure tokenizer: it never rejects input, never throws, and never
// crashes on malformed shapes (unterminated quotes, ragged column counts).
// Turning tokenized rows into validated data — including deciding a row's
// column count is wrong — is `HevyCSVImporter`'s job, not this file's; a
// tokenizer that itself refused "bad" input would be the one place hostile
// CSV text could take down the whole import instead of surfacing as an
// accounted, per-row problem.
//
// Scans `text.unicodeScalars` rather than `text` (a `[Character]`
// grapheme-cluster sequence) for a specific reason: Swift's default
// grapheme segmentation treats "\r\n" as a *single* `Character`, so a
// per-`Character` switch statement can never distinguish a bare `\n` from
// the `\n` half of a CRLF pair — scanning by `Unicode.Scalar` sidesteps
// that entirely and treats CR and LF as the two independent bytes they are
// in the source file.
//
// No BurlyCore/Foundation dependency: this operates on `String`/
// `Unicode.Scalar` alone.
enum CSVTokenizer {
    /// Splits `text` into logical rows of raw fields. A genuinely blank
    /// physical line (no characters at all before the next line break) is
    /// skipped rather than surfaced as a phantom one-field row — matching
    /// how a spreadsheet renders a trailing blank line in an exported file.
    /// A line that is merely whitespace, or otherwise has *some* content,
    /// still becomes a row (almost certainly a malformed one once the
    /// caller checks its column count against the header) — only truly
    /// empty lines vanish silently, since silently dropping anything with
    /// actual content would violate the never-silently-discard rule this
    /// module is built around.
    static func rows(in text: String) -> [[String]] {
        let scalars = Array(text.unicodeScalars)
        var rows: [[String]] = []
        var fields: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var rowHasContent = false
        var i = 0

        func endRow() {
            if rowHasContent {
                fields.append(String(field))
                rows.append(fields)
            }
            fields = []
            field = String.UnicodeScalarView()
            rowHasContent = false
        }

        while i < scalars.count {
            let c = scalars[i]

            if inQuotes {
                if c == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" {
                        field.append("\"") // escaped literal quote
                        i += 2
                    } else {
                        inQuotes = false
                        i += 1
                    }
                } else {
                    field.append(c)
                    i += 1
                }
                continue
            }

            switch c {
            case "\"":
                inQuotes = true
                rowHasContent = true
                i += 1
            case ",":
                fields.append(String(field))
                field = String.UnicodeScalarView()
                rowHasContent = true
                i += 1
            case "\r":
                // Bare CR is dropped; a following LF (CRLF) is handled by
                // the "\n" case on the next iteration as normal.
                i += 1
            case "\n":
                endRow()
                i += 1
            default:
                field.append(c)
                rowHasContent = true
                i += 1
            }
        }

        // Final row when the text has no trailing newline. An unterminated
        // quote at end-of-file falls out of the loop with `inQuotes` still
        // true — whatever was absorbed into `field` is flushed as-is here
        // rather than discarded; the resulting row will very likely fail
        // the caller's column-count check and be reported as malformed,
        // which is the correct outcome for truncated/corrupt input.
        endRow()

        return rows
    }
}
