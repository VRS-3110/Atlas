import Foundation

/// One `@type{key, field = value, ...}` entry. Field names are lowercased; values are the
/// raw BibTeX text with the outer braces or quotes removed (LaTeX not yet decoded).
public struct BibEntry: Equatable, Sendable {
    public var type: String
    public var key: String
    public var fields: [String: String]
    /// Field names in the order they appeared (or should be written).
    public var fieldOrder: [String]

    public init(type: String, key: String, fields: [(String, String)] = []) {
        self.type = type.lowercased()
        self.key = key
        self.fields = [:]
        self.fieldOrder = []
        for (name, value) in fields { self[name] = value }
    }

    public subscript(name: String) -> String? {
        get { fields[name.lowercased()] }
        set {
            let name = name.lowercased()
            if let newValue {
                if fields[name] == nil { fieldOrder.append(name) }
                fields[name] = newValue
            } else {
                fields[name] = nil
                fieldOrder.removeAll { $0 == name }
            }
        }
    }
}

/// Reads and writes BibTeX, and converts between entries and Atlas sources.
public enum BibTeX {

    // MARK: Parsing

    /// Parses every entry in `text`. `@string` macros and the standard month abbreviations
    /// are expanded; `@comment` and `@preamble` blocks are skipped. Malformed entries are
    /// skipped rather than failing the whole file.
    public static func parse(_ text: String) -> [BibEntry] {
        var parser = Parser(text)
        return parser.entries()
    }

    private struct Parser {
        let chars: [Character]
        var i = 0
        var macros: [String: String] = [
            "jan": "January", "feb": "February", "mar": "March", "apr": "April", "may": "May", "jun": "June",
            "jul": "July", "aug": "August", "sep": "September", "oct": "October", "nov": "November", "dec": "December",
        ]

        init(_ text: String) { chars = Array(text) }

        mutating func entries() -> [BibEntry] {
            var result: [BibEntry] = []
            while i < chars.count {
                guard chars[i] == "@" else { i += 1; continue }
                i += 1
                let type = identifier().lowercased()
                skipSpace()
                guard i < chars.count, chars[i] == "{" || chars[i] == "(" else { continue }
                let close: Character = chars[i] == "{" ? "}" : ")"
                switch type {
                case "comment", "preamble":
                    skipBalanced()
                case "string":
                    i += 1
                    skipSpace()
                    let name = identifier().lowercased()
                    skipSpace()
                    if i < chars.count, chars[i] == "=" {
                        i += 1
                        macros[name] = value()
                    }
                    skip(to: close)
                case "":
                    continue
                default:
                    let start = i
                    if let entry = entry(type: type, close: close) {
                        result.append(entry)
                    } else {
                        i = start + 1
                    }
                }
            }
            return result
        }

        /// Reads `key, name = value, ...}` after the opening brace.
        mutating func entry(type: String, close: Character) -> BibEntry? {
            i += 1
            skipSpace()
            var key = ""
            while i < chars.count, chars[i] != ",", chars[i] != close, !chars[i].isNewline {
                key.append(chars[i])
                i += 1
            }
            var entry = BibEntry(type: type, key: key.trimmingCharacters(in: .whitespaces))
            while i < chars.count {
                skipSpace()
                guard i < chars.count else { return nil }
                if chars[i] == "," { i += 1; continue }
                if chars[i] == close { i += 1; return entry }
                if chars[i] == "@" { return entry } // unterminated: keep what we have
                let name = identifier().lowercased()
                guard !name.isEmpty else { i += 1; continue }
                skipSpace()
                guard i < chars.count, chars[i] == "=" else { continue }
                i += 1
                entry[name] = value()
            }
            return entry.key.isEmpty && entry.fields.isEmpty ? nil : entry
        }

        /// A field value: braced, quoted, a number or a macro name, joined with `#`.
        mutating func value() -> String {
            var result = ""
            while i < chars.count {
                skipSpace()
                guard i < chars.count else { break }
                switch chars[i] {
                case "{":
                    result += braced()
                case "\"":
                    result += quoted()
                default:
                    let word = identifier()
                    if word.isEmpty { return result }
                    result += word.allSatisfy(\.isNumber) ? word : (macros[word.lowercased()] ?? word)
                }
                skipSpace()
                if i < chars.count, chars[i] == "#" { i += 1 } else { break }
            }
            return result
        }

        /// Contents of a `{...}` group, nested braces kept.
        mutating func braced() -> String {
            var depth = 0
            var result = ""
            while i < chars.count {
                let c = chars[i]
                i += 1
                if c == "{" {
                    depth += 1
                    if depth == 1 { continue }
                } else if c == "}" {
                    depth -= 1
                    if depth == 0 { break }
                } else if c == "\\", i < chars.count {
                    result.append(c)
                    result.append(chars[i])
                    i += 1
                    continue
                } else if c.isNewline, startsEntry(at: i) {
                    break // an unclosed brace: stop at the next entry rather than swallow it
                }
                result.append(c)
            }
            return result
        }

        /// Whether `@type{` (after optional spaces) starts at `index`.
        func startsEntry(at index: Int) -> Bool {
            var j = index
            while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
            guard j < chars.count, chars[j] == "@" else { return false }
            j += 1
            let start = j
            while j < chars.count, chars[j].isLetter { j += 1 }
            return j > start && j < chars.count && (chars[j] == "{" || chars[j] == "(")
        }

        mutating func quoted() -> String {
            i += 1
            var depth = 0
            var result = ""
            while i < chars.count {
                let c = chars[i]
                i += 1
                if c == "{" { depth += 1 }
                if c == "}" { depth -= 1 }
                if c == "\"", depth == 0 { break }
                result.append(c)
            }
            return result
        }

        mutating func identifier() -> String {
            var result = ""
            while i < chars.count {
                let c = chars[i]
                guard c.isLetter || c.isNumber || "_-:./+'".contains(c) else { break }
                result.append(c)
                i += 1
            }
            return result
        }

        mutating func skipSpace() {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
        }

        mutating func skipBalanced() {
            let open = chars[i]
            let close: Character = open == "{" ? "}" : ")"
            var depth = 0
            while i < chars.count {
                if chars[i] == open { depth += 1 }
                if chars[i] == close { depth -= 1; if depth == 0 { i += 1; return } }
                i += 1
            }
        }

        mutating func skip(to close: Character) {
            while i < chars.count, chars[i] != close { i += 1 }
            i += 1
        }
    }

    // MARK: Writing

    /// Formats entries as BibTeX text, fields indented in their stored order.
    public static func format(_ entries: [BibEntry]) -> String {
        entries.map(format).joined(separator: "\n\n") + (entries.isEmpty ? "" : "\n")
    }

    public static func format(_ entry: BibEntry) -> String {
        var lines = ["@\(entry.type){\(entry.key),"]
        let names = entry.fieldOrder.filter { !(entry.fields[$0] ?? "").isEmpty }
        for (index, name) in names.enumerated() {
            let comma = index == names.count - 1 ? "" : ","
            lines.append("  \(name) = {\(entry.fields[name] ?? "")}\(comma)")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    // MARK: LaTeX text

    private static let accents: [Character: Character] = [
        "\"": "\u{0308}", "'": "\u{0301}", "`": "\u{0300}", "^": "\u{0302}", "~": "\u{0303}",
        "=": "\u{0304}", ".": "\u{0307}", "c": "\u{0327}", "v": "\u{030C}", "u": "\u{0306}",
        "H": "\u{030B}", "k": "\u{0328}",
    ]
    private static let symbols: [String: String] = [
        "ss": "ß", "o": "ø", "O": "Ø", "ae": "æ", "AE": "Æ", "aa": "å", "AA": "Å", "oe": "œ", "OE": "Œ",
        "l": "ł", "L": "Ł", "i": "ı", "j": "ȷ", "textendash": "–", "textemdash": "—", "textquoteright": "’",
    ]

    /// Turns BibTeX/LaTeX markup into plain text: accents, escaped characters, dashes and
    /// case-protecting braces.
    public static func decodeLaTeX(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                // Letter accents (\c, \v, \u, \H, \k) only count when an argument follows,
                // so commands such as \cite are not mistaken for them.
                if let mark = accents[next], i + 2 < chars.count,
                   !next.isLetter || chars[i + 2] == "{" || chars[i + 2] == " " {
                    // \"o, \"{o}, \c{c}, \c c
                    var j = i + 2
                    while j < chars.count, chars[j] == " " { j += 1 }
                    var base: Character?
                    if j < chars.count, chars[j] == "{" {
                        // \"{o} or \"{\i}: the first letter inside the braces.
                        j += 1
                        while j < chars.count, chars[j] != "}" {
                            if base == nil, chars[j].isLetter { base = chars[j] }
                            j += 1
                        }
                        j += 1
                    } else if j < chars.count, chars[j].isLetter {
                        base = chars[j]
                        j += 1
                    }
                    if let base {
                        out += (String(base) + String(mark)).precomposedStringWithCanonicalMapping
                        i = j
                        continue
                    }
                }
                if "&%$#_{}".contains(next) {
                    out.append(next)
                    i += 2
                    continue
                }
                // A command word such as \ss or \textendash.
                var j = i + 1
                var word = ""
                while j < chars.count, chars[j].isLetter { word.append(chars[j]); j += 1 }
                if let symbol = symbols[word] {
                    out += symbol
                    if j < chars.count, chars[j] == " " { j += 1 }
                    i = j
                    continue
                }
                if !word.isEmpty {
                    // Unknown command (\emph, \textit): drop the command, keep its argument.
                    i = j
                    continue
                }
                i += 1
                continue
            }
            if c == "{" || c == "}" { i += 1; continue }
            if c == "~" { out.append(" "); i += 1; continue }
            if c == "-", i + 2 < chars.count, chars[i + 1] == "-", chars[i + 2] == "-" {
                out += "—"; i += 3; continue
            }
            if c == "-", i + 1 < chars.count, chars[i + 1] == "-" {
                out += "–"; i += 2; continue
            }
            out.append(c)
            i += 1
        }
        return out.split(whereSeparator: { $0 == "\n" || $0 == "\t" || $0 == " " })
            .joined(separator: " ")
    }

    /// Escapes the characters BibTeX treats specially. Non-ASCII text is written as UTF-8,
    /// which BibLaTeX and modern BibTeX read directly.
    public static func encodeLaTeX(_ text: String) -> String {
        var out = ""
        for c in text {
            switch c {
            case "&", "%", "$", "#", "_": out += "\\\(c)"
            case "{", "}": out += "\\\(c)"
            case "\\": out += "\\textbackslash{}"
            case "–": out += "--"
            case "—": out += "---"
            default: out.append(c)
            }
        }
        return out
    }

    // MARK: Names

    /// Splits an author field on `and` (outside braces) and puts each name in
    /// "Last, First" form. Braced corporate names are kept whole.
    public static func authors(from field: String) -> [String] {
        var names: [String] = []
        var current = ""
        var depth = 0
        let words = field.split(separator: " ", omittingEmptySubsequences: true)
        for word in words {
            for c in word { if c == "{" { depth += 1 } else if c == "}" { depth -= 1 } }
            if depth == 0, word.lowercased() == "and", !current.isEmpty {
                names.append(current)
                current = ""
            } else {
                current += current.isEmpty ? String(word) : " " + word
            }
        }
        if !current.isEmpty { names.append(current) }
        return names.map(normalizeName).filter { !$0.isEmpty }
    }

    static func normalizeName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") { return decodeLaTeX(trimmed) }
        let name = decodeLaTeX(trimmed)
        if name.contains(",") || name == "others" { return name }
        let parts = name.split(separator: " ").map(String.init)
        guard parts.count > 1 else { return name }
        // "Ludwig van Beethoven": lower-case particles belong to the last name.
        var lastStart = parts.count - 1
        while lastStart > 1, parts[lastStart - 1].first?.isLowercase == true { lastStart -= 1 }
        let last = parts[lastStart...].joined(separator: " ")
        let first = parts[..<lastStart].joined(separator: " ")
        return "\(last), \(first)"
    }

    // MARK: Sources

    /// What one BibTeX entry becomes in Atlas.
    public struct ImportedSource: Equatable, Sendable {
        public var title: String
        public var info: SourceInfo
        public var tags: [String]
    }

    /// Converts an entry to a source. Fields Atlas does not model are kept in
    /// `extraFields`, so exporting the source again writes them back.
    public static func source(from entry: BibEntry) -> ImportedSource {
        var info = SourceInfo(entryType: entry.type, citationKey: entry.key)
        var tags: [String] = []
        var extra: [String: String] = [:]
        for name in entry.fieldOrder {
            let raw = entry.fields[name] ?? ""
            let text = decodeLaTeX(raw)
            switch name {
            case "title": break
            case "author": info.authors = authors(from: raw)
            case "year": info.year = Int(text.prefix(4)) ?? info.year
            case "date": if info.year == nil { info.year = Int(text.prefix(4)) }
            case "publisher": info.publisher = text
            case "journal", "journaltitle", "booktitle": if info.container.isEmpty { info.container = text }
            case "volume": info.volume = text
            case "number", "issue": info.issue = text
            case "pages": info.pages = text
            case "url": info.url = raw.trimmingCharacters(in: .whitespaces)
            case "doi": info.doi = DOI.normalize(raw) ?? text
            case "isbn": info.isbn = text
            case "keywords":
                tags = text.split(whereSeparator: { $0 == "," || $0 == ";" }).map { Tags.normalize(String($0)) }
                    .filter { !$0.isEmpty }
            default: extra[name] = raw
            }
        }
        info.extraFields = extra
        let title = decodeLaTeX(entry["title"] ?? "")
        return ImportedSource(title: title.isEmpty ? (entry.key.isEmpty ? "Untitled Source" : entry.key) : title,
                              info: info, tags: tags)
    }

    /// The entry for a source, using its stored citation key.
    public static func entry(title: String, info: SourceInfo, tags: [String] = []) -> BibEntry {
        let type = info.entryType.isEmpty ? "misc" : info.entryType.lowercased()
        var entry = BibEntry(type: type, key: info.citationKey)
        if !info.authors.isEmpty { entry["author"] = info.authors.map(encodeLaTeX).joined(separator: " and ") }
        entry["title"] = encodeLaTeX(title)
        if !info.container.isEmpty {
            let containerField = ["inproceedings", "incollection", "inbook", "conference"].contains(type) ? "booktitle" : "journal"
            entry[containerField] = encodeLaTeX(info.container)
        }
        if let year = info.year { entry["year"] = String(year) }
        for (name, value) in [("volume", info.volume), ("number", info.issue), ("pages", info.pages),
                              ("publisher", info.publisher), ("isbn", info.isbn), ("doi", info.doi)] where !value.isEmpty {
            entry[name] = encodeLaTeX(value)
        }
        if !info.url.isEmpty { entry["url"] = info.url }
        if !tags.isEmpty { entry["keywords"] = encodeLaTeX(tags.joined(separator: ", ")) }
        for name in info.extraFields.keys.sorted() where entry[name] == nil {
            entry[name] = info.extraFields[name]
        }
        return entry
    }
}
