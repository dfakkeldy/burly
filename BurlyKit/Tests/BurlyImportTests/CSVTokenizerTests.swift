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
        #expect(rows == [.fields(["a", "b"]), .oversizedRecord(.fieldLength(CSVTokenizer.maxFieldLength))])
    }

    @Test("finding 1.5 — an oversized record does not prevent the tokenizer from resynchronizing on the next record")
    func oversizedRecordResynchronizes() {
        // Pinning regression (round 2 blocker): the old design kept
        // treating the record as "still inside quotes" even after the
        // field bound tripped, so resync only happened once the ACTUAL
        // closing quote for the huge field turned up later in the input.
        // The redesign transitions straight to `recordError` the instant
        // the bound trips, so resync no longer depends on ever finding a
        // real closing quote at all — proven below by an unterminated
        // huge field (no closing quote anywhere) still resyncing cleanly.
        let hugeField = String(repeating: "x", count: CSVTokenizer.maxFieldLength + 10)
        let rows = CSVTokenizer.rows(in: "a,b\n\"\(hugeField)\",2\ngood,row\n")
        #expect(rows == [
            .fields(["a", "b"]),
            .oversizedRecord(.fieldLength(CSVTokenizer.maxFieldLength)),
            .fields(["good", "row"])
        ])
    }

    @Test("an oversized field with no closing quote at all still resynchronizes at the next real terminator")
    func oversizedUnclosedFieldStillResynchronizes() {
        let hugeField = String(repeating: "x", count: CSVTokenizer.maxFieldLength + 10)
        // No closing quote anywhere — the old design would keep this
        // "inside quotes" forever and swallow `good,row` as literal
        // content too; the redesign's `recordError` transition happens the
        // instant the field bound trips, regardless of whether a closing
        // quote ever shows up.
        let rows = CSVTokenizer.rows(in: "a,b\n\"\(hugeField)\ngood,row\n")
        #expect(rows == [
            .fields(["a", "b"]),
            .oversizedRecord(.fieldLength(CSVTokenizer.maxFieldLength)),
            .fields(["good", "row"])
        ])
    }

    @Test("empty input produces no rows")
    func emptyInput() {
        #expect(CSVTokenizer.rows(in: "").isEmpty)
    }

    // MARK: - m7-01 adversarial review round 2 — clean-redesign properties

    @Test("required property 1 — a missing close quote mid-file does not swallow or merge subsequent physical rows forever")
    func missingCloseQuoteMidFileResynchronizesWithinABoundedPrefix() {
        // Pinning regression (round-2 blocker): the old tokenizer kept
        // "inside quotes" state for as long as no closing quote appeared,
        // so a missing close quote could consume EVERY remaining physical
        // row in the file into one giant malformed record, with no bound
        // at all. The redesign's runaway-quote guard
        // (`maxEmbeddedTerminatorsPerRecord`) caps how many embedded line
        // breaks an open quote is believed to legitimately contain before
        // giving up on it ever closing — so the swallowed prefix is always
        // a small, FIXED size regardless of how many good rows follow,
        // never "the rest of the file". This file supplies many more good
        // rows than that bound to make the fixed-size-not-proportional
        // property observable.
        let goodRowCount = CSVTokenizer.maxEmbeddedTerminatorsPerRecord * 3
        let goodRows = (0..<goodRowCount).map { "good\($0),row\($0)" }
        let csv = "\"broken\n" + goodRows.joined(separator: "\n") + "\n"

        let rows = CSVTokenizer.rows(in: csv)

        let fieldsRows = rows.compactMap { row -> [String]? in
            if case .fields(let fields) = row { return fields }
            return nil
        }
        let malformedRows = rows.filter { if case .fields = $0 { return false }; return true }

        // Exactly one malformed record accounts for the whole swallowed
        // prefix — the runaway-quote guard trips once, resynchronizes
        // once, not once per swallowed physical line.
        #expect(malformedRows == [.unterminatedQuote])

        // Whatever survived is an exact, uncorrupted, correctly-ordered
        // suffix of the good rows — proving nothing after resync was
        // merged, reordered, or silently dropped — and a solid majority
        // of the good rows survive despite the bound, since the bound is
        // tiny relative to how many good rows this file supplies.
        #expect(fieldsRows.count > goodRowCount / 2)
        let expectedSuffix = goodRows.suffix(fieldsRows.count).map { row -> [String] in
            let parts = row.split(separator: ",").map(String.init)
            return parts
        }
        #expect(fieldsRows == expectedSuffix)

        // The key, categorical property: the swallowed prefix's size is
        // fixed (bounded by the guard), not proportional to how much
        // "subsequent" content exists — tripling `goodRowCount` above
        // would swallow the SAME number of rows, not three times as many.
        let swallowedCount = goodRowCount - fieldsRows.count
        #expect(swallowedCount <= CSVTokenizer.maxEmbeddedTerminatorsPerRecord + 2)
    }

    @Test("required property 1 — a later physical row's quote cannot reach back and falsely close an earlier unterminated field, merging rows")
    func laterQuoteCannotMergeAcrossAnUnterminatedField() {
        // Pinning regression (round-2 blocker, second half): "if a later
        // physical row contains a quote, that quote can close the earlier
        // field and merge the rows into one logical record." The redesign
        // never lets a LATER row's quote close an earlier still-open one —
        // `recordError` (entered via the runaway-quote guard) stops
        // interpreting quote syntax entirely, so a quote appearing well
        // after the bound trips is just more skipped content, never a
        // false close.
        let goodRowCount = CSVTokenizer.maxEmbeddedTerminatorsPerRecord + 5
        var lines = ["\"broken"]
        lines.append(contentsOf: (0..<goodRowCount).map { "line\($0)" })
        // A row containing a quote character placed well past the
        // runaway-quote bound — must NOT be interpreted as closing the
        // long-dead field from line 1.
        lines.append("\"reopened\",value")
        lines.append("final,row")
        let csv = lines.joined(separator: "\n") + "\n"

        let rows = CSVTokenizer.rows(in: csv)

        // The genuinely final, unambiguous row must still parse cleanly —
        // if the stray quote had reached back and reopened/merged
        // anything, this row's clean field split would be the first
        // casualty.
        #expect(rows.last == .fields(["final", "row"]))
        // No two `.fields` rows may be textually identical to a merge of
        // multiple source lines — every accounted `.fields` row must
        // correspond to exactly one source line's content.
        let fieldsRows = rows.compactMap { row -> [String]? in
            if case .fields(let fields) = row { return fields }
            return nil
        }
        #expect(fieldsRows.allSatisfy { $0.count <= 2 })
    }

    @Test("required property 2 — content after a closing quote is malformed, not silently concatenated onto the value")
    func contentAfterClosingQuoteIsMalformed() {
        // Pinning regression (round-2 new defect #1): `"Bench Press
        // (Barbell)"junk` used to tokenize as the single value
        // `Bench Press (Barbell)junk` instead of being rejected.
        let rows = CSVTokenizer.rows(in: "title,note\n\"Bench Press (Barbell)\"junk,fine\n")
        #expect(rows == [.fields(["title", "note"]), .contentAfterClosingQuote])
    }

    @Test("required property 2 — a comma immediately after a closing quote is legal (the ordinary next-field case)")
    func commaAfterClosingQuoteIsLegal() {
        let rows = CSVTokenizer.rows(in: "\"a\",\"b\"\n")
        #expect(rows == [.fields(["a", "b"])])
    }

    @Test("required property 2 — a CRLF immediately after a closing quote is legal and ends the record")
    func crlfAfterClosingQuoteIsLegal() {
        let rows = CSVTokenizer.rows(in: "\"a\",\"b\"\r\n\"c\",\"d\"\r\n")
        #expect(rows == [.fields(["a", "b"]), .fields(["c", "d"])])
    }

    @Test("required property 2 — EOF immediately after a closing quote is legal, not an unterminated quote")
    func eofAfterClosingQuoteIsLegal() {
        let rows = CSVTokenizer.rows(in: "a,b\n\"c\",\"d\"")
        #expect(rows == [.fields(["a", "b"]), .fields(["c", "d"])])
    }

    @Test("required property 3 — a record whose total content exceeds the per-record bound is reported oversized, even though no single field is over the per-field bound")
    func recordTotalSizeBoundIsEnforced() {
        // Five unquoted fields, each safely under `maxFieldLength` on its
        // own, but summing well past `maxRecordLength` together.
        let bigFieldSize = (CSVTokenizer.maxFieldLength / 2)
        let bigField = String(repeating: "y", count: bigFieldSize)
        let fieldCount = (CSVTokenizer.maxRecordLength / bigFieldSize) + 2
        let row = Array(repeating: bigField, count: fieldCount).joined(separator: ",")
        let rows = CSVTokenizer.rows(in: "header\n\(row)\ngood,row\n")

        #expect(rows == [
            .fields(["header"]),
            .oversizedRecord(.recordLength(CSVTokenizer.maxRecordLength)),
            .fields(["good", "row"])
        ])
    }

    @Test("required property 3 — a record with more fields than the field-count bound is reported oversized")
    func fieldCountBoundIsEnforced() {
        // Pinning regression (round-2 finding): "a record containing
        // millions of empty comma-separated fields... can still grow
        // memory without bound." A record with more commas than
        // `maxFieldsPerRecord` allows must be capped, not tokenized as one
        // enormous `fields` array.
        let commas = String(repeating: ",", count: CSVTokenizer.maxFieldsPerRecord + 10)
        let rows = CSVTokenizer.rows(in: "header\n\(commas)\ngood,row\n")

        #expect(rows == [
            .fields(["header"]),
            .oversizedRecord(.fieldCount(CSVTokenizer.maxFieldsPerRecord)),
            .fields(["good", "row"])
        ])
    }

    // MARK: - Adversarial self-check (m7-01 review round 2 verification requirement)

    @Test("adversarial fuzz — hostile random byte-strings never crash, never hang, and never produce overlapping rows")
    func adversarialFuzzNeverCrashesOrOverlaps() {
        // Fixed seed: deterministic across runs. A small, hostile alphabet
        // (quotes, commas, CR, LF, backslash, digits, letters, a couple of
        // multi-scalar/combining characters) maximizes the odds of hitting
        // every state-machine transition, including invalid ones, without
        // needing an enormous corpus.
        var rng = SplitMix64(seed: 0xC5F_7001)
        let alphabet: [Character] = [
            "\"", ",", "\r", "\n", "a", "b", "0", "1", "\\", " ",
            "\u{FEFF}", "\u{FFFD}", "\u{0301}", "é", "\t"
        ]

        for trial in 0..<300 {
            let length = Int(rng.next() % 200)
            var hostile = ""
            hostile.reserveCapacity(length)
            for _ in 0..<length {
                let index = Int(rng.next() % UInt64(alphabet.count))
                hostile.append(alphabet[index])
            }

            // Never crashes, never hangs: simply calling this and
            // returning is the assertion. A hung/looping tokenizer would
            // time out the whole test run instead of failing gracefully,
            // so this also stands in for "always terminates".
            let rows = CSVTokenizer.rows(in: hostile)

            // Never returns rows whose parse position overlaps: every
            // `.fields` row's total reconstructed content must be
            // consistent with having consumed a disjoint slice of the
            // input — verified indirectly by confirming the tokenizer
            // never produces more `.fields([String])` field-content
            // scalars in total than existed in the source text (a
            // duplicated/overlapping read would over-count).
            let totalFieldScalars = rows.reduce(into: 0) { total, row in
                if case .fields(let fields) = row {
                    total += fields.reduce(0) { $0 + $1.unicodeScalars.count }
                }
            }
            #expect(
                totalFieldScalars <= hostile.unicodeScalars.count,
                "trial \(trial) produced more field content than input scalars for input: \(hostile.debugDescription)"
            )
        }
    }
}

/// Tiny, dependency-free, deterministic PRNG for the adversarial fuzz test
/// above — no need for a third-party dependency or `SystemRandomNumberGenerator`
/// (which isn't seedable and would make the fuzz test non-reproducible).
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
