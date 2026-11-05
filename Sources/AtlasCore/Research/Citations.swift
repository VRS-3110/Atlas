import Foundation

/// Citation keys in the common `authorYEARword` form, e.g. `darwin1859origin`.
public enum CitationKey {
    private static let skippedWords: Set<String> = [
        "a", "an", "the", "on", "of", "in", "and", "for", "to", "at", "by", "with", "from", "is", "are",
    ]

    /// The key for a source, before any de-duplication.
    public static func base(title: String, info: SourceInfo) -> String {
        let author = info.authors.first.map(familyName) ?? ""
        let word = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { fold(String($0)) }
            .first { !$0.isEmpty && !skippedWords.contains($0) } ?? ""
        let year = info.year.map(String.init) ?? ""
        let key = fold(author) + year + word
        return key.isEmpty ? "source" : key
    }

    /// A key not in `taken` (compared case-insensitively): the base key, then with
    /// `a`, `b`, `c`… appended, as reference managers do.
    public static func unique(title: String, info: SourceInfo, taken: Set<String>) -> String {
        let lowered = Set(taken.map { $0.lowercased() })
        let base = base(title: title, info: info)
        if !lowered.contains(base) { return base }
        for suffix in "abcdefghijklmnopqrstuvwxyz" where !lowered.contains(base + String(suffix)) {
            return base + String(suffix)
        }
        var n = 2
        while lowered.contains("\(base)\(n)") { n += 1 }
        return "\(base)\(n)"
    }

    /// The family name of an author written "Last, First" or "First Last".
    public static func familyName(_ author: String) -> String {
        if let comma = author.firstIndex(of: ",") {
            return String(author[..<comma]).trimmingCharacters(in: .whitespaces)
        }
        return author.split(separator: " ").last.map(String.init) ?? author
    }

    /// Lower-case ASCII letters and digits only: "Müller-Lüdenscheidt" → "mullerludenscheidt".
    static func fold(_ text: String) -> String {
        let plain = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "ø", with: "o")
            .replacingOccurrences(of: "æ", with: "ae")
        return String(plain.lowercased().unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0)) }
            .map(Character.init))
    }
}

/// Formats citations in an author–date style close to APA, which reads well in notes and
/// drafts whatever the final style will be.
public enum CitationFormatter {
    /// "Darwin, 1859, p. 42" or "Darwin & Wallace, 1858" or "Smith et al., 2020".
    public static func inText(_ info: SourceInfo, title: String, page: String = "") -> String {
        var parts: [String] = []
        let names = info.authors.map(CitationKey.familyName)
        switch names.count {
        case 0: parts.append(title.isEmpty ? "Anonymous" : shortTitle(title))
        case 1: parts.append(names[0])
        case 2: parts.append("\(names[0]) & \(names[1])")
        default: parts.append("\(names[0]) et al.")
        }
        parts.append(info.year.map(String.init) ?? "n.d.")
        let page = page.trimmingCharacters(in: .whitespaces)
        if !page.isEmpty { parts.append(page.contains("-") || page.contains("–") ? "pp. \(page)" : "p. \(page)") }
        return parts.joined(separator: ", ")
    }

    /// The full reference: "Darwin, C. (1859). On the Origin of Species. John Murray. https://doi.org/…"
    public static func reference(_ info: SourceInfo, title: String) -> String {
        var text = ""
        let authors = info.authors.map(initialled)
        switch authors.count {
        case 0: break
        case 1: text = authors[0]
        case 2: text = "\(authors[0]), & \(authors[1])"
        default: text = authors.dropLast().joined(separator: ", ") + ", & " + authors.last!
        }
        let year = info.year.map(String.init) ?? "n.d."
        text += text.isEmpty ? "\(title) (\(year))." : " (\(year)). \(title)."
        var container = info.container
        if !container.isEmpty {
            if !info.volume.isEmpty {
                container += ", \(info.volume)"
                if !info.issue.isEmpty { container += "(\(info.issue))" }
            }
            if !info.pages.isEmpty { container += ", \(info.pages)" }
            text += " \(container)."
        } else if !info.publisher.isEmpty {
            text += " \(info.publisher)."
        }
        if !info.doi.isEmpty {
            text += " https://doi.org/\(info.doi)"
        } else if !info.url.isEmpty {
            text += " \(info.url)"
        }
        return text.replacingOccurrences(of: "..", with: ".")
    }

    /// What Cite copies for a quote: the quote with its in-text citation, then the reference.
    public static func quote(_ text: String, page: String, source info: SourceInfo, sourceTitle: String) -> String {
        let quote = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return "“\(quote)” (\(inText(info, title: sourceTitle, page: page)))\n\n\(reference(info, title: sourceTitle))"
    }

    /// "Darwin, Charles Robert" → "Darwin, C. R."
    static func initialled(_ author: String) -> String {
        guard let comma = author.firstIndex(of: ",") else { return author }
        let last = author[..<comma]
        let initials = author[author.index(after: comma)...]
            .split(whereSeparator: { $0 == " " || $0 == "-" })
            .compactMap { $0.first.map { "\($0)." } }
            .joined(separator: " ")
        return initials.isEmpty ? String(last) : "\(last), \(initials)"
    }

    private static func shortTitle(_ title: String) -> String {
        let words = title.split(separator: " ")
        return words.count > 4 ? words.prefix(4).joined(separator: " ") + "…" : title
    }
}
