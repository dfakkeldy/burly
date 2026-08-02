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
//                    the field, and — per this round's finding — only a
//                    separator/CR/LF/CRLF/EOF may legally follow a closing
//                    quote (`,` commits the field; a terminator ends the
//                    record). Anything else is content silently glued onto
//                    the string, e.g. `"Bench Press (Barbell)"junk` —
//                    malformed CSV, not a value ending in "...)junk".
//   recordError    — the record is already known malformed (sticky reason
//                    recorded once). No further grammar is interpreted:
//                    every scalar is skipped until the next terminator,
//                    which ends the malformed record and resynchronizes at
//                    fieldStart for whatever comes next. Every malformed
//                    condition below funnels into this one state, so
//                    "resynchronize at the next record terminator" is a
//                    single code path instead of N ad-hoc patches.
//
// RECORD-LOCAL RECOVERY (finding: quote-state recovery was not row-local).
// The old design kept treating scalars as "inside quotes" — swallowing
// every CR/LF as literal content — for as long as no closing quote turned
// up, which let one missing close quote consume arbitrarily many
// subsequent physical rows, or let a LATER unrelated quote wrongly close
// the field and merge rows together. `recordError` fixes this at the
// root: the instant a record is known malformed, quote semantics stop
// applying to it entirely, and the very next terminator — full stop —
// ends that record. What still needs a bound is *how long* the tokenizer
// is willing to keep believing a quoted field is legitimately multi-line
// before giving up on it ever closing: `maxEmbeddedTerminatorsPerRecord`
// below is exactly that bound (generous for a real multi-paragraph note;
// small enough that a genuinely broken quote can only ever swallow a
// bounded, fixed number of physical lines, never "the rest of the file").
//
// BOUNDED EVERYTHING. Four independent, named bounds, each reported as
// `.oversizedRecord(OversizedRecordLimit)` (three of them) or
// `.unterminatedQuote` (the fourth), all resynchronizing via the
// `recordError` mechanism above:
//   - maxFieldLength                  — one field's own size (pre-existing).
//   - maxRecordLength                 — total content across every field in
//                                        one record (many large-but-legal
//                                        fields adding up).
//   - maxFieldsPerRecord              — number of fields/commas in one
//                                        record (millions of empty
//                                        comma-separated fields).
//   - maxEmbeddedTerminatorsPerRecord — CR/LF absorbed as literal content
//                                        inside a still-open quote before
//                                        the tokenizer gives up waiting for
//                                        it to close (the runaway-quote
//                                        guard described above).
enum CSVTokenizer {
    /// One physical/logical CSV record as tokenized, or why it couldn't be
    /// turned into one. A malformed case still represents forward
    /// progress: the tokenizer always resynchronizes at the next record
    /// boundary (see `recordError` in the file doc) and keeps scanning the
    /// rest of the file.
    enum Row: Equatable {
        /// A structurally well-formed record's raw fields.
        case fields([String])
        /// A genuinely blank physical record — no characters at all before
        /// the next line break (finding 1.7). Reported rather than
        /// vanishing silently, so a caller can count it instead of
        /// row-numbering drifting around it.
        case blank
        /// The record's last field was still inside an open quote when
        /// scanning ended — either at true end-of-file, or because
        /// `maxEmbeddedTerminatorsPerRecord` was exceeded while quoted
        /// (the runaway-quote guard — see file doc).
        case unterminatedQuote
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
        /// section was exceeded. Carries which bound and its value so a
        /// caller can report specifics instead of a generic "too big".
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
    /// need while still being a fixed, finite number.
    static let maxFieldsPerRecord = 4096

    /// Bounds how many raw CR/LF terminators a single still-open quoted
    /// field will be believed to legitimately embed (see file doc,
    /// "RECORD-LOCAL RECOVERY") before the tokenizer stops waiting for a
    /// closing quote that may never come and reports `.unterminatedQuote`
    /// instead. Far more line breaks than any real multi-paragraph workout
    /// note would plausibly contain, while still bounding the worst case
    /// — a missing close quote mid-file — to a small, fixed number of
    /// swallowed physical rows instead of the rest of the file (round-2
    /// blocker: "quote-state recovery is not record-local").
    static let maxEmbeddedTerminatorsPerRecord = 32

    /// Explicit tokenizer states — see the file-level "STATE MACHINE" doc
    /// for what each one means and how they connect.
    private enum State {
        case fieldStart
        case unquotedField
        case quotedField
        case quoteSeen
        case recordError
    }

    /// Splits `text` into logical records (see `Row` above).
    static func rows(in text: String) -> [Row] {
        let scalars = Array(text.unicodeScalars)
        var result: [Row] = []

        var state: State = .fieldStart
        var fields: [String] = []
        var field = String.UnicodeScalarView()
        var fieldLength = 0
        var recordScalarCount = 0
        var fieldCount = 0
        var embeddedTerminatorCount = 0
        var rowHasContent = false
        /// Sticky reason for the record currently being scanned, once one
        /// is found. The first problem found for a record wins; a record
        /// isn't reported as more than one kind of malformed.
        var rowMalformedReason: Row?
        var i = 0

        func markMalformed(_ reason: Row) {
            if rowMalformedReason == nil {
                rowMalformedReason = reason
            }
        }

        /// Records `reason` (sticky — see `markMalformed`) and switches
        /// the whole record into `recordError`: from this point on, no
        /// more CSV grammar is interpreted for this record — every scalar
        /// is skipped until the next terminator ends it. This is the one
        /// place every malformed condition in this tokenizer funnels
        /// through, which is what makes "resynchronize at the next record
        /// terminator" a single mechanism instead of N separate patches.
        func enterRecordError(_ reason: Row) {
            markMalformed(reason)
            state = .recordError
        }

        /// Appends `c` to the current field, enforcing both the per-field
        /// bound (finding 1.5) and the per-record total bound (round-2
        /// finding) before growing any buffer. Once either bound is
        /// exceeded the record enters `recordError`; this scalar is
        /// simply dropped rather than the buffer growing further.
        func appendToField(_ c: Unicode.Scalar) {
            recordScalarCount += 1
            guard recordScalarCount <= maxRecordLength else {
                enterRecordError(.oversizedRecord(.recordLength(maxRecordLength)))
                return
            }
            guard fieldLength < maxFieldLength else {
                enterRecordError(.oversizedRecord(.fieldLength(maxFieldLength)))
                return
            }
            field.append(c)
            fieldLength += 1
        }

        /// Commits the current field buffer as done and starts the next
        /// one, enforcing the per-record field-count bound (round-2
        /// finding).
        func startNewField() {
            fields.append(String(field))
            field = String.UnicodeScalarView()
            fieldLength = 0
            fieldCount += 1
            guard fieldCount <= maxFieldsPerRecord else {
                enterRecordError(.oversizedRecord(.fieldCount(maxFieldsPerRecord)))
                return
            }
        }

        /// A `,` outside of quotes always means the same thing regardless
        /// of which non-quoted state it's seen from (fieldStart,
        /// unquotedField, or quoteSeen immediately after a closing quote):
        /// commit the field just finished and go back to fieldStart for
        /// the next one — unless `startNewField` just tipped the record
        /// into `recordError`, in which case that takeover must not be
        /// overwritten back to fieldStart.
        func handleComma() {
            startNewField()
            rowHasContent = true
            if state != .recordError {
                state = .fieldStart
            }
        }

        /// Ends the record at a definite, just-crossed terminator (a `\n`
        /// or a terminating bare `\r`) — always emits a `Row`, since
        /// crossing a real terminator always means *some* record just
        /// ended, even a blank one (finding 1.7). Resets every piece of
        /// per-record state, including back to `fieldStart`, so the next
        /// scalar starts a fresh record.
        func endRow() {
            defer {
                fields = []
                field = String.UnicodeScalarView()
                fieldLength = 0
                recordScalarCount = 0
                fieldCount = 0
                embeddedTerminatorCount = 0
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
        /// scan mid-malformed (e.g. an unterminated quote).
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

        while i < scalars.count {
            switch state {
            case .recordError:
                // The record is already known malformed: no more CSV
                // grammar applies to it. Every scalar is skipped until the
                // next terminator ends it right here — this is what
                // guarantees a missing close quote (or any other malformed
                // condition) can never swallow more than the bounded
                // amount of content that got it into this state before the
                // very next terminator resynchronizes.
                if let termLen = terminatorLength(at: i) {
                    endRow()
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
                        appendToField(c)
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
                        // invitation to open quoted mode mid-field.
                        enterRecordError(.strayQuote)
                        i += 1
                    case ",":
                        handleComma()
                        i += 1
                    default:
                        appendToField(c)
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
                } else if c == "\r" || c == "\n" {
                    // A bare CR or LF inside a quoted field is ordinary
                    // literal content (a legitimately multi-line field),
                    // not a record terminator — up to the bound below.
                    embeddedTerminatorCount += 1
                    if embeddedTerminatorCount > maxEmbeddedTerminatorsPerRecord {
                        // The runaway-quote guard (see file doc): this
                        // field has now absorbed more embedded line breaks
                        // than any legitimate content plausibly would.
                        // Stop believing a closing quote is coming and
                        // resynchronize instead of risking swallowing the
                        // rest of the file.
                        enterRecordError(.unterminatedQuote)
                    } else {
                        appendToField(c)
                    }
                    i += 1
                } else {
                    appendToField(c)
                    i += 1
                }

            case .quoteSeen:
                if let termLen = terminatorLength(at: i) {
                    // Legal: a terminator is one of the transitions this
                    // round's finding requires after a closing quote.
                    endRow()
                    i += termLen
                } else {
                    let c = scalars[i]
                    switch c {
                    case "\"":
                        // The pair was an escaped literal quote, not a
                        // close — resume accumulating the quoted field.
                        appendToField("\"")
                        state = .quotedField
                        i += 1
                    case ",":
                        // Legal: the other transition this round's finding
                        // requires after a closing quote.
                        handleComma()
                        i += 1
                    default:
                        // Round-2 new defect #1: anything else glued onto
                        // a just-closed quote (e.g. `"a"junk`) is malformed
                        // CSV, not content silently appended to the value.
                        enterRecordError(.contentAfterClosingQuote)
                        i += 1
                    }
                }
            }
        }

        // End of input. `quotedField` with nothing left to read is a true
        // unterminated quote (finding 1.3). `quoteSeen` at EOF is legal —
        // EOF is one of the transitions allowed right after a closing
        // quote — so it falls through to the ordinary flush below exactly
        // like reaching a real terminator would.
        if state == .quotedField {
            markMalformed(.unterminatedQuote)
        }
        flushFinalRowIfNeeded()

        return result
    }
}
