import Foundation

/// Plain-text outlines: one item per line, nested by indentation. Used to copy nodes as
/// text and to paste lists and Markdown from other apps onto a map.
public enum OutlineText {
    public struct Item: Equatable, Sendable {
        public var title: String
        public var children: [Item]

        public init(_ title: String, children: [Item] = []) {
            self.title = title
            self.children = children
        }

        /// This item and all items below it.
        public var count: Int { 1 + children.reduce(0) { $0 + $1.count } }
    }

    /// One line per item, children indented by a tab.
    public static func render(_ items: [Item]) -> String {
        var lines: [String] = []
        func walk(_ item: Item, depth: Int) {
            lines.append(String(repeating: "\t", count: depth) + item.title)
            for child in item.children { walk(child, depth: depth + 1) }
        }
        for item in items { walk(item, depth: 0) }
        return lines.joined(separator: "\n")
    }

    /// Reads an outline. Indentation (tabs or any number of spaces) sets the depth. List
    /// markers (`-`, `*`, `+`, `•`, `1.`, `1)`, task boxes) are dropped, and Markdown
    /// headings nest everything after them until the next heading of the same or a higher level.
    public static func parse(_ text: String) -> [Item] {
        var lines: [(indent: Int, title: String)] = []
        for raw in text.components(separatedBy: .newlines) {
            var indent = 0
            var rest = Substring(raw)
            while let first = rest.first, first == " " || first == "\t" {
                indent += first == "\t" ? 4 : 1
                rest = rest.dropFirst()
            }
            var title = String(rest).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            if let level = headingLevel(title) {
                // Headings sit above any indented line: h1 shallowest, then h2, and so on.
                indent = level - 7
                title = String(title.dropFirst(level)).trimmingCharacters(in: .whitespaces)
            } else {
                title = stripListMarker(title)
            }
            guard !title.isEmpty else { continue }
            lines.append((indent, title))
        }

        // Each line's depth is the number of shallower lines still open above it.
        var open: [Int] = []
        var flat: [(depth: Int, title: String)] = []
        for line in lines {
            while let last = open.last, last >= line.indent { open.removeLast() }
            flat.append((open.count, line.title))
            open.append(line.indent)
        }
        return build(flat[...])
    }

    private static func build(_ lines: ArraySlice<(depth: Int, title: String)>) -> [Item] {
        var items: [Item] = []
        var index = lines.startIndex
        while index < lines.endIndex {
            let line = lines[index]
            var end = lines.index(after: index)
            while end < lines.endIndex, lines[end].depth > line.depth { end = lines.index(after: end) }
            items.append(Item(line.title, children: build(lines[lines.index(after: index)..<end])))
            index = end
        }
        return items
    }

    /// 1–6 for a Markdown heading (`## Title`), nil otherwise.
    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let after = line.dropFirst(hashes)
        return after.first == " " ? hashes : nil
    }

    private static func stripListMarker(_ line: String) -> String {
        var text = Substring(line)
        if let first = text.first, "-*+•".contains(first), text.dropFirst().first == " " {
            text = text.dropFirst(2)
        } else {
            let digits = text.prefix { $0.isNumber }
            let after = text.dropFirst(digits.count)
            if !digits.isEmpty, let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " {
                text = after.dropFirst(2)
            }
        }
        for box in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(box) {
            text = text.dropFirst(box.count)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
