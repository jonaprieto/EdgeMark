import Foundation

/// The highlight.js language for a gist code file, from its name (extension, or a well-known
/// name like `Makefile`) or, for a file without a known extension, its `#!` line. Every
/// value is a language the bundled highlight.js (HighlighterSwift 3.1.0, highlight.js
/// 11.11.1) registers. Languages it lacks map to a close grammar only where keywords,
/// strings and comments still come out right (Solidity as JavaScript, Agda and Idris as
/// Haskell); the rest stay plain. Foundation only, so the rules are unit tested by the
/// `EdgeStorageLogic` SPM target.
nonisolated enum SyntaxLanguage {
    /// Larger texts stay plain: highlight.js runs over the whole text on every edit.
    static let maxBytes = 300 * 1024
    /// Texts with more lines than this stay plain too.
    static let maxLines = 5000

    private static let byExtension: [String: String] = {
        var map: [String: String] = [:]
        func add(_ exts: [String], _ language: String) {
            for ext in exts {
                map[ext] = language
            }
        }
        add(["rs"], "rust")
        add(["py", "pyw", "pyi"], "python")
        add(["js", "mjs", "cjs", "jsx"], "javascript")
        add(["ts", "tsx", "mts", "cts"], "typescript")
        add(["json", "jsonc", "json5", "ipynb"], "json")
        add(["yaml", "yml"], "yaml")
        // highlight.js has no TOML grammar; its INI grammar handles tables, keys, strings
        // and comments (`toml` is an alias of `ini` there).
        add(["toml", "ini", "cfg"], "ini")
        add(["sh", "bash", "zsh"], "bash")
        add(["c", "h"], "c")
        add(["cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx", "h++"], "cpp")
        add(["cs"], "csharp")
        add(["mm"], "objectivec")
        add(["go"], "go")
        add(["java"], "java")
        add(["kt", "kts"], "kotlin")
        add(["scala"], "scala")
        add(["groovy", "gradle"], "groovy")
        add(["swift"], "swift")
        add(["rb", "gemspec", "rake"], "ruby")
        add(["php"], "php")
        add(["pl", "pm"], "perl")
        add(["lua"], "lua")
        add(["sql"], "sql")
        add(["html", "htm", "xhtml", "xml", "svg", "plist", "xsd", "xsl"], "xml")
        add(["css"], "css")
        add(["scss"], "scss")
        add(["less"], "less")
        add(["md", "markdown"], "markdown")
        add(["ex", "exs"], "elixir")
        add(["erl", "hrl"], "erlang")
        add(["hs"], "haskell")
        add(["elm"], "elm")
        add(["ml", "mli"], "ocaml")
        add(["fs", "fsi", "fsx"], "fsharp")
        add(["clj", "cljs", "cljc", "edn"], "clojure")
        add(["el", "lisp"], "lisp")
        add(["scm", "rkt"], "scheme")
        add(["r"], "r")
        add(["jl"], "julia")
        add(["dart"], "dart")
        add(["nix"], "nix")
        add(["dockerfile"], "dockerfile")
        add(["mk", "mak", "make"], "makefile")
        add(["cmake"], "cmake")
        add(["tex", "sty", "ltx"], "latex")
        add(["diff", "patch"], "diff")
        add(["graphql", "gql"], "graphql")
        add(["proto"], "protobuf")
        add(["vim"], "vim")
        add(["ps1", "psm1"], "powershell")
        add(["bat", "cmd"], "dos")
        add(["tcl"], "tcl")
        add(["awk"], "awk")
        add(["adoc", "asciidoc"], "asciidoc")
        add(["nim"], "nim")
        add(["cr"], "crystal")
        add(["f90", "f95"], "fortran")
        add(["hx"], "haxe")
        add(["wat", "wast"], "wasm")
        // `.v` is Verilog in highlight.js; in gists it is Coq far more often.
        add(["v"], "coq")
        // Not in highlight.js. Solidity's comments, strings, numbers and most keywords
        // (`function`, `return`, `if`) read right as JavaScript.
        add(["sol"], "javascript")
        // Not in highlight.js. Haskell's grammar gets their `--` and `{- -}` comments,
        // strings, `module`/`where`/`data`/`import` and capitalised types right. Lean is
        // left plain: its `/- -/` comments come out as code there.
        add(["agda", "idr"], "haskell")
        return map
    }()

    /// Lowercased whole file names without a telling extension.
    private static let byFileName: [String: String] = [
        "makefile": "makefile", "gnumakefile": "makefile",
        "dockerfile": "dockerfile", "containerfile": "dockerfile",
        "cmakelists.txt": "cmake",
        "gemfile": "ruby", "rakefile": "ruby", "podfile": "ruby", "vagrantfile": "ruby", "brewfile": "ruby",
        ".bashrc": "bash", ".bash_profile": "bash", ".bash_aliases": "bash", ".bash_logout": "bash",
        ".profile": "bash", ".zshrc": "bash", ".zshenv": "bash", ".zprofile": "bash", ".zlogin": "bash",
        ".gitconfig": "ini", ".editorconfig": "ini",
        ".vimrc": "vim", "_vimrc": "vim",
    ]

    /// `#!` interpreters (the command's last path component, version digits dropped).
    private static let byInterpreter: [String: String] = [
        "sh": "bash", "bash": "bash", "zsh": "bash", "dash": "bash", "ksh": "bash",
        "python": "python", "pypy": "python",
        "node": "javascript", "nodejs": "javascript", "deno": "javascript", "bun": "javascript",
        "ts-node": "typescript", "tsx": "typescript",
        "ruby": "ruby", "perl": "perl", "php": "php", "lua": "lua", "luajit": "lua",
        "rscript": "r", "julia": "julia", "elixir": "elixir", "escript": "erlang",
        "runhaskell": "haskell", "runghc": "haskell", "swift": "swift", "pwsh": "powershell",
        "tclsh": "tcl", "wish": "tcl", "awk": "awk", "gawk": "awk", "make": "makefile",
        "kotlin": "kotlin", "scala": "scala", "osascript": "applescript", "guile": "scheme",
        "racket": "scheme", "ocaml": "ocaml", "groovy": "groovy",
    ]

    /// Every language this type can return, for the test that pins them to highlight.js.
    static var mappedLanguages: Set<String> {
        Set(byExtension.values).union(byFileName.values).union(byInterpreter.values)
    }

    /// The highlight.js language for a file named `name` (any case), or nil to show it
    /// plain. A whole-name match (`Makefile`, `.zshrc`) wins, then the extension (the last
    /// one, so `foo.test.ts` is TypeScript), then a `Dockerfile.*` name, then the `#!` line
    /// of `content` when given.
    static func language(forFileName name: String, content: String? = nil) -> String? {
        let lower = name.lowercased()
        if let language = byFileName[lower] {
            return language
        }
        if let language = byExtension[(lower as NSString).pathExtension] {
            return language
        }
        if lower.hasPrefix("dockerfile.") || lower.hasPrefix("containerfile.") {
            return "dockerfile"
        }
        return content.flatMap(language(forShebangIn:))
    }

    /// The language named by a first line like `#!/usr/bin/env python3` or `#!/bin/bash`.
    /// `env` and its options (`-S`) and `NAME=value` settings are skipped.
    static func language(forShebangIn text: String) -> String? {
        guard text.hasPrefix("#!") else { return nil }
        let firstLine = text.dropFirst(2).prefix { $0 != "\n" && $0 != "\r" }
        var words = firstLine.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        if (words[0] as NSString).lastPathComponent == "env" {
            words.removeFirst()
            words.removeAll { $0.hasPrefix("-") || $0.contains("=") }
        }
        guard let command = words.first else { return nil }
        var interpreter = (command as NSString).lastPathComponent.lowercased()
        // python3, python3.12, lua5.4
        while let last = interpreter.last, last.isNumber || last == "." {
            interpreter.removeLast()
        }
        return byInterpreter[interpreter]
    }

    /// Whether `text` is small enough to highlight: at most `maxBytes` UTF-8 bytes and
    /// `maxLines` lines, and not `NoteComplexity.isHeavy`.
    static func isSmallEnough(_ text: String) -> Bool {
        let utf8 = text.utf8
        guard utf8.count <= maxBytes else { return false }
        var lines = 1
        for byte in utf8 where byte == UInt8(ascii: "\n") {
            lines += 1
            if lines > maxLines {
                return false
            }
        }
        return !NoteComplexity.isHeavy(text)
    }

    /// `text` as one fenced Markdown code block in `language`, for rendering a code file
    /// through the Markdown engine (the PDF export). Nil when a line of `text` starts with
    /// three backticks: the engine closes a block at any such line, whatever its length.
    static func fencedCodeBlock(_ text: String, language: String) -> String? {
        let startsFence = text.hasPrefix("```") || text.contains("\n```") || text.contains("\r```")
        guard !startsFence else { return nil }
        let body = text.hasSuffix("\n") ? text : text + "\n"
        return "```\(language)\n\(body)```\n"
    }
}
