import Foundation
import SwiftMath
import UIKit

/// Rewrites LaTeX math into image links that the providers below render with SwiftMath.
/// `$$..$$` and `\[..\]` become display math, `$..$` and `\(..\)` inline. Code is left alone.
enum MathMarkdown {
    private static let patterns: [(String, Bool)] = [
        (#"\$\$(.+?)\$\$"#, true),
        (#"\\\[(.+?)\\\]"#, true),
        (#"\\\((.+?)\\\)"#, false),
        // No space inside the delimiters and no digit after, so "$5 and $10" stays text.
        (#"(?<![\\$\w])\$(?!\s)([^$\n]+?)(?<!\s)\$(?!\d)"#, false),
    ]

    static func url(latex: String, display: Bool) -> String {
        let b64 = Data(latex.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return "math://\(display ? "block" : "inline")/\(b64)"
    }

    static func latex(from url: URL) -> (String, Bool)? {
        guard url.scheme == "math" else { return nil }
        let b64 = url.lastPathComponent.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: b64), let s = String(data: data, encoding: .utf8) else { return nil }
        return (s, url.host == "block")
    }

    static func rewrite(_ markdown: String) -> String {
        guard markdown.contains("$") || markdown.contains("\\(") || markdown.contains("\\[") else { return markdown }
        // Split on fenced blocks and inline code spans; only the pieces between them are rewritten.
        guard let codeRE = try? NSRegularExpression(pattern: #"```.*?```|`[^`\n]+`"#, options: [.dotMatchesLineSeparators]) else { return markdown }
        let ns = markdown as NSString
        var out = ""
        var cursor = 0
        for m in codeRE.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            out += rewriteProse(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            out += ns.substring(with: m.range)
            cursor = m.range.location + m.range.length
        }
        return out + rewriteProse(ns.substring(from: cursor))
    }

    private static func rewriteProse(_ text: String) -> String {
        var s = text
        for (pattern, display) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: display ? [.dotMatchesLineSeparators] : []) else { continue }
            let ns = s as NSString
            var result = ""
            var cursor = 0
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                let latex = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                if let ok = renderable(latex, display: display) {
                    let link = "![math](\(url(latex: ok, display: display)))"
                    result += display ? "\n\n\(link)\n\n" : link
                } else {
                    // SwiftMath cannot typeset it: show the source rather than a broken image.
                    result += display ? "\n\n```latex\n\(latex)\n```\n\n" : "`\(latex)`"
                }
                cursor = m.range.location + m.range.length
            }
            s = result + ns.substring(from: cursor)
        }
        return s
    }

    /// Symbols notes use that SwiftMath does not define. All exist in Latin Modern Math.
    private static let extraSymbols: Void = {
        let relations: [String: String] = [
            "vdash": "\u{22A2}", "dashv": "\u{22A3}", "Vdash": "\u{22A9}", "vDash": "\u{22A8}", "nvdash": "\u{22AC}",
            "nvDash": "\u{22AD}", "nVdash": "\u{22AE}", "preceq": "\u{2AAF}", "succeq": "\u{2AB0}", "prec": "\u{227A}",
            "succ": "\u{227B}", "leadsto": "\u{21DD}", "subsetneq": "\u{228A}", "supsetneq": "\u{228B}",
            "nsubseteq": "\u{2288}", "nsupseteq": "\u{2289}", "nequiv": "\u{2262}", "ncong": "\u{2247}",
            "nleq": "\u{2270}", "ngeq": "\u{2271}", "nmid": "\u{2224}", "nexists": "\u{2204}", "mapsfrom": "\u{21A4}",
            "sqsubseteq": "\u{2291}", "sqsupseteq": "\u{2292}", "bowtie": "\u{22C8}", "triangleq": "\u{225C}",
            "coloneqq": "\u{2254}", "rightsquigarrow": "\u{21DD}", "twoheadrightarrow": "\u{21A0}", "hookrightarrow": "\u{21AA}",
        ]
        let ordinary: [String: String] = [
            "Box": "\u{25A1}", "square": "\u{25A1}", "Diamond": "\u{25C7}", "lozenge": "\u{25CA}", "ulcorner": "\u{231C}",
            "urcorner": "\u{231D}", "llcorner": "\u{231E}", "lrcorner": "\u{231F}", "upharpoonright": "\u{21BE}",
            "restriction": "\u{21BE}", "blacksquare": "\u{25A0}", "varnothing": "\u{2205}", "complement": "\u{2201}",
        ]
        // Atoms cannot be built directly, so each new symbol starts as a copy of one of the same class.
        func register(_ table: [String: String], like template: String) {
            for (name, glyph) in table where MTMathAtomFactory.atom(forLatexSymbol: name) == nil {
                guard let atom = MTMathAtomFactory.atom(forLatexSymbol: template) else { continue }
                atom.nucleus = glyph
                MTMathAtomFactory.add(latexSymbol: name, value: atom)
            }
        }
        register(relations, like: "leq")
        register(ordinary, like: "infty")
    }()

    /// Negated relations written with `\not`, mapped to their own symbols.
    private static let negations: [(String, String)] = [
        (#"\\not\s*\\models"#, #"\\nvDash "#), (#"\\not\s*\\vdash"#, #"\\nvdash "#), (#"\\not\s*\\Vdash"#, #"\\nVdash "#),
        (#"\\not\s*\\in\b"#, #"\\notin "#), (#"\\not\s*="#, #"\\neq "#), (#"\\not\s*\\equiv"#, #"\\nequiv "#),
        (#"\\not\s*\\subseteq"#, #"\\nsubseteq "#), (#"\\not\s*\\leq?\b"#, #"\\nleq "#), (#"\\not\s*\\geq?\b"#, #"\\ngeq "#),
        (#"\\not\s*\\exists"#, #"\\nexists "#), (#"\\not\s*\\mid"#, #"\\nmid "#), (#"\\not\s*\\cong"#, #"\\ncong "#),
    ]

    /// Rewrites commands SwiftMath cannot parse into ones it can, without changing what the formula says.
    static func normalize(_ latex: String) -> String {
        var s = latex
        for (pattern, replacement) in negations { s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression) }
        // Manual delimiter sizes only affect size; fraction variants only affect style.
        s = s.replacingOccurrences(of: #"\\(?:big|Big|bigg|Bigg)[lrm]?(?![a-zA-Z])"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\[dt]frac"#, with: #"\\frac"#, options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\(?:mathop|mathrel|mathbin|mathord)(?![a-zA-Z])"#, with: "", options: .regularExpression)
        return s
    }

    /// The LaTeX as given, or a rewritten form SwiftMath accepts, or nil when neither typesets.
    static func renderable(_ source: String, display: Bool) -> String? {
        _ = extraSymbols
        let latex = normalize(source)
        let variants = [
            latex,
            latex.replacingOccurrences(of: "\\stackrel", with: "\\overset"),
            // Last resort for stacked relations: the label as a superscript.
            latex.replacingOccurrences(of: #"\\(?:stackrel|overset)\{((?:[^{}]|\{[^{}]*\})*)\}\{((?:[^{}]|\{[^{}]*\})*)\}"#, with: "{$2}^{$1}", options: .regularExpression),
        ]
        return variants.first { image(latex: $0, display: display, size: 16) != nil }
    }

    private static var cache: [String: UIImage] = [:]

    /// Template image, so it takes the surrounding text color in light and dark mode.
    static func image(latex: String, display: Bool, size: CGFloat) -> UIImage? {
        let key = "\(display)|\(size)|\(latex)"
        if let hit = cache[key] { return hit }
        var math = MathImage(latex: latex, fontSize: size, textColor: .black, labelMode: display ? .display : .text, textAlignment: .left)
        let (_, image, layout) = math.asImage()
        if cache.count > 800 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

