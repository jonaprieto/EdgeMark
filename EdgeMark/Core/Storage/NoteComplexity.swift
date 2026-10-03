import Foundation

/// Decides whether a note is too large or too pathological for the Markdown engine, which
/// styles the whole text on the main thread. A 2 MB single line, 10,000 nested quotes or
/// thousands of formulas froze the app for seconds to minutes; such notes open in a plain
/// text editor instead. Foundation only, so the rules are unit tested by the
/// `EdgeStorageLogic` SPM target.
nonisolated enum NoteComplexity {
    /// Whole text, in UTF-8 bytes.
    static let maxBytes = 400 * 1024
    /// Characters (Unicode scalars) on one line.
    static let maxLineLength = 20000
    /// `>` quote markers at the start of one line, spaces between them allowed.
    static let maxQuoteDepth = 100
    /// `$` characters in the whole text (each inline formula takes two).
    static let maxDollarSigns = 1000
    /// Consecutive `[` or consecutive `(`; this many or more is heavy.
    static let bracketRunLimit = 500

    /// Single pass over the UTF-8 bytes, stopping at the first limit hit.
    static func isHeavy(_ text: String) -> Bool {
        let utf8 = text.utf8
        if utf8.count > maxBytes {
            return true
        }
        var lineLength = 0
        var quoteDepth = 0
        var inQuotePrefix = true
        var dollarSigns = 0
        var bracketRun = 0
        var parenRun = 0
        for byte in utf8 {
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                lineLength = 0
                quoteDepth = 0
                inQuotePrefix = true
                bracketRun = 0
                parenRun = 0
                continue
            }
            // Count scalars, not bytes: skip UTF-8 continuation bytes.
            if byte & 0xC0 != 0x80 {
                lineLength += 1
                if lineLength > maxLineLength {
                    return true
                }
            }
            if inQuotePrefix {
                if byte == UInt8(ascii: ">") {
                    quoteDepth += 1
                    if quoteDepth > maxQuoteDepth {
                        return true
                    }
                } else if byte != UInt8(ascii: " "), byte != UInt8(ascii: "\t") {
                    inQuotePrefix = false
                }
            }
            if byte == UInt8(ascii: "$") {
                dollarSigns += 1
                if dollarSigns > maxDollarSigns {
                    return true
                }
            }
            bracketRun = byte == UInt8(ascii: "[") ? bracketRun + 1 : 0
            parenRun = byte == UInt8(ascii: "(") ? parenRun + 1 : 0
            if bracketRun >= bracketRunLimit || parenRun >= bracketRunLimit {
                return true
            }
        }
        return false
    }
}
