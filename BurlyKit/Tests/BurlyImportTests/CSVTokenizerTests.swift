// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import BurlyImport

@Suite("CSVTokenizer")
struct CSVTokenizerTests {
    @Test("splits a simple unquoted row on commas")
    func simpleRow() {
        let rows = CSVTokenizer.rows(in: "a,b,c\n1,2,3\n")
        #expect(rows == [.fields(["a", "b", "c"]), .fields(["1", "2", "3"])])
    }

    @Test("handles a final row with no trailing newline")
    func noTrailingNewline() {
        let rows = CSVTokenizer.rows(in: "a,b\n1,2")
        #expect(rows == [.fields(["a", "b"]), .fields(["1", "2"])])
    }

    @Test("skips genuinely blank lines at the very start/end without producing a phantom row")
    func skipsBlankLines() {
        // Only the interior blank line between the two real rows exercises
        // finding 1.7's "visibly counted" behavior (see
        // blankInteriorRecordIsReportedNotSilentlyDropped below); a blank
        // line at the very start or end of the scan is not "between" two
        // records the way the tokenizer's `rowHasContent` tracking sees it.
        let rows = CSVTokenizer.rows(in: "a,b\n1,2\n")
        #expect(rows == [.fields(["a", "b"]), .fields(["1", "2"])])
    }

    @Test("finding 1.7 — a blank interior record is reported, not silently dropped")
    func blankInteriorRecordIsReportedNotSilentlyDropped() {
        // Pinning regression: the old tokenizer discarded a blank physical
        // line entirely, producing only 2 rows here (and shifting every
        // subsequent row's apparent position). The fixed tokenizer reports
        // the blank line as its own `.blank` record, in its true position.
        let rows = CSVTokenizer.rows(in: "a,b\n\n1,2\n")
        #expect(rows == [.fields(["a", "b"]), .blank, .fields(["1", "2"])])
    }

    @Test("a whitespace-only line is kept as a (malformed-looking) row, not silently dropped")
    func whitespaceOnlyLineIsKept() {
        let rows = CSVTokenizer.rows(in: "a,b\n   \n1,2\n")
        #expect(rows == [.fields(["a", "b"]), .fields(["   "]), .fields(["1", "2"])])
    }

    @Test("a quoted field may contain a comma")
    func quotedFieldWithComma() {
        let rows = CSVTokenizer.rows(in: "title,note\n\"Leg Day, Heavy\",fine\n")
        #expect(rows == [.fields(["title", "note"]), .fields(["Leg Day, Heavy", "fine"])])
    }

    @Test("a doubled quote inside a quoted field is an escaped literal quote")
    func escapedQuote() {
        let quote = "\""
        // Line 2 as written in the CSV: "He said ""hi"""
        let csv = "a\n" + quote + "He said " + quote + quote + "hi" + quote + quote + quote + "\n"
        let rows = CSVTokenizer.rows(in: csv)
        let expectedField = "He said " + quote + "hi" + quote
        #expect(rows == [.fields(["a"]), .fields([expectedField])])
    }

    @Test("a quoted field may contain an embedded newline without ending the row")
    func quotedFieldWithEmbeddedNewline() {
        let rows = CSVTokenizer.rows(in: "note,val\n\"line one\nline two\",42\n")
        #expect(rows == [.fields(["note", "val"]), .fields(["line one\nline two", "42"])])
    }

    @Test("CRLF line endings are treated the same as bare LF")
    func crlfLineEndings() {
        let rows = CSVTokenizer.rows(in: "a,b\r\n1,2\r\n")
        #expect(rows == [.fields(["a", "b"]), .fields(["1", "2"])])
    }

    @Test("finding 1.6 — a bare CR alone is a record terminator, not silently dropped")
    func bareCRIsARecordTerminator() {
        // Pinning regression: the old tokenizer unconditionally discarded
        // every "\r" byte, so a bare-CR-only export concatenated the
        // header and every data row into one giant row instead of ending
        // each record.
        let rows = CSVTokenizer.rows(in: "a,b\r1,2\r")
        #expect(rows == [.fields(["a", "b"]), .fields(["1", "2"])])
    }

    @Test("finding 1.6 — a bare CR inside a quoted field is preserved as literal content")
    func bareCRInsideQuotesIsPreserved() {
        let rows = CSVTokenizer.rows(in: "note,val\n\"line one\rline two\",42\n")
        #expect(rows == [.fields(["note", "val"]), .fields(["line one\rline two", "42"])])
    }

    @Test("a row with a wrong column count is still tokenized, not rejected")
    func raggedColumnCountIsStillTokenized() {
        let rows = CSVTokenizer.rows(in: "a,b,c\n1,2\n")
        #expect(rows == [.fields(["a", "b", "c"]), .fields(["1", "2"])])
    }

    @Test("finding 1.3 — an unterminated quote at end of file is reported malformed, not flushed as a value")
    func unterminatedQuoteAtEOFIsReportedMalformed() {
        // Pinning regression: the old tokenizer flushed everything it had
        // absorbed into the open quote as a normal field value — which,
        // when the column count happened to still line up, imported as a
        // wrong value instead of being caught as malformed.
        let rows = CSVTokenizer.rows(in: "a,b\n\"oops,still going")
        #expect(rows == [.fields(["a", "b"]), .unterminatedQuote])
    }

    @Test("finding 1.4 — a stray quote after unquoted content has begun is reported malformed, not silently merged")
    func strayQuoteMidFieldIsReportedMalformed() {
        // Pinning regression: the old tokenizer let a "\"" reopen quoted
        // mode anywhere, so an unquoted reps field like `1"2"` tokenized
        // as the single value "12" instead of being caught as malformed.
        let rows = CSVTokenizer.rows(in: "title,reps\nRow,1\"2\"\n")
        #expect(rows == [.fields(["title", "reps"]), .strayQuote])
    }

    @Test("finding 1.5 — a field that grows past the size bound is reported as an oversized record")
    func oversizedFieldIsReportedMalformed() {
        let hugeField = String(repeating: "x", count: CSVTokenizer.maxFieldLength + 10)
        let rows = CSVTokenizer.rows(in: "a,b\n\"\(hugeField)\",2\n")
        #expect(rows == [.fields(["a", "b"]), .oversizedRecord])
    }

    @Test("finding 1.5 — an oversized record does not prevent the tokenizer from resynchronizing on the next record")
    func oversizedRecordResynchronizes() {
        let hugeField = String(repeating: "x", count: CSVTokenizer.maxFieldLength + 10)
        let rows = CSVTokenizer.rows(in: "a,b\n\"\(hugeField)\",2\ngood,row\n")
        #expect(rows == [.fields(["a", "b"]), .oversizedRecord, .fields(["good", "row"])])
    }

    @Test("empty input produces no rows")
    func emptyInput() {
        #expect(CSVTokenizer.rows(in: "").isEmpty)
    }
}
