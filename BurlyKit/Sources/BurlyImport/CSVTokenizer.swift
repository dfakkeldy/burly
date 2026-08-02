// SPDX-License-Identifier: GPL-3.0-or-later
// BurlyImport — CSVTokenizer
//
// Hand-rolled RFC-4180-ish tokenizer: no third-party CSV library, per the
// task's constraint that the input format is fixed and known. Splits raw
// CSV text into rows of raw string fields. A field wrapped in double quotes
// may contain commas, newlines, and `""` as an escaped literal quote — the
// same shape `BurlyFixtures.HevyCSVGenerator` produces on the way out.
//
// This is a pure tokenizer: it never throws and never crashes on hostile
// input. It DOES, however, distinguish a well-formed record from one whose
// raw CSV syntax is broken (unterminated quote, a stray quote mid-field, an
// illegal transition, a pathologically oversized field/record/field-count)
// — see `Row` below — rather than blindly flushing whatever it absorbed as
// if it were legitimate data. Turning a well-formed row's fields into
// validated domain data — including deciding a row's column count is wrong
// — remains `HevyCSVImporter`'s job, not this file's.
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
// `Unicode.Scalar` alone. `OversizedRecordLimit` is a plain Swift enum
// defined in HevyImportTypes.swift (same target); referencing it here adds
// no Foundation/BurlyCore dependency.
//
// ---------------------------------------------------------------------
// STATE MACHINE (m7-01 review round 2: "the hand-rolled tokenizer state
// machine has accreted patches — redesign it cleanly rather than patching
// again"). Explicit states, one unconditional dispatch per scalar:
//
//   fieldStart     — the first scalar of a field has not been seen yet.
//                    `"` opens a quoted field; `,` commits an empty field
//                    and stays in fieldStart for the next one; a
//                    terminator ends the record (possibly as `.blank`);
//                    anything else starts an unquoted field.
//   unquotedField  — accumulating an unquoted field's content. `,` commits
//                    the field; a terminator ends the record; `"` here is
//                    a stray quote (finding 1.4) — malformed CSV, not an
//                    invitation to open quoted mode mid-field.
//   quotedField    — inside an open quote. CR/LF here are literal content
//                    (a legitimately multi-line quoted field), not a
//                    terminator. `"` transitions to quoteSeen to decide
//                    whether it's an escaped literal quote or the field's
//                    real close.
//   quoteSeen      — a `"` was just seen while quoted; look at the very
//                    next scalar to decide. Another `"` means the pair was
//                    an escaped literal quote (back to quotedField).
//                    Anything else means the first `"` really did close
//                    the field, and — per m7-01 round 2 — only a
//                    separator/CR/LF/CRLF/EOF may legally follow a closing
//                    quote (`,` commits the field; a terminator ends the
//                    record). Anything else is content silently glued onto
//                    the string, e.g. `"Bench Press (Barbell)"junk` —
//                    malformed CSV, not a value ending in "...)junk".
//   recordError    — the record is already known malformed FOR A REASON
//                    DISCOVERED OUTSIDE ANY OPEN QUOTE (sticky reason
//                    recorded once). No further grammar is interpreted:
//                    every scalar is skipped until the next terminator,
//                    which ends the malformed record and resynchronizes at
//                    fieldStart for whatever comes next. Safe to
//                    resynchronize here — see the FAILURE-MODE TABLE below
//                    for exactly why this is trustworthy only in unquoted
//                    context.
//   consumeToEOF   — a failure was discovered WHILE INSIDE AN OPEN QUOTE.
//                    Per m7-01 round 3, resynchronizing here is NOT
//                    trustworthy (see FAILURE-MODE TABLE) — every scalar
//                    for the rest of the file is skipped without buffering
//                    (bounded memory) and never reinterpreted as CSV
//                    structure again, so nothing after this point can ever
//                    import as data. The number of terminators skipped is
//                    counted as an honest "approximately this many rows
//                    were lost" figure, reported once, at true EOF, as a
//                    single `.unterminatedQuoteConsumedRemainder`.
//
// FAILURE-MODE TABLE (m7-01 round 3 adjudication 1). The round-2 design
// bounded how many embedded line breaks a still-open quote could absorb
// before giving up and resynchronizing at the next terminator
// (`maxEmbeddedTerminatorsPerRecord`). The round-3 review proved this is
// an INJECTION VECTOR, not a safety net: Hevy notes are free-form, so a
// perfectly legitimate 17-line quoted note can exceed any fixed bound,
// get resynced MID-CONTENT, and have one of its own note lines misread as
// a fabricated workout record — silent row-boundary corruption, which is
// worse than the data loss it was meant to prevent. The bound is REMOVED,
// not retuned; there is no number of embedded terminators inside an open
// quote that's safe to resynchronize on, because a still-open quote means
// the tokenizer no longer reliably knows where a "row" begins or ends.
// Resynchronizing outside of quotes has no such problem: a comma, a
// closing-quote transition, or a terminator seen OUTSIDE any open quote is
// unambiguous CSV structure regardless of what came before it.
//
//   Failure                                      | Context  | Recovery
//   ----------------------------------------------|----------|------------------
//   stray quote (finding 1.4)                     | unquoted | recordError (resync at next terminator)
//   content after closing quote (round 2 defect)  | unquoted*| recordError (resync at next terminator)
//   field-count bound exceeded                    | unquoted | recordError (resync at next terminator)
//   field-length bound exceeded                   | unquoted | recordError (resync at next terminator)
//   record-length bound exceeded                  | unquoted | recordError (resync at next terminator)
//   field-length bound exceeded                   | quoted   | consumeToEOF (no resync — see above)
//   record-length bound exceeded                  | quoted   | consumeToEOF (no resync — see above)
//   unterminated quote at true EOF (finding 1.3)  | quoted   | consumeToEOF (trivially 0 rows lost — EOF already reached)
//
//   * `quoteSeen` (right after a closing quote) counts as unquoted context
//     for this table: the quote has already closed, so what follows is
//     ordinary top-level CSV structure, not quoted content — resync there
//     is exactly as trustworthy as anywhere else outside a quote. The one
//     EXCEPTION is the escaped-quote pair (`""`): appending its literal
//     `"` is quoted-content by nature, so a bound tripping on THAT specific
//     append still routes to `consumeToEOF`, not `recordError` (m7-01
//     round 3 finding 1.1 — see `appendToField`'s `insideQuotedContent`).
//
// BOUNDED EVERYTHING. Three independent, named bounds, each reported as
// `.oversizedRecord(OversizedRecordLimit)` when tripped outside a quote, or
// folded into `.unterminatedQuoteConsumedRemainder` when tripped inside
// one (see table above):
//   - maxFieldLength   — one field's own size (pre-existing, finding 1.5).
//   - maxRecordLength  — total content across every field in one record
//                        (many large-but-legal fields adding up).
//   - maxFieldsPerRecord — number of fields/commas in one record (millions
//                        of empty comma-separated fields).
// Bounded memory is preserved even in `consumeToEOF`: nothing is buffered
// for the remainder of the file, only a terminator count.
enum CSVTokenizer {
    /// One physical/logical CSV record as tokenized, or why it couldn't be
    /// turned into one. A malformed case still represents forward
    /// progress: the tokenizer always keeps scanning to the end of the
    /// input (see the file's FAILURE-MODE TABLE for exactly what "forward
    /// progress" means for each failure — trustworthy resynchronization
    /// outside quotes; a single honest "rest of the file is lost" report
    /// inside one).
    enum Row: Equatable {
        /// A structurally well-formed record's raw fields.
        case fields([String])
        /// A genuinely blank physical record — no characters at all before
        /// the next line break (finding 1.7). Reported rather than
        /// vanishing silently, so a caller can count it instead of
        /// row-numbering drifting around it.
        case blank
        /// A failure was discovered while a quote was still open — either
        /// the file ended with the quote never closed (finding 1.3), or a
        /// field/record size bound tripped on content that was inside that
        /// open quote (m7-01 round 3 finding: resynchronizing here is not
        /// safe — see the file's FAILURE-MODE TABLE). Everything from the
        /// point of failure to the true end of the file is consumed
        /// without buffering and reported as ONE malformed record, never
        /// reinterpreted as CSV structure again. `approxRowsLost` counts
        /// the terminators skipped while consuming that remainder — an
        /// honest, approximate "this many physical rows are gone" figure
        /// (0 when the failure was discovered exactly at EOF, with nothing
        /// left to skip).
        case unterminatedQuoteConsumedRemainder(approxRowsLost: Int)
        /// A `"` appeared outside of quoted mode after the current field
        /// had already started (i.e. anywhere but as the very first
        /// character of a field) — e.g. an unquoted `1"2"` field. Only an
        /// opening quote at the true start of a field is meaningful CSV
        /// syntax; any other appearance is malformed (finding 1.4).
        case strayQuote
        /// A closing quote was immediately followed by something other
        /// than a separator/CR/LF/CRLF/EOF — e.g. `"a"junk`. Only the
        /// value up to the closing quote is meaningful CSV syntax; content
        /// glued on after it is malformed, not silently concatenated (m7-01
        /// review round 2, "new defect" #1).
        case contentAfterClosingQuote
        /// One of the bounds documented in the file's "BOUNDED EVERYTHING"
        /// section was exceeded OUTSIDE any open quote. Carries which
        /// bound and its value so a caller can report specifics instead of
        /// a generic "too big". (The same bounds tripped INSIDE an open
        /// quote report `.unterminatedQuoteConsumedRemainder` instead —
        /// see the file's FAILURE-MODE TABLE.)
        case oversizedRecord(OversizedRecordLimit)
    }

    /// Per-field size bound (finding 1.5). Comfortably larger than any
    /// legitimate CSV field Burly's schema reads (the longest is free-text
    /// notes), while bounding how large the `field`/`String` buffer below
    /// is allowed to grow for one field in response to hostile input. This
    /// does not bound the single up-front `Array(text.unicodeScalars)`
    /// copy of the whole file — that copy is proportional to the input's
    /// own size, not to a single field's pathological growth, which is the
    /// specific amplification finding 1.5 is about; fully streaming the
    /// tokenizer to avoid even that copy was judged out of scope for this
    /// fix (see task handoff).
    static let maxFieldLength = 1 << 20 // 1,048,576 scalars (~1 MiB of ASCII)

    /// Total content bound across every field of one record combined
    /// (round-2 finding: field bounding alone doesn't stop "many
    /// individually sub-limit fields" from growing memory without limit).
    /// Four times `maxFieldLength` — generous enough that one legitimately
    /// huge single note field (up to the field bound on its own) plus
    /// Burly's dozen-or-so short numeric/date columns never comes close,
    /// while still bounding a hostile record's total footprint.
    static let maxRecordLength = maxFieldLength * 4

    /// Number of fields (commas) a single record may contain (round-2
    /// finding: no bound at all previously let a record of millions of
    /// empty comma-separated fields grow `fields` without limit). Hevy's
    /// real and fixture-generated schemas both use on the order of a dozen
    /// columns; this is generously larger than any legitimate header could
    /// need while still being a fixed, finite number. Exactly this many
    /// fields is legal; one more trips `.oversizedRecord(.fieldCount(_))`
    /// (m7-01 round 3 finding 3.2 — the round-2 boundary was off by one,
    /// silently allowing `maxFieldsPerRecord + 1`).
    static let maxFieldsPerRecord = 4096

    /// Explicit tokenizer states — see the file-level "STATE MACHINE" and
    /// "FAILURE-MODE TABLE" docs for what each one means, how they
    /// connect, and — critically for `consumeToEOF` — why resynchronizing
    /// is only trustworthy in some of them.
    private enum State {
        case fieldStart
        case unquotedField
        case quotedField
        case quoteSeen
        case recordError
        case consumeToEOF
    }

    /// Splits `text` into logical records (see `Row` above). Thin wrapper
    /// over `scan`, discarding the diagnostics `rowsWithDiagnostics` below
    /// uses — production callers pay no extra cost for a feature only
    /// tests need.
    static func rows(in text: String) -> [Row] {
        scan(text).rows
    }

    /// Test/diagnostic-only entry point (m7-01 round 3 finding 6.1: the
    /// adversarial fuzz test needs to PROVE properties, not just fail to
    /// crash). Exposes, for each main-loop iteration, the exact
    /// half-open range of scalar indices that iteration consumed —
    /// letting a caller mechanically verify the tokenizer reads the ENTIRE
    /// input exactly once, front to back, with no gap, no overlap, and no
    /// double-read (rather than trusting that by inspection). Also accepts
    /// an explicit `iterationBudget`: if the scan would take more
    /// iterations than that, it stops and reports
    /// `iterationBudgetExceeded: true` instead of continuing — a
    /// deterministic way to prove termination that doesn't depend on the
    /// test harness's wall-clock timeout ever firing (by construction, a
    /// correct scan takes at most one iteration per input scalar, so any
    /// budget at or above `scalars.count` is generous for a correct
    /// implementation and tight enough to catch a stuck one quickly).
    static func rowsWithDiagnostics(
        in text: String,
        iterationBudget: Int? = nil
    ) -> (rows: [Row], steps: [Range<Int>], iterationBudgetExceeded: Bool) {
        var steps: [Range<Int>] = []
        let result = scan(text, recordStep: { steps.append($0) }, iterationBudget: iterationBudget)
        return (result.rows, steps, result.iterationBudgetExceeded)
    }

    /// Shared scanning core behind both entry points above.
    ///
    /// - Parameter recordStep: Called once per main-loop iteration with the
    ///   half-open range of scalar indices that iteration consumed, in
    ///   scan order. `nil` (the default, used by `rows(in:)`) skips this
    ///   entirely — no array, no per-iteration closure call — so the
    ///   production path pays nothing for a testing-only feature.
    /// - Parameter iterationBudget: See `rowsWithDiagnostics` above. `nil`
    ///   (the default, used by `rows(in:)`) means unbounded, matching this
    ///   tokenizer's unconditional "never crashes, never hangs" contract in
    ///   production — the budget is a TEST instrument for proving that
    ///   contract, not a production safety net that could truncate a real
    ///   import.
    private static func scan(
        _ text: String,
        recordStep: ((Range<Int>) -> Void)? = nil,
        iterationBudget: Int? = nil
    ) -> (rows: [Row], iterationBudgetExceeded: Bool) {
        let scalars = Array(text.unicodeScalars)
        var result: [Row] = []

        var state: State = .fieldStart
        var fields: [String] = []
        var field = String.UnicodeScalarView()
        var fieldLength = 0
        var recordScalarCount = 0
        var fieldCount = 0
        var rowHasContent = false
        /// Sticky reason for the record currently being scanned, once one
        /// is found (only ever set for `recordError` — `consumeToEOF`
        /// doesn't use this, since it always reports the same case at true
        /// EOF with a computed rows-lost count). The first problem found
        /// for a record wins; a record isn't reported as more than one
        /// kind of malformed.
        var rowMalformedReason: Row?
        /// Terminators skipped while in `consumeToEOF` — the honest
        /// "approximately this many rows were lost" count reported once,
        /// at true EOF, in `.unterminatedQuoteConsumedRemainder`.
        var consumeToEOFTerminatorCount = 0
        var i = 0

        func markMalformed(_ reason: Row) {
            if rowMalformedReason == nil {
                rowMalformedReason = reason
            }
        }

        /// Records `reason` (sticky — see `markMalformed`) and switches
        /// the record into `recordError`: from this point on, no more CSV
        /// grammar is interpreted for THIS record — every scalar is
        /// skipped until the next terminator ends it and resynchronizes at
        /// `fieldStart`. Only for failures discovered OUTSIDE an open
        /// quote (see the file's FAILURE-MODE TABLE) — quoted-context
        /// failures call `enterConsumeToEOF()` instead. Callers must never
        /// unconditionally reassign `state` after calling this (m7-01
        /// round 3 finding 1.1: an unconditional reassignment right after
        /// this call silently clobbered the error transition) — every call
        /// site below either has nothing after it, or explicitly checks
        /// `state` before touching it again.
        func enterRecordError(_ reason: Row) {
            markMalformed(reason)
            state = .recordError
        }

        /// Switches the record into `consumeToEOF`: a failure was
        /// discovered while a quote was still open, so — per the file's
        /// FAILURE-MODE TABLE — no resynchronization is attempted.
        /// Everything from here to the true end of the file is skipped
        /// without buffering. Same clobber caveat as `enterRecordError`
        /// above applies to every call site.
        func enterConsumeToEOF() {
            state = .consumeToEOF
        }

        /// Appends `c` to the current field, enforcing both the per-field
        /// bound (finding 1.5) and the per-record total bound (round-2
        /// finding) before growing any buffer. `insideQuotedContent`
        /// decides which recovery a tripped bound gets (see FAILURE-MODE
        /// TABLE): content inside an open quote (including the literal
        /// `"` from an escaped-quote pair) can only safely give up on the
        /// rest of the file; unquoted content can safely resynchronize at
        /// the next terminator. Either way this scalar is simply dropped
        /// rather than the buffer growing further.
        func appendToField(_ c: Unicode.Scalar, insideQuotedContent: Bool) {
            recordScalarCount += 1
            guard recordScalarCount <= maxRecordLength else {
                if insideQuotedContent {
                    enterConsumeToEOF()
                } else {
                    enterRecordError(.oversizedRecord(.recordLength(maxRecordLength)))
                }
                return
            }
            guard fieldLength < maxFieldLength else {
                if insideQuotedContent {
                    enterConsumeToEOF()
                } else {
                    enterRecordError(.oversizedRecord(.fieldLength(maxFieldLength)))
                }
                return
            }
            field.append(c)
            fieldLength += 1
        }

        /// Commits the current field buffer as done and starts the next
        /// one, enforcing the per-record field-count bound (round-2
        /// finding; round-3 finding 3.2 fixed the off-by-one). Only ever
        /// called from a comma seen OUTSIDE quotes (a comma inside a quote
        /// is literal field content, handled by `appendToField` instead),
        /// so a tripped bound here always resynchronizes via
        /// `enterRecordError` — never `enterConsumeToEOF`.
        func startNewField() {
            fields.append(String(field))
            field = String.UnicodeScalarView()
            fieldLength = 0
            fieldCount += 1
            guard fieldCount < maxFieldsPerRecord else {
                enterRecordError(.oversizedRecord(.fieldCount(maxFieldsPerRecord)))
                return
            }
        }

        /// A `,` outside of quotes always means the same thing regardless
        /// of which non-quoted state it's seen from (fieldStart,
        /// unquotedField, or quoteSeen immediately after a closing quote):
        /// commit the field just finished and go back to fieldStart for
        /// the next one — unless `startNewField` just tipped the record
        /// into an error state, in which case that takeover must not be
        /// overwritten (m7-01 round 3 finding 1.1's "guard every
        /// assignment" — `startNewField` can only ever reach
        /// `.recordError`, never `.consumeToEOF`, but this checks both
        /// defensively rather than relying on that staying true forever).
        func handleComma() {
            startNewField()
            rowHasContent = true
            if state != .recordError && state != .consumeToEOF {
                state = .fieldStart
            }
        }

        /// Ends the record at a definite, just-crossed terminator (a `\n`
        /// or a terminating bare `\r`) — always emits a `Row`, since
        /// crossing a real terminator always means *some* record just
        /// ended, even a blank one (finding 1.7). Resets every piece of
        /// per-record state, including back to `fieldStart`, so the next
        /// scalar starts a fresh record. Never called from `consumeToEOF`
        /// — that state ends the whole scan itself, once, after the main
        /// loop (see below).
        func endRow() {
            defer {
                fields = []
                field = String.UnicodeScalarView()
                fieldLength = 0
                recordScalarCount = 0
                fieldCount = 0
                rowHasContent = false
                rowMalformedReason = nil
                state = .fieldStart
            }
            if let reason = rowMalformedReason {
                result.append(reason)
            } else if rowHasContent {
                fields.append(String(field))
                result.append(.fields(fields))
            } else {
                result.append(.blank)
            }
        }

        /// End-of-scan flush, used exactly once after the main loop. Unlike
        /// `endRow()`, this must NOT unconditionally emit a `Row`: if the
        /// file's last character was already a real terminator, nothing is
        /// pending and emitting here would fabricate a phantom trailing
        /// `.blank` record that was never in the file. It only emits when
        /// there's genuinely uncommitted state — a final record with no
        /// trailing newline (`rowHasContent`), or a record that ended the
        /// scan mid-malformed. Never reached from `.quotedField` or
        /// `.consumeToEOF` — those are handled separately right after the
        /// main loop, since neither one goes through `rowMalformedReason`.
        func flushFinalRowIfNeeded() {
            guard rowHasContent || rowMalformedReason != nil else { return }
            endRow()
        }

        /// If `scalars[i]` begins a line terminator — bare CR, bare LF, or
        /// CRLF treated as the one terminator it represents — returns how
        /// many scalars it occupies (1 or 2); otherwise `nil`. Centralizing
        /// this keeps CRLF-as-one-unit handling in exactly one place
        /// shared by every non-quoted state instead of re-deriving it per
        /// call site.
        func terminatorLength(at index: Int) -> Int? {
            guard index < scalars.count else { return nil }
            switch scalars[index] {
            case "\n":
                return 1
            case "\r":
                return (index + 1 < scalars.count && scalars[index + 1] == "\n") ? 2 : 1
            default:
                return nil
            }
        }

        var iterationCount = 0
        while i < scalars.count {
            if let budget = iterationBudget, iterationCount >= budget {
                return (rows: result, iterationBudgetExceeded: true)
            }
            iterationCount += 1
            let stepStart = i
            defer { recordStep?(stepStart..<i) }

            switch state {
            case .recordError:
                // The record is already known malformed for a reason
                // discovered OUTSIDE any open quote: no more CSV grammar
                // applies to it. Every scalar is skipped until the next
                // terminator ends it right here — trustworthy because
                // nothing about this recovery depends on quote state (see
                // FAILURE-MODE TABLE).
                if let termLen = terminatorLength(at: i) {
                    endRow()
                    i += termLen
                } else {
                    i += 1
                }

            case .consumeToEOF:
                // A failure was discovered INSIDE an open quote (m7-01
                // round 3 adjudication): resynchronizing here is not safe
                // at any bound, so no more CSV grammar is EVER interpreted
                // again for the rest of this file. Every scalar is skipped
                // without buffering; only terminators are counted, for an
                // honest approximate rows-lost report emitted once at true
                // EOF (see below, after the loop).
                if let termLen = terminatorLength(at: i) {
                    consumeToEOFTerminatorCount += 1
                    i += termLen
                } else {
                    i += 1
                }

            case .fieldStart:
                if let termLen = terminatorLength(at: i) {
                    endRow()
                    i += termLen
                } else {
                    let c = scalars[i]
                    switch c {
                    case "\"":
                        state = .quotedField
                        rowHasContent = true
                        i += 1
                    case ",":
                        handleComma()
                        i += 1
                    default:
                        state = .unquotedField
                        rowHasContent = true
                        appendToField(c, insideQuotedContent: false)
                        i += 1
                    }
                }

            case .unquotedField:
                if let termLen = terminatorLength(at: i) {
                    endRow()
                    i += termLen
                } else {
                    let c = scalars[i]
                    switch c {
                    case "\"":
                        // Finding 1.4: a quote anywhere but the true start
                        // of a field is malformed CSV syntax, not an
                        // invitation to open quoted mode mid-field. This is
                        // unquoted context — safe to resynchronize.
                        enterRecordError(.strayQuote)
                        i += 1
                    case ",":
                        handleComma()
                        i += 1
                    default:
                        appendToField(c, insideQuotedContent: false)
                        i += 1
                    }
                }

            case .quotedField:
                let c = scalars[i]
                if c == "\"" {
                    // Ambiguous until the next scalar: an escaped literal
                    // quote (`""`) or the field's real closing quote.
                    // `quoteSeen` decides.
                    state = .quoteSeen
                    i += 1
                } else {
                    // A bare CR or LF inside a quoted field is ordinary
                    // literal content (a legitimately multi-line field),
                    // not a record terminator — and, per m7-01 round 3,
                    // NOT bounded by a separate "how many embedded
                    // terminators" count either (that bound was proven to
                    // be an injection vector: it could resync mid-note and
                    // misread a note line as a fabricated row). CR/LF and
                    // every other character here are bounded only by the
                    // field/record size bounds inside `appendToField`,
                    // which route a trip here to `consumeToEOF` — see
                    // FAILURE-MODE TABLE.
                    appendToField(c, insideQuotedContent: true)
                    i += 1
                }

            case .quoteSeen:
                if let termLen = terminatorLength(at: i) {
                    // Legal: a terminator is one of the transitions m7-01
                    // round 2 requires after a closing quote. Unquoted
                    // context (the quote already closed) — safe to end the
                    // record normally here.
                    endRow()
                    i += termLen
                } else {
                    let c = scalars[i]
                    switch c {
                    case "\"":
                        // The pair was an escaped literal quote, not a
                        // close — resume accumulating the quoted field.
                        // This append IS quoted content (the escaped `"`
                        // itself), so a bound tripping here must route to
                        // `consumeToEOF`, not `recordError` — m7-01 round 3
                        // finding 1.1 pins exactly this: the old code
                        // unconditionally reassigned `state = .quotedField`
                        // right after this call, silently clobbering
                        // whichever error state `appendToField` had just
                        // entered. Guarded the same way `handleComma` is.
                        appendToField("\"", insideQuotedContent: true)
                        if state != .recordError && state != .consumeToEOF {
                            state = .quotedField
                        }
                        i += 1
                    case ",":
                        // Legal: the other transition m7-01 round 2
                        // requires after a closing quote. Unquoted context.
                        handleComma()
                        i += 1
                    default:
                        // Round-2 new defect #1: anything else glued onto
                        // a just-closed quote (e.g. `"a"junk`) is malformed
                        // CSV, not content silently appended to the value.
                        // Unquoted context (the quote already closed) —
                        // safe to resynchronize.
                        enterRecordError(.contentAfterClosingQuote)
                        i += 1
                    }
                }
            }
        }

        // End of input. `quotedField`/`consumeToEOF` are handled here
        // instead of `flushFinalRowIfNeeded()`, since neither one goes
        // through `rowMalformedReason` — both always report the same
        // `.unterminatedQuoteConsumedRemainder` case, differing only in
        // how many terminators (if any) were skipped getting here.
        switch state {
        case .quotedField:
            // Ran out of input while genuinely still inside an open quote
            // (finding 1.3), with no bound ever tripped along the way —
            // already at true EOF, so there's nothing further to lose.
            result.append(.unterminatedQuoteConsumedRemainder(approxRowsLost: 0))
        case .consumeToEOF:
            result.append(.unterminatedQuoteConsumedRemainder(approxRowsLost: consumeToEOFTerminatorCount))
        default:
            // `quoteSeen` at EOF is legal (EOF is one of the transitions
            // allowed right after a closing quote) and falls through here
            // exactly like reaching a real terminator would; `fieldStart`/
            // `unquotedField`/`recordError` at EOF are the ordinary
            // trailing-content/malformed-tail cases `flushFinalRowIfNeeded`
            // already handles.
            flushFinalRowIfNeeded()
        }

        return (rows: result, iterationBudgetExceeded: false)
    }
}
