import CoreGraphics
import Foundation

/// A map as a plain tree of nodes, for the text exports. Collapsed branches are included:
/// an export carries the map's content, not how it is currently folded.
public struct ExportTree: Sendable {
    public struct Item: Sendable, Equatable {
        public var id: UUID
        public var data: NodeData
        public var children: [Item]

        public var count: Int { 1 + children.reduce(0) { $0 + $1.count } }
    }

    public var name: String
    public var roots: [Item]
    /// Relations between nodes on the map, as (from title, relation, to title).
    public var connections: [(from: String, label: String, to: String)]

    public var nodeCount: Int { roots.reduce(0) { $0 + $1.count } }
}

extension Workspace {
    public func exportTree(of mapID: UUID) -> ExportTree {
        let tree = tree(of: mapID)
        func item(_ id: UUID) -> ExportTree.Item? {
            guard let node = nodes[id] else { return nil }
            return .init(id: id, data: node.data, children: tree.children(of: id).compactMap(item))
        }
        let onMap = Set(tree.allIDs)
        let connections = edges(in: mapID)
            .filter { onMap.contains($0.fromID) && onMap.contains($0.toID) }
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap { edge -> (String, String, String)? in
                guard let a = nodes[edge.fromID], let b = nodes[edge.toID] else { return nil }
                return (a.data.exportTitle, edge.data.displayLabel, b.data.exportTitle)
            }
        return ExportTree(name: maps[mapID]?.name ?? "Map", roots: tree.roots.compactMap(item),
                          connections: connections)
    }

    /// The map as a Markdown outline: a heading, then nested bullets with notes, tags and
    /// task boxes, then the map's connections.
    public func markdown(for mapID: UUID) -> String {
        MarkdownExport.render(exportTree(of: mapID), citation: inTextCitation(for:))
    }

    /// "(Darwin, 1859, p. 4)" for a node citing sources, or "Darwin (1859)"-style text for a
    /// source itself; nil when there is nothing to cite.
    public func inTextCitation(for nodeID: UUID) -> String? {
        guard let node = nodes[nodeID] else { return nil }
        if let info = node.source { return "(\(CitationFormatter.inText(info, title: node.title)))" }
        let parts = node.citations.compactMap { c -> String? in
            guard let source = nodes[c.sourceID], let info = source.source else { return nil }
            return CitationFormatter.inText(info, title: source.title, page: c.page)
        }
        return parts.isEmpty ? nil : "(" + parts.joined(separator: "; ") + ")"
    }

    public func opml(for mapID: UUID, date: Date = Date()) -> String {
        OPML.render(exportTree(of: mapID), date: date)
    }

    /// Makes a new map from an outline file's items (OPML, Markdown or indented text).
    /// Notes become node notes. Returns nil when there is nothing to import.
    @discardableResult
    public func importOutline(_ items: [OPML.Item], named name: String) -> MindMap? {
        guard !items.isEmpty else { return nil }
        func plain(_ item: OPML.Item) -> OutlineText.Item {
            OutlineText.Item(item.title, children: item.children.map(plain))
        }
        var notes: [String] = []
        func collect(_ item: OPML.Item) {
            notes.append(item.note)
            item.children.forEach(collect)
        }
        items.forEach(collect)
        var clip = MapClipboard(outline: items.map(plain), createdAt: clock())
        for index in clip.items.indices where index < notes.count {
            clip.items[index].data.body = notes[index]
        }
        return perform("Import Outline") { _ in
            let map = createMap(named: name, layout: .mindMap, rootTitle: nil)
            paste(clip, into: map.id, under: nil, origin: .zero)
            return map
        }
    }
}

extension NodeData {
    var exportTitle: String { title.isEmpty ? "Untitled" : title }
}

public enum MarkdownExport {
    public static func render(_ tree: ExportTree, citation: (UUID) -> String? = { _ in nil }) -> String {
        var lines = ["# \(escape(tree.name))", ""]
        func walk(_ item: ExportTree.Item, depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            let data = item.data
            var line = indent + "- "
            if let task = data.task {
                line += task.status == .done ? "[x] " : "[ ] "
            }
            if data.kind != .idea && data.kind != .task && data.kind != .note {
                line += "*\(data.kind.title):* "
            }
            line += data.kind == .quote ? "“\(escape(data.exportTitle))”" : escape(data.exportTitle)
            if !data.citations.isEmpty || data.source != nil, let cite = citation(item.id), !cite.isEmpty {
                line += " \(cite)"
            }
            if let link = data.link, !link.isEmpty { line += " <\(link)>" }
            if !data.tags.isEmpty { line += " " + data.tags.map { "#\($0)" }.joined(separator: " ") }
            lines.append(line)
            let body = data.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                for bodyLine in body.components(separatedBy: .newlines) {
                    lines.append(indent + "  > " + bodyLine)
                }
            }
            for child in item.children { walk(child, depth: depth + 1) }
        }
        for root in tree.roots { walk(root, depth: 0) }
        if !tree.connections.isEmpty {
            lines += ["", "## Connections", ""]
            for c in tree.connections {
                lines.append("- \(escape(c.from)) → *\(c.label)* → \(escape(c.to))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Escapes characters that would otherwise start Markdown formatting at the start of a title.
    static func escape(_ text: String) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        guard let first = single.first, "#>*+-".contains(first) else { return single }
        return "\\" + single
    }
}

/// OPML 2.0, read by most outliners (OmniOutliner, Bike, Logseq, MindNode). Notes use the
/// common `_note` attribute.
public enum OPML {
    public struct Item: Equatable, Sendable {
        public var title: String
        public var note: String
        public var children: [Item]

        public init(_ title: String, note: String = "", children: [Item] = []) {
            self.title = title
            self.note = note
            self.children = children
        }
    }

    public static func render(_ tree: ExportTree, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<opml version="2.0">"#,
            "  <head>",
            "    <title>\(escape(tree.name))</title>",
            "    <dateCreated>\(formatter.string(from: date))</dateCreated>",
            "  </head>",
            "  <body>",
        ]
        func walk(_ item: ExportTree.Item, depth: Int) {
            let indent = String(repeating: "  ", count: depth + 2)
            let data = item.data
            var attributes = [#"text="\#(escape(data.exportTitle))""#]
            let body = data.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { attributes.append(#"_note="\#(escape(body))""#) }
            if data.kind != .idea { attributes.append(#"atlasKind="\#(data.kind.rawValue)""#) }
            if !data.tags.isEmpty { attributes.append(#"category="\#(escape(data.tags.joined(separator: ",")))""#) }
            if let task = data.task { attributes.append(#"_status="\#(task.status == .done ? "checked" : "unchecked")""#) }
            if let link = data.link ?? (data.source?.url.isEmpty == false ? data.source?.url : nil) {
                attributes.append(#"type="link" url="\#(escape(link))""#)
            }
            let open = indent + "<outline " + attributes.joined(separator: " ")
            if item.children.isEmpty {
                lines.append(open + "/>")
            } else {
                lines.append(open + ">")
                for child in item.children { walk(child, depth: depth + 1) }
                lines.append(indent + "</outline>")
            }
        }
        for root in tree.roots { walk(root, depth: 0) }
        lines += ["  </body>", "</opml>"]
        return lines.joined(separator: "\n") + "\n"
    }

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "\n": result += "&#10;"
            case "\t": result += "&#9;"
            case "\r": continue
            default:
                // Control characters are not allowed in XML 1.0.
                if scalar.value < 0x20 { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// The outline items of an OPML document, and its title. Nil if the data is not OPML.
    public static func parse(_ data: Data) -> (title: String, items: [Item])? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), reader.sawOPML else { return nil }
        return (reader.title.trimmingCharacters(in: .whitespacesAndNewlines), reader.roots)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var sawOPML = false
        var title = ""
        var roots: [Item] = []
        private var stack: [Item] = []
        private var inTitle = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name.lowercased() {
            case "opml": sawOPML = true
            case "title": inTitle = stack.isEmpty
            case "outline":
                let text = attributes["text"] ?? attributes["title"] ?? ""
                stack.append(Item(text.trimmingCharacters(in: .whitespacesAndNewlines), note: attributes["_note"] ?? ""))
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inTitle { title += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name.lowercased() {
            case "title": inTitle = false
            case "outline":
                guard let item = stack.popLast() else { return }
                if stack.isEmpty { roots.append(item) } else { stack[stack.count - 1].children.append(item) }
            default: break
            }
        }
    }

    /// In a Markdown export, `> ` lines under an item are its notes, not children.
    private static func foldMarkdownNotes(_ item: Item) -> Item {
        var item = item
        let notes = item.children.filter { $0.title.hasPrefix("> ") || $0.title == ">" }
        if !notes.isEmpty {
            item.note = notes.map { String($0.title.dropFirst(min(2, $0.title.count))) }.joined(separator: "\n")
            item.children.removeAll { $0.title.hasPrefix("> ") || $0.title == ">" }
        }
        for kind in NodeKind.allCases where item.title.hasPrefix("*\(kind.title):* ") {
            item.title = String(item.title.dropFirst(kind.title.count + 4))
        }
        item.children = item.children.map(foldMarkdownNotes)
        return item
    }

    /// Items from any outline file: OPML, or Markdown and indented text (one item per line).
    public static func items(fromFile data: Data) -> (title: String, items: [Item]) {
        if let opml = parse(data) { return opml }
        let text = String(decoding: data, as: UTF8.self)
        func convert(_ item: OutlineText.Item) -> Item { Item(item.title, children: item.children.map(convert)) }
        var items = OutlineText.parse(text).map(convert).map(foldMarkdownNotes)
        // A Markdown export starts with the map name as its only top-level heading.
        var title = ""
        if items.count == 1, text.hasPrefix("# ") {
            title = items[0].title
            items = items[0].children.filter { $0.title != "Connections" }
        }
        return (title, items)
    }
}
