import Foundation

/// Line merge of two edits of the same base text.
public enum ThreeWayMerge {
    private struct Hunk: Equatable {
        /// Base lines `start ..< end` are replaced by `lines`. An insertion has `start == end`.
        var start: Int
        var end: Int
        var lines: [String]
    }

    /// The merged text, or nil when both edits changed the same base lines. Two insertions at
    /// one point keep both, theirs first: two journal lines added on two devices are no conflict.
    public static func merge(base: String, mine: String, theirs: String) -> String? {
        if mine == theirs { return mine }
        if mine == base { return theirs }
        if theirs == base { return mine }

        let baseLines = lines(base)
        let myHunks = hunks(base: baseLines, edited: lines(mine))
        let theirHunks = hunks(base: baseLines, edited: lines(theirs))
        for a in myHunks {
            for b in theirHunks where a != b && clash(a, b) {
                return nil
            }
        }

        let all = theirHunks + myHunks.filter { !theirHunks.contains($0) }
        // Stable on (start, end): at one point, an insertion goes before a replacement.
        let ordered = all.enumerated().sorted {
            ($0.element.start, $0.element.end, $0.offset) < ($1.element.start, $1.element.end, $1.offset)
        }.map(\.element)

        var out: [String] = []
        var next = 0
        for hunk in ordered {
            if hunk.start > next { out += baseLines[next ..< hunk.start] }
            out += hunk.lines
            next = max(next, hunk.end)
        }
        out += baseLines[next...]
        return out.joined(separator: "\n")
    }

    /// Every line of two texts with no common ancestor: theirs in place, mine woven in where the
    /// two line up. For one day's journal started on two devices, which share their headings.
    public static func union(mine: String, theirs: String) -> String {
        let theirLines = lines(theirs)
        var out: [String] = []
        var next = 0
        for hunk in hunks(base: theirLines, edited: lines(mine)) {
            out += theirLines[next ..< hunk.end]
            out += hunk.lines
            next = hunk.end
        }
        out += theirLines[next...]
        return out.joined(separator: "\n")
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func hunks(base: [String], edited: [String]) -> [Hunk] {
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in edited.difference(from: base) {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }

        var out: [Hunk] = []
        var i = 0
        var j = 0
        while i < base.count || j < edited.count {
            let baseKept = i < base.count && !removed.contains(i)
            let editKept = j < edited.count && !inserted.contains(j)
            if baseKept, editKept {
                i += 1
                j += 1
                continue
            }
            var hunk = Hunk(start: i, end: i, lines: [])
            while i < base.count, removed.contains(i) { i += 1 }
            while j < edited.count, inserted.contains(j) {
                hunk.lines.append(edited[j])
                j += 1
            }
            hunk.end = i
            out.append(hunk)
        }
        return out
    }

    private static func clash(_ a: Hunk, _ b: Hunk) -> Bool {
        if a.start == a.end, b.start == b.end { return false }
        if a.start == a.end { return b.start < a.start && a.start < b.end }
        if b.start == b.end { return a.start < b.start && b.start < a.end }
        return a.start < b.end && b.start < a.end
    }
}
