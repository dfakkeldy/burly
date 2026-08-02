// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import BurlyImport

@Suite("CSVTokenizer")
struct CSVTokenizerTests {
    @Test("splits a simple unquoted row on commas")
    func simpleRow() {
        let rows = CSVTokenizer.rows(in: "a,b,c\n1,2,3\n")
        #expect(rows == [["a", "b", "c"], ["1", "2", "3"]])
    }

    @Test("handles a final row with no trailing newline")
    func noTrailingNewline() {
        let rows = CSVTokenizer.rows(in: "a,b\n1,2")
        #expect(rows == [["a", "b"], ["1", "2"]])
    }

    @Test("skips genuinely blank lines without producing a phantom row")
    func skipsBlankLines() {
        let rows = CSVTokenizer.rows(in: "a,b\n\n1,2\n\n")
        #expect(rows == [["a", "b"], ["1", "2"]])
    }

    @Test("a whitespace-only line is kept as a (malformed-looking) row, not silently dropped")
    func whitespaceOnlyLineIsKept() {
        let rows = CSVTokenizer.rows(in: "a,b\n   \n1,2\n")
        #expect(rows == [["a", "b"], ["   "], ["1", "2"]])
    }

    @Test("a quoted field may contain a comma")
    func quotedFieldWithComma() {
        let rows = CSVTokenizer.rows(in: "title,note\n\"Leg Day, Heavy\",fine\n")
        #expect(rows == [["title", "note"], ["Leg Day, Heavy", "fine"]])
    }

    @Test("a doubled quote inside a quoted field is an escaped literal quote")
    func escapedQuote() {
        let quote = "\""
        // Line 2 as written in the CSV: "He said ""hi"""
        let csv = "a\n" + quote + "He said " + quote + quote + "hi" + quote + quote + quote + "\n"
        let rows = CSVTokenizer.rows(in: csv)
        #expect(rows == [["a"], ["He said " + quote + "hi" + quote]])
    }

    @Test("a quoted field may contain an embedded newline without ending the row")
    func quotedFieldWithEmbeddedNewline() {
        let rows = CSVTokenizer.rows(in: "note,val\n\"line one\nline two\",42\n")
        #expect(rows == [["note", "val"], ["line one\nline two", "42"]])
    }

    @Test("CRLF line endings are treated the same as bare LF")
    func crlfLineEndings() {
        let rows = CSVTokenizer.rows(in: "a,b\r\n1,2\r\n")
        #expect(rows == [["a", "b"], ["1", "2"]])
    }

    @Test("a row with a wrong column count is still tokenized, not rejected")
    func raggedColumnCountIsStillTokenized() {
        let rows = CSVTokenizer.rows(in: "a,b,c\n1,2\n")
        #expect(rows == [["a", "b", "c"], ["1", "2"]])
    }

    @Test("an unterminated quote at end of file does not crash or hang, and flushes what it absorbed")
    func unterminatedQuoteAtEOF() {
        let rows = CSVTokenizer.rows(in: "a,b\n\"oops,still going")
        #expect(rows.count == 2)
        #expect(rows[0] == ["a", "b"])
        // Everything after the opening quote (including the comma) was
        // absorbed into one field rather than being lost.
        #expect(rows[1] == ["oops,still going"])
    }

    @Test("empty input produces no rows")
    func emptyInput() {
        #expect(CSVTokenizer.rows(in: "").isEmpty)
    }
}
