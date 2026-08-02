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
        // wrong value instead of being caught as malformed. Reaching true
        // EOF with no bound ever tripped has nothing left to lose, so
        // `approxRowsLost` is 0.
        let rows = CSVTokenizer.rows(in: "a,b\n\"oops,still going")
        #expect(rows == [.fields(["a", "b"]), .unterminatedQuoteConsumedRemainder(approxRowsLost: 0)])
    }

    @Test("finding 1.4 — a stray quote after unquoted content has begun is reported malformed, not silently merged")
    func strayQuoteMidFieldIsReportedMalformed() {
        // Pinning regression: the old tokenizer let a "\"" reopen quoted
        // mode anywhere, so an unquoted reps field like `1"2"` tokenized
        // as the single value "12" instead of being caught as malformed.
        let rows = CSVTokenizer.rows(in: "title,reps\nRow,1\"2\"\n")
        #expect(rows == [.fields(["title", "reps"]), .strayQuote])
    }

    @Test("finding 1.5 — an oversized field inside a quote consumes the rest of the file rather than risking a resync")
    func oversizedFieldInsideQuoteConsumesRemainder() {
        // Round-3 adjudication 1: a bound tripping WHILE a quote is still
        // open can never safely resynchronize (see CSVTokenizer's
        // FAILURE-MODE TABLE) — unlike an unquoted oversized field, this
        // consumes to true EOF as ONE malformed record instead of
        // resynchronizing at the next terminator. Here the file ends
        // shortly after the bound trips, so only the one trailing
        // terminator is "lost".
        let hugeField = String(repeating: "x", count: CSVTokenizer.maxFieldLength + 10)
        let rows = CSVTokenizer.rows(in: "a,b\n\"\(hugeField)\",2\n")
        #expect(rows == [.fields(["a", "b"]), .unterminatedQuoteConsumedRemainder(approxRowsLost: 1)])
    }

    // MARK: - m7-01 adversarial review round 4 — approxRowsLost undercount

    @Test("round-4 finding 1 — a bound tripped BY a terminator still counts that terminator as one lost row (reviewer trigger a: LF trips the field bound)")
    func boundTrippedByLFStillCountsIt() {
        // Pinning regression: the scalar that trips a quoted-context bound
        // was advanced by the `quotedField` caller's own `i += 1` BEFORE
        // `consumeToEOF`'s skip loop ever got a chance to count it — so a
        // bound tripped BY a terminator silently omitted that terminator
        // from `approxRowsLost`. Exact reviewer trigger: an open quote,
        // exactly `maxFieldLength` x's (fills the field to precisely the
        // bound, still legal), then a bare LF that trips the bound on
        // itself, then EOF. Old behavior undercounted this as 0; correct
        // is 1.
        let csv = "\"" + String(repeating: "x", count: CSVTokenizer.maxFieldLength) + "\n"
        let rows = CSVTokenizer.rows(in: csv)
        #expect(rows == [.unterminatedQuoteConsumedRemainder(approxRowsLost: 1)])
    }

    @Test("round-4 finding 1 — a CRLF whose LF trips the bound is still counted exactly once, not zero (reviewer trigger b)")
    func boundTrippedByLFHalfOfCRLFStillCountsItOnce() {
        // Exact reviewer trigger: `maxFieldLength - 1` x's (one short of
        // the bound), then a CRLF pair — the CR fits under the bound and
        // is appended as ordinary content (no trip), but the LF is what
        // trips it. "CRLF still once": the pair must be counted as ONE
        // lost row, not the zero the old code produced (the CR's harmless
        // append doesn't contribute a count on its own; the trip lands
        // exactly on the LF's own position, which `terminatorLength(at:)`
        // reports as length 1 there — no double-counting the CR).
        let csv = "\"" + String(repeating: "x", count: CSVTokenizer.maxFieldLength - 1) + "\r\n"
        let rows = CSVTokenizer.rows(in: csv)
        #expect(rows == [.unterminatedQuoteConsumedRemainder(approxRowsLost: 1)])
    }

    @Test("round-3 adjudication 1 — an oversized quoted field consumes ALL subsequent rows, even a genuine later closing quote and well-formed rows, rather than resynchronizing")
    func oversizedQuotedFieldNeverResynchronizesEvenWithAGenuineCloseLater() {
        // Pinning regression (round-3 adjudication 1, replacing round-2's
        // "resynchronizes on the next record" expectation): the round-2
        // design transitioned straight to `recordError` and resynchronized
        // at the very next terminator once a quoted field's bound tripped
        // — which the round-3 review proved unsafe in general (a bound
        // tripping inside a legitimate long note is indistinguishable from
        // one tripping inside truly hostile content). Now ANY bound
        // tripping while a quote is open gives up on the rest of the
        // file entirely — "good,row" below, despite being perfectly
        // well-formed and following a genuine closing quote, must never
        // import as data.
        let hugeField = String(repeating: "x", count: CSVTokenizer.maxFieldLength + 10)
        let rows = CSVTokenizer.rows(in: "a,b\n\"\(hugeField)\",2\ngood,row\n")
        #expect(rows == [.fields(["a", "b"]), .unterminatedQuoteConsumedRemainder(approxRowsLost: 2)])
    }

    @Test("an oversized field with no closing quote at all also consumes the remainder, not just resynchronizes")
    func oversizedUnclosedFieldAlsoConsumesRemainder() {
        let hugeField = String(repeating: "x", count: CSVFieldTestSupport.maxFieldLengthPlusTen)
        let rows = CSVTokenizer.rows(in: "a,b\n\"\(hugeField)\ngood,row\n")
        #expect(rows == [.fields(["a", "b"]), .unterminatedQuoteConsumedRemainder(approxRowsLost: 2)])
    }

    @Test("empty input produces no rows")
    func emptyInput() {
        #expect(CSVTokenizer.rows(in: "").isEmpty)
    }

    // MARK: - m7-01 adversarial review round 3 — adjudication 1 (runaway-quote guard removed)

    @Test("round-3 adjudication 1 — a missing close quote mid-file consumes the rest of the file as ONE malformed record; nothing after it ever imports as data")
    func missingCloseQuoteMidFileConsumesRestOfFile() {
        // Pinning regression: round 2 introduced a bounded
        // "maxEmbeddedTerminatorsPerRecord" guard meant to stop a missing
        // close quote from swallowing arbitrarily many physical rows. The
        // round-3 review proved this is an INJECTION VECTOR, not a safety
        // net: Hevy notes are free-form, so a legitimate multi-line note
        // could exceed any fixed bound, get resynced MID-CONTENT, and have
        // one of its own lines misread as a fabricated workout row —
        // silent row-boundary corruption, worse than the data loss it was
        // meant to prevent. The guard is REMOVED, not retuned: an open
        // quote that never legitimately closes swallows everything to
        // true EOF as one honestly-reported malformed record, and nothing
        // "good-looking" after it is ever reinterpreted as a new row. 50
        // good-looking rows here is deliberately more than the round-2
        // guard's old bound (32) — under round 2 this would have
        // resynchronized around row ~33; under round 3 nothing resyncs no
        // matter how many rows follow.
        let goodRows = (0..<50).map { "good\($0),row\($0)" }
        let csv = "\"broken\n" + goodRows.joined(separator: "\n") + "\n"

        let rows = CSVTokenizer.rows(in: csv)

        // The entire remainder — every "good" row included — is absorbed
        // as literal content of the one still-open quoted field; none of
        // it is ever reinterpreted as CSV structure. No bound ever trips
        // (the file is small), so the tokenizer reaches true EOF still
        // inside the open quote with nothing further to "lose".
        #expect(rows == [.unterminatedQuoteConsumedRemainder(approxRowsLost: 0)])
    }

    @Test("round-3 adjudication 1 — once a bound trips inside an open quote, a later well-formed-looking quoted row in the discarded remainder is never reinterpreted as new row structure")
    func laterQuoteInConsumedRemainderIsNeverReinterpreted() {
        // Distinguishes the (removed) round-2 defect from what remains
        // TRUE and required: once `consumeToEOF` is entered (because a
        // bound tripped, not merely because a quote is still open with no
        // failure yet), literally nothing afterward — not even a
        // perfectly well-formed, correctly quoted row — is ever
        // reinterpreted as data.
        let hugeField = String(repeating: "x", count: CSVFieldTestSupport.maxFieldLengthPlusTen)
        let csv = "a,b\n\"\(hugeField)\ngood-looking,\"quoted\",row\nfinal,row\n"

        let rows = CSVTokenizer.rows(in: csv)

        let fieldsRows = rows.compactMap { row -> [String]? in
            if case .fields(let fields) = row { return fields }
            return nil
        }
        // Only the header-shaped first row survives; the syntactically
        // well-formed "good-looking" and "final" rows are both swallowed.
        #expect(fieldsRows == [["a", "b"]])
    }

    @Test("round-3 finding 1.1 — an escaped-quote append that trips the record-size bound is not clobbered back into quotedField; nothing after it imports as data")
    func escapedQuoteAppendTrippingBoundIsNotClobbered() {
        // Pinning regression: `quoteSeen`'s escaped-quote branch called
        // `appendToField` (which can trip a bound and enter an error
        // state) and then unconditionally reassigned `state =
        // .quotedField` immediately afterward — silently UNDOING the
        // error transition. The dangerous consequence only shows up when
        // the VERY NEXT scalar after the clobbered escape is itself a
        // real closing quote (not more plain content, which would
        // harmlessly re-trip the same bound on its own): `quotedField`'s
        // own `"` handling unconditionally enters `quoteSeen` regardless
        // of prior state, so the clobber lets the tokenizer walk straight
        // back to a legal-looking close, comma, and terminator — emitting
        // the oversized record as ordinary `.fields` data (and resuming
        // normal parsing for everything after it) instead of ever
        // reporting it malformed. Exact reviewer scenario: four ~1 MiB
        // fields, then a field containing "abcd" followed by an escaped
        // quote pair positioned so its second `"` (the literal-quote
        // append) is the exact scalar that trips the per-record bound,
        // immediately followed by the field's real closing quote.
        let fieldSize = (CSVTokenizer.maxRecordLength - 4) / 4
        let bigField = String(repeating: "y", count: fieldSize)
        let firstFourFields = Array(repeating: bigField, count: 4).joined(separator: ",")
        let csv = "header\n" + firstFourFields + ",\"abcd\"\"\",lastfield\ngood,row\n"

        let rows = CSVTokenizer.rows(in: csv)

        // Fixed behavior: the whole oversized record — including
        // "lastfield" and the well-formed "good,row" that follows — is
        // discarded as one malformed record, never split back out into
        // ordinary `.fields` data.
        #expect(rows == [.fields(["header"]), .unterminatedQuoteConsumedRemainder(approxRowsLost: 2)])
    }

    // MARK: - required property 2 (post-quote transitions — unaffected by round 3)

    @Test("required property 2 — content after a closing quote is malformed, not silently concatenated onto the value")
    func contentAfterClosingQuoteIsMalformed() {
        // Pinning regression (round-2 new defect #1): `"Bench Press
        // (Barbell)"junk` used to tokenize as the single value
        // `Bench Press (Barbell)junk` instead of being rejected. This is
        // unquoted context (the quote already closed) — still safe to
        // resynchronize under round 3's adjudication.
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

    // MARK: - required property 3 (bounded everything, unquoted context)

    @Test("required property 3 — a record whose total content exceeds the per-record bound is reported oversized, even though no single field is over the per-field bound")
    func recordTotalSizeBoundIsEnforced() {
        // Five unquoted fields, each safely under `maxFieldLength` on its
        // own, but summing well past `maxRecordLength` together. Unquoted
        // context: still safe to resynchronize under round 3's
        // adjudication.
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

    // MARK: - m7-01 round 3 finding 3.2 — field-count boundary off-by-one

    @Test("round-3 finding 3.2 — exactly maxFieldsPerRecord fields is legal")
    func exactlyMaxFieldsPerRecordIsLegal() {
        let fields = Array(repeating: "x", count: CSVTokenizer.maxFieldsPerRecord)
        let row = fields.joined(separator: ",")
        let rows = CSVTokenizer.rows(in: "header\n" + row + "\n")
        #expect(rows == [.fields(["header"]), .fields(fields)])
    }

    @Test("round-3 finding 3.2 — pinning regression: maxFieldsPerRecord + 1 fields is oversized, not silently allowed")
    func oneMoreThanMaxFieldsPerRecordIsOversized() {
        // Pinning regression: the round-2 boundary check was `fieldCount
        // <= maxFieldsPerRecord` evaluated AFTER incrementing for the
        // field just started, which actually permitted
        // `maxFieldsPerRecord + 1` fields before ever tripping.
        let fields = Array(repeating: "x", count: CSVTokenizer.maxFieldsPerRecord + 1)
        let row = fields.joined(separator: ",")
        let rows = CSVTokenizer.rows(in: "header\n" + row + "\n")
        #expect(rows == [.fields(["header"]), .oversizedRecord(.fieldCount(CSVTokenizer.maxFieldsPerRecord))])
    }

    // MARK: - Adversarial self-check (m7-01 review round 2 verification requirement; strengthened round 3 finding 6.1)

    @Test("adversarial fuzz — short hostile random byte-strings never crash; explicit iteration-budget termination; full non-overlapping single-pass scalar coverage")
    func adversarialFuzzShortHostileInputsFullCoverage() {
        // What this proves, exactly (round-3 finding 6.1: the prior
        // version of this test overstated itself — it only checked for
        // no-crash and a loose scalar-count inequality that couldn't
        // detect an overlapping or gapped read, and the reviewer measured
        // ZERO trials in it ever reaching any size bound):
        //   1. Never crashes on a short, densely hostile random string
        //      (fixed seed, deterministic).
        //   2. Always terminates — proven by an explicit iteration budget
        //      (`CSVTokenizer.rowsWithDiagnostics`'s `iterationBudget`),
        //      NOT by relying on the test harness's wall-clock timeout to
        //      catch a hang.
        //   3. Reads the ENTIRE input exactly once, front to back, with no
        //      gap and no overlap — proven mechanically by reconstructing
        //      full scalar coverage from the diagnostic per-iteration step
        //      ranges, not merely inferred from output sizes.
        // This corpus is short and NOT expected to trip any size bound —
        // see `adversarialFuzzBoundTrippingAndQuotedHeavyShapes` below for
        // a corpus specifically built to do that.
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

            assertFullCoverageNoCrashNoHang(of: hostile, trialLabel: "short trial \(trial)")
        }
    }

    @Test("adversarial fuzz — quoted-heavy shapes that actually trip size bounds: escaped quotes at boundaries, long embedded-terminator runs, oversized fields")
    func adversarialFuzzBoundTrippingAndQuotedHeavyShapes() {
        // Round-3 finding 6.1(b): the short-corpus fuzz test above can
        // never exercise `maxFieldLength`/`maxRecordLength`/
        // `maxFieldsPerRecord` — its longest input is 200 scalars. This
        // corpus deliberately builds long quoted runs (sometimes past the
        // field bound), embeds terminators inside them, and places an
        // escaped-quote pair immediately after the bulk content
        // (mirroring finding 1.1's exact reviewer shape: an escaped
        // quote's append is what trips the bound) — proving the fuzz net
        // actually reaches the code paths finding 6.1 flagged as
        // completely untested (the reviewer measured zero trials reaching
        // any bound in the round-2 version of this test).
        //
        // Round-4 finding 6.1-follow-up: TWO fixes to the guarantee below.
        // (1) `assertFullCoverageNoCrashNoHang`'s "did a bound trip"
        // signal now requires a GENUINE trip (`.oversizedRecord`, or
        // `.unterminatedQuoteConsumedRemainder` with a nonzero
        // `approxRowsLost`) — a plain `approxRowsLost == 0` result can
        // also mean an ordinary "ran out of input while quoted" case with
        // NO bound ever tripped (e.g. a short trailing unterminated quote
        // in the SHORT corpus above), which must not silently satisfy
        // this corpus's "bounds actually trip" guarantee. (2) trial 0's
        // field size is no longer left to the probabilistic `makeHuge`
        // branch (which could, for some values of the RNG draw, land
        // just UNDER `maxFieldLength` and never trip anything) — it's
        // deterministically forced to exceed the bound, so the guarantee
        // below is real regardless of how the RNG happens to behave for
        // this seed, not just overwhelmingly likely.
        var rng = SplitMix64(seed: 0x807A_9E11)
        var atLeastOneGenuineBoundTrip = false

        for trial in 0..<15 {
            let csv = generateQuotedHeavyHostileCSV(using: &rng, guaranteeOversizedField: trial == 0)
            let (rows, trippedGenuinely) = assertFullCoverageNoCrashNoHang(of: csv, trialLabel: "quoted-heavy trial \(trial)")
            if trippedGenuinely { atLeastOneGenuineBoundTrip = true }
            _ = rows
        }

        #expect(
            atLeastOneGenuineBoundTrip,
            "expected at least one trial in this bound-stressing corpus to genuinely trip a size bound (not merely reach a natural, bound-free unterminated-quote-at-EOF outcome)"
        )
    }
}

/// Small shared constant so the "oversized field" tests below don't each
/// redundantly recompute `maxFieldLength + 10`.
private enum CSVFieldTestSupport {
    static let maxFieldLengthPlusTen = CSVTokenizer.maxFieldLength + 10
}

/// Shared assertion helper (round-3 finding 6.1): runs `text` through
/// `CSVTokenizer.rowsWithDiagnostics`, asserting termination via an
/// explicit iteration budget (never the test harness's wall-clock
/// timeout) and full/non-overlapping/single-pass scalar coverage
/// reconstructed from the diagnostic per-iteration step ranges. Returns
/// the tokenized rows and whether a GENUINE bound trip appeared, so the
/// bound-stressing corpus can assert it actually reached one.
@discardableResult
private func assertFullCoverageNoCrashNoHang(
    of text: String,
    trialLabel: String
) -> (rows: [CSVTokenizer.Row], trippedAGenuineBound: Bool) {
    let scalarCount = text.unicodeScalars.count
    // By construction every main-loop iteration advances by at least one
    // scalar, so a correct scan never needs more iterations than there are
    // scalars; +16 is slack for small/edge-case inputs, not a "just in
    // case" fudge for tolerating a real hang.
    let budget = scalarCount + 16

    let (rows, steps, budgetExceeded) = CSVTokenizer.rowsWithDiagnostics(in: text, iterationBudget: budget)

    #expect(
        !budgetExceeded,
        "\(trialLabel): exceeded iteration budget \(budget) for a \(scalarCount)-scalar input — the scan is not making forward progress"
    )

    // Full, non-overlapping, single-pass coverage: each step's start must
    // equal the previous step's end (no gap, no overlap, no double-read),
    // the first step implicitly starts at 0 (`expectedNext`'s initial
    // value), and the last step's end must equal the input's total scalar
    // count — together these mechanically reconstruct the ENTIRE input
    // from the recorded steps alone, rather than merely inferring it from
    // output sizes. Scanned as plain Swift first and asserted with a
    // handful of `#expect`s at the end, rather than one `#expect` per
    // step — a huge quoted field can produce millions of single-scalar
    // steps, and Swift Testing's per-call bookkeeping makes one `#expect`
    // per step prohibitively slow at that scale (a fixed number of
    // assertions keeps this test fast regardless of input size).
    var expectedNext = 0
    var firstGapOrOverlap: (atScalar: Int, expectedScalar: Int)?
    var sawZeroLengthStep = false
    for step in steps {
        if step.lowerBound != expectedNext, firstGapOrOverlap == nil {
            firstGapOrOverlap = (step.lowerBound, expectedNext)
        }
        if step.isEmpty {
            sawZeroLengthStep = true
        }
        expectedNext = step.upperBound
    }
    #expect(firstGapOrOverlap == nil, "\(trialLabel): gap or overlap — \(String(describing: firstGapOrOverlap))")
    #expect(!sawZeroLengthStep, "\(trialLabel): a step consumed zero scalars — no forward progress")
    #expect(expectedNext == scalarCount, "\(trialLabel): coverage ended at \(expectedNext), expected \(scalarCount)")

    // Round-4 finding 6.1-follow-up: a GENUINE bound trip is either
    // `.oversizedRecord` (always unquoted-context) or
    // `.unterminatedQuoteConsumedRemainder` with a NONZERO `approxRowsLost`
    // — that counter only ever increments inside `consumeToEOF`, which is
    // only ever entered via an actual field/record-size bound tripping on
    // quoted content (see `CSVTokenizer`'s FAILURE-MODE TABLE). A zero
    // `approxRowsLost` is NOT proof of a trip: it's also exactly what an
    // ordinary "ran out of input while a quote was still open, no bound
    // ever tripped" outcome reports (e.g. a short trailing unterminated
    // quote in the short-hostile-input corpus) — treating that as a
    // "bound tripped" signal is precisely the over-broad detection this
    // finding flagged.
    let trippedAGenuineBound = rows.contains { row in
        switch row {
        case .oversizedRecord:
            return true
        case .unterminatedQuoteConsumedRemainder(let approxRowsLost):
            return approxRowsLost > 0
        default:
            return false
        }
    }
    return (rows, trippedAGenuineBound)
}

/// Builds one hostile CSV blob deliberately shaped to exercise code paths
/// a short-random-character fuzz corpus can't reach: quoted runs long
/// enough to sometimes cross `CSVTokenizer.maxFieldLength`, embedded
/// terminators inside them, and an escaped-quote pair placed immediately
/// after the bulk content — including, roughly a third of the time,
/// landing right at the size boundary (mirroring finding 1.1's exact
/// reviewer scenario, where an escaped quote's append is what trips the
/// bound). `String(repeating:)` for the bulk run keeps this fast even at
/// field-bound scale, unlike a character-by-character random walk.
///
/// - Parameter guaranteeOversizedField: When `true`, the first row's field
///   size is NOT left to the probabilistic branch below (whose range can,
///   for some RNG draws, land just under `maxFieldLength` and never trip
///   anything) — it's forced to deterministically exceed the bound
///   (round-4 finding 6.1-follow-up: the corpus must GUARANTEE a genuine
///   trip, not just make one likely).
private func generateQuotedHeavyHostileCSV(using rng: inout SplitMix64, guaranteeOversizedField: Bool) -> String {
    var lines = ["header"]
    let rowCount = 2 + Int(rng.next() % 3) // 2-4 rows
    for rowIndex in 0..<rowCount {
        let forceOversized = guaranteeOversizedField && rowIndex == 0
        let makeHuge = forceOversized || rng.next() % 3 == 0
        let bulkLength: Int
        if forceOversized {
            bulkLength = CSVTokenizer.maxFieldLength + 100 // unambiguously over the bound
        } else if makeHuge {
            bulkLength = CSVTokenizer.maxFieldLength - 20 + Int(rng.next() % 64) // straddles the field bound
        } else {
            bulkLength = 4 + Int(rng.next() % 40)
        }
        var content = String(repeating: "x", count: bulkLength)
        // A few embedded terminators plus an escaped-quote pair right at
        // the end of the bulk run.
        content += "\n\r\"\"more"
        let closesProperly = rng.next() % 4 != 0
        let field = closesProperly ? "\"\(content)\"" : "\"\(content)"
        lines.append(field + ",field2")
    }
    return lines.joined(separator: "\n") + "\n"
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
