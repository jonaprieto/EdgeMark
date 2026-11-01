import Foundation

/// What a stretch of code is, for coloring.
enum TokenRole: Sendable {
    case comment, string, number, keyword, type, function
}

/// Regex highlighter with per-language keywords. Good enough for quiz snippets and an editor in any
/// pack language, including assembly, without shipping a grammar library.
enum Highlighter {
    private static let cFamily: Set<String> = [
        "if", "else", "for", "while", "do", "return", "break", "continue", "switch", "case", "default", "struct", "class", "enum",
        "union", "const", "static", "void", "int", "char", "long", "short", "unsigned", "signed", "float", "double", "bool", "auto",
        "namespace", "using", "template", "typename", "public", "private", "protected", "virtual", "override", "new", "delete",
        "nullptr", "true", "false", "sizeof", "inline", "typedef", "extern", "volatile", "constexpr", "noexcept", "operator", "this",
        "try", "catch", "throw", "friend", "explicit", "goto", "final", "abstract", "interface", "extends", "implements", "import",
        "package", "null", "var", "let", "function", "async", "await", "yield", "typeof", "instanceof", "export", "from", "of", "in",
        "func", "defer", "go", "chan", "map", "range", "select", "type", "nil", "guard", "self", "super", "init", "protocol", "extension",
        "where", "throws", "is", "as", "val", "fun", "when", "object", "string", "boolean", "number", "any", "readonly", "static",
    ]
    private static let keywords: [String: Set<String>] = [
        "python": ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "None", "True", "False",
                   "import", "from", "as", "pass", "break", "continue", "lambda", "yield", "with", "try", "except", "finally", "raise",
                   "global", "nonlocal", "assert", "del", "async", "await", "self", "match", "case"],
        "rust": ["fn", "let", "mut", "pub", "impl", "trait", "struct", "enum", "match", "if", "else", "for", "while", "loop", "return",
                 "break", "continue", "use", "mod", "crate", "self", "Self", "super", "where", "async", "await", "move", "ref", "dyn",
                 "unsafe", "in", "as", "type", "const", "static", "extern", "true", "false", "macro_rules"],
        "haskell": ["data", "newtype", "type", "class", "instance", "deriving", "module", "import", "where", "let", "in", "case", "of",
                    "if", "then", "else", "do", "forall", "qualified", "as", "hiding", "infixl", "infixr"],
        "lean": ["def", "theorem", "lemma", "example", "by", "fun", "match", "with", "let", "in", "if", "then", "else", "do", "open",
                 "namespace", "end", "inductive", "structure", "class", "instance", "variable", "import", "where", "have", "show",
                 "from", "at", "simp", "rfl", "intro", "exact", "apply", "cases", "induction", "forall", "exists", "postulate", "record",
                 "data", "module", "mutual", "constructor", "field", "private", "noncomputable", "deriving"],
        "ocaml": ["let", "rec", "in", "fun", "function", "match", "with", "if", "then", "else", "type", "module", "open", "of", "and",
                  "begin", "end", "struct", "sig", "val", "mutable", "when", "try", "raise", "true", "false", "for", "while", "do", "done"],
        "sql": ["select", "from", "where", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having", "insert",
                "into", "values", "update", "set", "delete", "create", "table", "index", "as", "and", "or", "not", "null", "limit",
                "distinct", "union", "with", "case", "when", "then", "else", "end", "primary", "key", "foreign", "references", "drop",
                "alter", "view", "exists", "in", "is", "between", "like", "asc", "desc", "over", "partition", "count", "sum", "avg"],
        "asm": ["mov", "lea", "add", "sub", "imul", "idiv", "mul", "div", "xor", "and", "or", "not", "neg", "shl", "shr", "sar", "push",
                "pop", "call", "ret", "jmp", "je", "jne", "jz", "jnz", "jg", "jge", "jl", "jle", "ja", "jae", "jb", "jbe", "cmp", "test",
                "inc", "dec", "syscall", "nop", "movzx", "movsx", "cmove", "cmovne", "cmovg", "cmovl", "section", "global", "db",
                "dw", "dd", "dq", "resb", "equ", "leave", "cdq", "cqo"],
        "bash": ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function", "in", "return", "export",
                 "local", "echo", "exit", "set", "source"],
    ]

    /// Canonical language name for the many spellings packs and LeetCode use.
    static func normalize(_ lang: String) -> String {
        switch lang.lowercased() {
        case "python", "python3", "py": "python"
        case "rust", "rs": "rust"
        case "haskell", "hs": "haskell"
        case "lean", "lean4", "agda": "lean"
        case "ocaml", "ml": "ocaml"
        case "sql", "mysql", "postgresql", "mssql", "oraclesql": "sql"
        case "asm", "x86", "x86-64", "nasm", "assembly": "asm"
        case "bash", "sh", "shell", "zsh": "bash"
        case "toml", "yaml", "yml", "ruby", "r", "elixir": "hash"
        case "lua": "dash"
        case "lisp", "scheme", "racket": "semi"
        default: "c"
        }
    }

    private static func commentPattern(_ lang: String) -> String {
        switch lang {
        case "python", "bash", "hash": "#.*$"
        case "haskell", "sql", "lean", "dash": "--.*$"
        case "asm", "semi": ";.*$"
        case "ocaml": #"\(\*.*?\*\)"#
        default: #"//.*$|/\*[\s\S]*?\*/"#
        }
    }

    /// Token ranges of `code` in priority order: comments first, then strings, numbers, keywords,
    /// functions and types. Earlier tokens are never overlapped by later ones.
    static func spans(_ code: String, lang rawLang: String) -> [(NSRange, TokenRole)] {
        let lang = normalize(rawLang)
        let ns = code as NSString
        let full = NSRange(location: 0, length: ns.length)
        var taken = IndexSet()
        var out: [(NSRange, TokenRole)] = []

        func paint(_ pattern: String, _ role: TokenRole, group: Int = 0, options: NSRegularExpression.Options = [.anchorsMatchLines], filter: ((String) -> Bool)? = nil) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for m in re.matches(in: code, range: full) {
                let r = m.range(at: group)
                guard r.location != NSNotFound, r.length > 0, !taken.intersects(integersIn: r.location ..< r.location + r.length) else { continue }
                if let filter, !filter(ns.substring(with: r)) { continue }
                out.append((r, role))
                taken.insert(integersIn: r.location ..< r.location + r.length)
            }
        }

        let words = keywords[lang] ?? cFamily
        paint(commentPattern(lang), .comment)
        paint(#""(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])'"# + (lang == "python" || lang == "sql" || lang == "bash" ? #"|'(?:\\.|[^'\\\n])*'"# : ""), .string)
        paint(#"\b(?:0x[0-9a-fA-F_]+|0b[01_]+|\d[\d_]*(?:\.\d+)?)\b"#, .number)
        paint(#"\b[A-Za-z_][A-Za-z0-9_]*\b"#, .keyword) { lang == "sql" ? words.contains($0.lowercased()) : words.contains($0) }
        if lang == "asm" {
            paint(#"%?\b(?:[re]?(?:ax|bx|cx|dx|si|di|sp|bp)|r(?:[89]|1[0-5])[dwb]?|[abcd][lh]|[sd]il|[sb]pl|rip|xmm\d+)\b"#, .type)
        } else {
            paint(#"\b([A-Za-z_][A-Za-z0-9_]*)\s*\("#, .function, group: 1)
            paint(#"\b[A-Z][A-Za-z0-9_]*\b"#, .type)
        }
        return out
    }
}
