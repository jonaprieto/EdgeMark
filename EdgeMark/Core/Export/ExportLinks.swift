import Foundation

/// Link rewriting for "Export as Markdown". Foundation only, so `swift test` builds it
/// standalone (EdgeExportLogic); the app compiles the same file through its group.
enum ExportLinks {
    /// Rewrite the note's own image links `![alt](.STEM/IMG-x.png)` to point at the
    /// exported sibling folder `![alt](EXPORTED-images/IMG-x.png)`, and return the image
    /// file names in first-reference order without duplicates. Links to other notes'
    /// asset folders, non-image links and remote images are left untouched. A destination
    /// with spaces is written in angle brackets so CommonMark still reads it as one path.
    static func rewriteImageLinks(
        in markdown: String,
        stem: String,
        exportedStem: String,
    ) -> (text: String, imageNames: [String]) {
        guard markdown.contains("![") else { return (markdown, []) }
        let escapedStem = NSRegularExpression.escapedPattern(for: stem)
        // Group 1: alt text. Group 2: image file name. The path may be wrapped in <...>.
        let pattern = #"!\[([^\]]*)\]\(<?\."# + escapedStem + #"/(IMG-[A-Za-z0-9\-]+\.[A-Za-z0-9]+)>?\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (markdown, []) }

        let ns = markdown as NSString
        let matches = regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (markdown, []) }

        var names: [String] = []
        for match in matches {
            let name = ns.substring(with: match.range(at: 2))
            if !names.contains(name) { names.append(name) }
        }

        let result = NSMutableString(string: markdown)
        for match in matches.reversed() {
            let alt = ns.substring(with: match.range(at: 1))
            let name = ns.substring(with: match.range(at: 2))
            let path = "\(exportedStem)-images/\(name)"
            let destination = path.contains(" ") ? "<\(path)>" : path
            result.replaceCharacters(in: match.range, with: "![\(alt)](\(destination))")
        }
        return (result as String, names)
    }
}
