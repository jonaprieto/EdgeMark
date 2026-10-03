import XCTest
@testable import EdgeStorageLogic

final class SyntaxLanguageTests: XCTestCase {
    /// `hljs.listLanguages()` of the highlight.min.js bundled with HighlighterSwift 3.1.0
    /// (highlight.js 11.11.1). A library upgrade that drops a language the mapping uses
    /// fails `testEveryMappedLanguageIsBundled`; refresh this copy from the new bundle.
    private static let bundledLanguages: Set<String> = [
        "1c", "abnf", "accesslog", "actionscript", "ada", "angelscript", "apache", "applescript", "arcade",
        "arduino", "armasm", "asciidoc", "aspectj", "autohotkey", "autoit", "avrasm", "awk", "axapta", "bash",
        "basic", "bnf", "brainfuck", "c", "cal", "capnproto", "ceylon", "clean", "clojure", "clojure-repl",
        "cmake", "coffeescript", "coq", "cos", "cpp", "crmsh", "crystal", "csharp", "csp", "css", "d", "dart",
        "delphi", "diff", "django", "dns", "dockerfile", "dos", "dsconfig", "dts", "dust", "ebnf", "elixir",
        "elm", "erb", "erlang", "erlang-repl", "excel", "fix", "flix", "fortran", "fsharp", "gams", "gauss",
        "gcode", "gherkin", "glsl", "gml", "go", "golo", "gradle", "graphql", "groovy", "haml", "handlebars",
        "haskell", "haxe", "hsp", "http", "hy", "inform7", "ini", "irpf90", "isbl", "java", "javascript",
        "jboss-cli", "json", "julia", "julia-repl", "kotlin", "lasso", "latex", "ldif", "leaf", "less", "lisp",
        "livecodeserver", "livescript", "llvm", "lsl", "lua", "makefile", "markdown", "mathematica", "matlab",
        "maxima", "mel", "mercury", "mipsasm", "mizar", "mojolicious", "monkey", "moonscript", "n1ql",
        "nestedtext", "nginx", "nim", "nix", "node-repl", "nsis", "objectivec", "ocaml", "openscad", "oxygene",
        "parser3", "perl", "pf", "pgsql", "php", "php-template", "plaintext", "pony", "powershell", "processing",
        "profile", "prolog", "properties", "protobuf", "puppet", "purebasic", "python", "python-repl", "q",
        "qml", "r", "reasonml", "rib", "roboconf", "routeros", "rsl", "ruby", "ruleslanguage", "rust", "sas",
        "scala", "scheme", "scilab", "scss", "shell", "smali", "smalltalk", "sml", "sqf", "sql", "stan",
        "stata", "step21", "stylus", "subunit", "swift", "taggerscript", "tap", "tcl", "thrift", "tp", "twig",
        "typescript", "vala", "vbnet", "vbscript", "vbscript-html", "verilog", "vhdl", "vim", "wasm", "wren",
        "x86asm", "xl", "xml", "xquery", "yaml", "zephir",
    ]

    private func lang(_ name: String, _ content: String? = nil) -> String? {
        SyntaxLanguage.language(forFileName: name, content: content)
    }

    func testBundledListHasItsSize() {
        XCTAssertEqual(Self.bundledLanguages.count, 192)
    }

    func testEveryMappedLanguageIsBundled() {
        XCTAssertFalse(SyntaxLanguage.mappedLanguages.isEmpty)
        for language in SyntaxLanguage.mappedLanguages {
            XCTAssertTrue(Self.bundledLanguages.contains(language), language)
        }
    }

    func testExtensions() {
        let expected: [String: String] = [
            "rs": "rust", "py": "python", "js": "javascript", "mjs": "javascript", "ts": "typescript",
            "tsx": "typescript", "jsx": "javascript", "json": "json", "yaml": "yaml", "yml": "yaml",
            "toml": "ini", "sh": "bash", "bash": "bash", "zsh": "bash", "c": "c", "h": "c", "cpp": "cpp",
            "cc": "cpp", "hpp": "cpp", "go": "go", "java": "java", "kt": "kotlin", "swift": "swift",
            "rb": "ruby", "php": "php", "lua": "lua", "sql": "sql", "html": "xml", "css": "css", "scss": "scss",
            "xml": "xml", "md": "markdown", "ex": "elixir", "exs": "elixir", "erl": "erlang", "hs": "haskell",
            "ml": "ocaml", "mli": "ocaml", "fs": "fsharp", "clj": "clojure", "scala": "scala", "r": "r",
            "jl": "julia", "nix": "nix", "dockerfile": "dockerfile", "mk": "makefile", "tex": "latex",
            "diff": "diff", "patch": "diff", "ini": "ini", "sol": "javascript", "agda": "haskell",
            "v": "coq", "idr": "haskell",
        ]
        for (ext, language) in expected {
            XCTAssertEqual(lang("file.\(ext)"), language, ext)
        }
    }

    func testCaseInsensitive() {
        XCTAssertEqual(lang("Token.SOL"), "javascript")
        XCTAssertEqual(lang("MAIN.RS"), "rust")
        XCTAssertEqual(lang("Proof.V"), "coq")
        XCTAssertEqual(lang("MAKEFILE"), "makefile")
    }

    func testUnknownAndPlainStayNil() {
        for name in ["notes.txt", "data.csv", "LICENSE", "x.unknownext", "Main.lean", "Graph.lagda", "README", ""] {
            XCTAssertNil(lang(name), name)
        }
    }

    func testWellKnownNames() {
        XCTAssertEqual(lang("Makefile"), "makefile")
        XCTAssertEqual(lang("GNUmakefile"), "makefile")
        XCTAssertEqual(lang("Dockerfile"), "dockerfile")
        XCTAssertEqual(lang("Dockerfile.dev"), "dockerfile")
        XCTAssertEqual(lang("CMakeLists.txt"), "cmake")
        XCTAssertEqual(lang("Gemfile"), "ruby")
    }

    func testDotfiles() {
        XCTAssertEqual(lang(".bashrc"), "bash")
        XCTAssertEqual(lang(".zshrc"), "bash")
        XCTAssertEqual(lang(".gitconfig"), "ini")
        XCTAssertEqual(lang(".vimrc"), "vim")
        XCTAssertEqual(lang(".eslintrc.json"), "json")
        XCTAssertNil(lang(".gitignore"))
    }

    func testMultiDotNamesUseTheLastExtension() {
        XCTAssertEqual(lang("foo.test.ts"), "typescript")
        XCTAssertEqual(lang("app.config.mjs"), "javascript")
        XCTAssertEqual(lang("schema.v1.json"), "json")
        XCTAssertNil(lang("archive.rs.txt"))
    }

    func testShebang() {
        XCTAssertEqual(lang("run", "#!/usr/bin/env python3\nprint(1)\n"), "python")
        XCTAssertEqual(lang("run", "#!/bin/bash\necho hi\n"), "bash")
        XCTAssertEqual(lang("run", "#!/bin/sh\r\necho hi\r\n"), "bash")
        XCTAssertEqual(lang("run", "#!/usr/bin/env -S deno run --allow-net\n"), "javascript")
        XCTAssertEqual(lang("run", "#!/usr/bin/env LANG=C node\n"), "javascript")
        XCTAssertEqual(lang("run", "#! /usr/local/bin/python3.12 -u\n"), "python")
        XCTAssertEqual(lang("run", "#!/usr/bin/env ruby"), "ruby")
        XCTAssertNil(lang("run", "#!/usr/bin/env\n"))
        XCTAssertNil(lang("run", "#!/usr/bin/fish\n"))
        XCTAssertNil(lang("run", "echo hi\n#!/bin/bash\n"))
        XCTAssertNil(lang("run"))
    }

    func testKnownExtensionWinsOverShebang() {
        XCTAssertEqual(lang("tool.rb", "#!/usr/bin/env python3\n"), "ruby")
        // An unknown extension falls back to the shebang.
        XCTAssertEqual(lang("tool.cgi", "#!/usr/bin/perl\n"), "perl")
    }

    func testSizeLimits() {
        XCTAssertTrue(SyntaxLanguage.isSmallEnough("fn main() {}\n"))
        XCTAssertTrue(SyntaxLanguage.isSmallEnough(String(repeating: "x\n", count: SyntaxLanguage.maxLines - 1)))
        XCTAssertFalse(SyntaxLanguage.isSmallEnough(String(repeating: "x\n", count: SyntaxLanguage.maxLines)))
        let line = String(repeating: "a", count: 99) + "\n"
        let big = String(repeating: line, count: SyntaxLanguage.maxBytes / 100 + 1)
        XCTAssertGreaterThan(big.utf8.count, SyntaxLanguage.maxBytes)
        XCTAssertFalse(SyntaxLanguage.isSmallEnough(big))
        // Heavy per NoteComplexity even though small.
        XCTAssertFalse(SyntaxLanguage.isSmallEnough(String(repeating: "[", count: NoteComplexity.bracketRunLimit)))
    }

    func testFencedCodeBlock() {
        XCTAssertEqual(SyntaxLanguage.fencedCodeBlock("fn x() {}", language: "rust"), "```rust\nfn x() {}\n```\n")
        XCTAssertEqual(SyntaxLanguage.fencedCodeBlock("a\n", language: "c"), "```c\na\n```\n")
        XCTAssertEqual(SyntaxLanguage.fencedCodeBlock("s = \"```\"\n", language: "python"), "```python\ns = \"```\"\n```\n")
        XCTAssertNil(SyntaxLanguage.fencedCodeBlock("x = '''\n```\n'''\n", language: "python"))
        XCTAssertNil(SyntaxLanguage.fencedCodeBlock("```\n", language: "python"))
    }
}
