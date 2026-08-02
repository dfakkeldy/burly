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
// raw CSV syntax is broken (unterminated quote, a stray quote mid-field, a
// pathologically oversized field/record) — see `Row` below — rather than
// blindly flushing whatever it absorbed as if it were legitimate data.
// Turning a well-formed row's fields into validated domain data — including
// deciding a row's column count is wrong — remains `HevyCSVImporter`'s job,
// not this file's.
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
    /// One physical/logical CSV record as tokenized, or why it couldn't be
    /// turned into one. A malformed case still represents forward
    /// progress: the tokenizer always resynchronizes at the next record
    /// boundary and keeps scanning the rest of the file.
    enum Row: Equatable {
        /// A structurally well-formed record's raw fields.
        case fields([String])
        /// A genuinely blank physical record — no characters at all before
        /// the next line break (finding 1.7). Reported rather than
        /// vanishing silently, so a caller can count it instead of
        /// row-numbering drifting around it.
        case blank
        /// The record's last field was still inside an open quote when
        /// scanning ended — either at true end-of-file, or because the
        /// field grew past `maxFieldLength` while quoted (finding 1.3).
        case unterminatedQuote
        /// A `"` appeared outside of quoted mode after the current field
        /// had already started (i.e. anywhere but as the very first
        /// character of a field) — e.g. an unquoted `1"2"` field. Only an
        /// opening quote at the true start of a field is meaningful CSV
        /// syntax; any other appearance is malformed (finding 1.4).
        case strayQuote
        /// A field exceeded `maxFieldLength` scalars before its record
        /// ended. Bounds how large a single buffer this tokenizer will
        /// grow in response to hostile input, such as a multi-hundred-
        /// megabyte quoted field (finding 1.5) — the record is reported
        /// as oversized instead of the tokenizer growing that field's
        /// storage without limit.
        case oversizedRecord
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

    /// Splits `text` into logical records (see `Row` above).
    static func rows(in text: String) -> [Row] {
        let scalars = Array(text.unicodeScalars)
        var result: [Row] = []

        var fields: [String] = []
        var field = String.UnicodeScalarView()
        var fieldLength = 0
        var inQuotes = false
        var rowHasContent = false
        /// True once *any* content — an opening quote or a literal
        /// character — has been consumed for the current field. A `"`
        /// encountered while this is already true is necessarily
        /// mid-field, not field-opening (finding 1.4).
        var fieldStarted = false
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

        /// Appends `c` to the current field, unless the record is already
        /// known malformed (nothing more to preserve) or `c` would push
        /// the field past `maxFieldLength` (finding 1.5) — in which case
        /// the record is marked oversized and the buffer simply stops
        /// growing; scanning continues so the tokenizer can still find the
        /// record's true end and resynchronize for the next record.
        func appendToField(_ c: Unicode.Scalar) {
            guard rowMalformedReason == nil else { return }
            guard fieldLength < maxFieldLength else {
                markMalformed(.oversizedRecord)
                return
            }
            field.append(c)
            fieldLength += 1
        }

        func startNewField() {
            fields.append(String(field))
            field = String.UnicodeScalarView()
            fieldLength = 0
            fieldStarted = false
        }

        /// Ends the record at a definite, just-crossed terminator (a `\n`
        /// or a terminating bare `\r`) — always emits a `Row`, since
        /// crossing a real terminator always means *some* record just
        /// ended, even a blank one (finding 1.7).
        func endRow() {
            defer {
                fields = []
                field = String.UnicodeScalarView()
                fieldLength = 0
                fieldStarted = false
                rowHasContent = false
                rowMalformedReason = nil
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

        while i < scalars.count {
            let c = scalars[i]

            if inQuotes {
                if c == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" {
                        appendToField("\"") // escaped literal quote
                        i += 2
                    } else {
                        inQuotes = false
                        i += 1
                    }
                } else {
                    // Bare CR or LF inside a quoted field is literal
                    // content, not a record terminator — preserved
                    // verbatim here regardless of finding 1.6's outside-
                    // quotes handling below.
                    appendToField(c)
                    i += 1
                }
                continue
            }

            switch c {
            case "\"":
                if fieldStarted {
                    // A quote appearing anywhere but the true start of a
                    // field is malformed CSV syntax (finding 1.4), not an
                    // invitation to open quoted mode mid-field.
                    markMalformed(.strayQuote)
                    i += 1
                } else {
                    inQuotes = true
                    fieldStarted = true
                    rowHasContent = true
                    i += 1
                }
            case ",":
                startNewField()
                rowHasContent = true
                i += 1
            case "\r":
                // Finding 1.6: a bare CR is itself a record terminator.
                // Only when it's the first half of a CRLF pair do we defer
                // to the following "\n" case to end the row, so CRLF still
                // counts as exactly one terminator.
                if i + 1 < scalars.count, scalars[i + 1] == "\n" {
                    i += 1
                } else {
                    endRow()
                    i += 1
                }
            case "\n":
                endRow()
                i += 1
            default:
                fieldStarted = true
                rowHasContent = true
                appendToField(c)
                i += 1
            }
        }

        // End of input. An unterminated quote (finding 1.3) means the
        // scan fell out of the loop still inside a quoted field — that
        // record is reported as malformed rather than flushing whatever
        // it absorbed as if it were a real, complete value.
        if inQuotes {
            markMalformed(.unterminatedQuote)
        }
        flushFinalRowIfNeeded()

        return result
    }
}
