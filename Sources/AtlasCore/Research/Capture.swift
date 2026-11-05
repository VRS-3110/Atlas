import Foundation

/// Turns text typed into quick capture (or dropped into the Inbox) into a node.
///
/// - The first line is the title; further lines are the notes.
/// - `#words` in the first line become tags.
/// - A lone web address or DOI becomes a source, ready for a metadata lookup.
/// - `?` at the end makes a question; `[] `, `- [ ] ` or `todo:` in front makes a task;
///   `> ` in front, or text in quotation marks, makes a quote.
public enum CaptureParser {
    public static func node(from text: String, kind override: NodeKind? = nil, date: Date = .now) -> NodeData {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = trimmed.components(separatedBy: .newlines)
        var first = lines.isEmpty ? "" : lines.removeFirst().trimmingCharacters(in: .whitespaces)
        var body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // A bare link or DOI.
        if lines.isEmpty, !first.contains(" ") {
            if let url = URL(string: first), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
               url.host != nil {
                var info = SourceInfo()
                if let doi = DOI.normalize(first), url.host?.hasSuffix("doi.org") == true { info.doi = doi } else { info.url = first }
                var data = NodeData(title: placeholderTitle(for: url), kind: override ?? .source, createdAt: date, inbox: .inbox, link: first)
                if data.kind == .source { data.source = info }
                return data
            }
            if let doi = DOI.normalize(first), doi.count >= first.count - 4 {
                var data = NodeData(title: "doi:\(doi)", kind: override ?? .source, createdAt: date, inbox: .inbox)
                if data.kind == .source { data.source = SourceInfo(doi: doi) }
                return data
            }
        }

        var kind = NodeKind.note
        let lower = first.lowercased()
        for prefix in ["- [ ] ", "[] ", "[ ] ", "todo: ", "todo ", "task: "] where lower.hasPrefix(prefix) {
            kind = .task
            first = String(first.dropFirst(prefix.count))
            break
        }
        if kind == .note, first.hasPrefix("> ") {
            kind = .quote
            first = String(first.dropFirst(2))
        } else if kind == .note, let open = first.first, let close = first.last, first.count > 2,
                  (open == "\"" && close == "\"") || (open == "“" && close == "”") {
            kind = .quote
            first = String(first.dropFirst().dropLast())
        } else if kind == .note, first.hasSuffix("?") {
            kind = .question
        }

        // Tags: #word anywhere in the title line.
        var tags: [String] = []
        let words = first.split(separator: " ", omittingEmptySubsequences: false)
        let kept = words.filter { word in
            guard word.count > 1, word.hasPrefix("#"), word.dropFirst().first?.isLetter == true else { return true }
            tags.append(Tags.normalize(String(word)))
            return false
        }
        first = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        // Very long first lines (a pasted paragraph) keep a short title and the full text.
        if first.count > 140 {
            body = body.isEmpty ? first : first + "\n\n" + body
            first = shortened(first, to: 80)
        }
        var data = NodeData(title: first, body: body, kind: override ?? kind, tags: tags, createdAt: date, inbox: .inbox)
        data.setKind(data.kind)
        return data
    }

    /// "example.com/articles/how-cells-work" for a link whose page has not been read yet.
    public static func placeholderTitle(for url: URL) -> String {
        let host = (url.host ?? "").replacingOccurrences(of: "www.", with: "")
        let path = url.path == "/" ? "" : url.path
        let title = host + path
        return title.count > 80 ? String(title.prefix(79)) + "…" : title
    }

    static func shortened(_ text: String, to length: Int) -> String {
        guard text.count > length else { return text }
        if let end = text.prefix(length).lastIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }),
           text.distance(from: text.startIndex, to: end) > length / 2 {
            return String(text[...end])
        }
        let cut = text.prefix(length)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return word + "…"
    }
}
