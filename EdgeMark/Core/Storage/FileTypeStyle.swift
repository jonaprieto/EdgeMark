import Foundation

/// Label and colour of the file type badge shown for non-Markdown gist files. Colours are
/// the languages' usual ones, darkened where needed so white text stays readable. Foundation
/// only, so the mapping is unit tested by the `EdgeStorageLogic` SPM target.
nonisolated enum FileTypeStyle {
    typealias RGB = (red: Double, green: Double, blue: Double)

    /// Badge for a file without a known extension.
    static let neutral: RGB = (0.50, 0.50, 0.53)

    /// Longest label made from an unknown extension.
    static let maxUnknownLabelLength = 4

    private static let known: [String: (label: String, rgb: RGB)] = {
        var map: [String: (label: String, rgb: RGB)] = [:]
        func add(_ exts: [String], _ label: String, _ rgb: RGB) {
            for ext in exts {
                map[ext] = (label, rgb)
            }
        }
        add(["rs"], "RS", (0.72, 0.26, 0.05))
        add(["agda", "lagda"], "AGDA", (0.20, 0.38, 0.52))
        add(["lean"], "LEAN", (0.12, 0.30, 0.62))
        add(["ex", "exs", "heex"], "EX", (0.29, 0.15, 0.37))
        add(["sol"], "SOL", (0.25, 0.25, 0.36))
        add(["py"], "PY", (0.21, 0.45, 0.65))
        add(["swift"], "SWIFT", (0.86, 0.30, 0.18))
        add(["json"], "JSON", (0.55, 0.45, 0.08))
        add(["txt", "text", ""], "TXT", (0.40, 0.43, 0.48))
        add(["sh", "bash", "zsh", "fish"], "SH", (0.22, 0.52, 0.16))
        add(["js", "mjs", "cjs", "jsx"], "JS", (0.62, 0.52, 0.00))
        add(["ts", "tsx"], "TS", (0.19, 0.47, 0.78))
        add(["c", "h"], "C", (0.33, 0.37, 0.47))
        add(["cpp", "cc", "cxx", "hpp", "hh"], "CPP", (0.80, 0.25, 0.42))
        add(["go"], "GO", (0.00, 0.53, 0.68))
        add(["hs", "lhs"], "HS", (0.37, 0.31, 0.53))
        add(["ml", "mli"], "ML", (0.83, 0.38, 0.07))
        add(["nix"], "NIX", (0.33, 0.42, 0.73))
        add(["yaml", "yml"], "YAML", (0.70, 0.11, 0.13))
        add(["toml"], "TOML", (0.61, 0.26, 0.13))
        add(["html", "htm"], "HTML", (0.85, 0.30, 0.15))
        add(["css", "scss"], "CSS", (0.34, 0.24, 0.49))
        return map
    }()

    /// Label and colour for a file extension (without the dot, any case). An unknown
    /// extension gets its first `maxUnknownLabelLength` characters, uppercased, on the
    /// neutral grey; no extension counts as plain text.
    static func style(forExtension ext: String) -> (label: String, rgb: RGB) {
        let key = ext.lowercased()
        if let style = known[key] {
            return style
        }
        return (String(key.uppercased().prefix(maxUnknownLabelLength)), neutral)
    }
}
