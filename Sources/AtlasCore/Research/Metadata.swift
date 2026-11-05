import Foundation

/// Digital Object Identifiers: finding them in text and normalising them.
public enum DOI {
    /// The DOI in `text` (a bare DOI, `doi:` prefix or doi.org link), lower-cased prefix
    /// kept as written, trailing punctuation removed. Nil when there is none.
    public static func normalize(_ text: String) -> String? {
        let decoded = text.removingPercentEncoding ?? text
        guard let range = decoded.range(of: #"10\.\d{4,9}/[^\s"'<>{}]+"#, options: .regularExpression) else { return nil }
        var doi = String(decoded[range])
        while let last = doi.last, ".,;:)]".contains(last) {
            // Keep a closing parenthesis that has a matching opening one inside the DOI.
            if last == ")", doi.filter({ $0 == "(" }).count >= doi.filter({ $0 == ")" }).count { break }
            doi.removeLast()
        }
        return doi
    }

    public static func url(for doi: String) -> URL? {
        URL(string: "https://doi.org/" + (doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi))
    }
}

/// A source's details as fetched from Crossref or a web page.
public struct FetchedMetadata: Equatable, Sendable {
    public var title: String
    public var info: SourceInfo
    public var abstract: String

    public init(title: String, info: SourceInfo, abstract: String = "") {
        self.title = title
        self.info = info
        self.abstract = abstract
    }
}

/// Reads the JSON that `https://api.crossref.org/works/<doi>` returns.
public enum CrossrefParser {
    public enum ParseError: Error { case notAWork }

    public static func parse(_ data: Data) throws -> FetchedMetadata {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.notAWork }
        let work = (root["message"] as? [String: Any]) ?? root
        guard work["DOI"] != nil || work["title"] != nil else { throw ParseError.notAWork }
        func first(_ key: String) -> String {
            if let list = work[key] as? [String] { return list.first ?? "" }
            return work[key] as? String ?? ""
        }
        var info = SourceInfo()
        info.entryType = entryType(forCrossref: work["type"] as? String ?? "")
        info.authors = ((work["author"] as? [[String: Any]]) ?? []).compactMap { author in
            if let family = author["family"] as? String {
                let given = author["given"] as? String ?? ""
                return given.isEmpty ? family : "\(family), \(given)"
            }
            return author["name"] as? String
        }
        for key in ["published-print", "published-online", "issued", "published", "created"] {
            if let parts = (work[key] as? [String: Any])?["date-parts"] as? [[Any]],
               let year = parts.first?.first.flatMap({ ($0 as? Int) ?? Int("\($0)") }) {
                info.year = year
                break
            }
        }
        info.container = first("container-title")
        info.publisher = work["publisher"] as? String ?? ""
        info.volume = work["volume"] as? String ?? ""
        info.issue = work["issue"] as? String ?? ""
        info.pages = (work["page"] as? String ?? "").replacingOccurrences(of: "-", with: "–")
        info.doi = work["DOI"] as? String ?? ""
        info.url = work["URL"] as? String ?? ""
        info.isbn = first("ISBN")
        var title = first("title")
        let subtitle = first("subtitle")
        if !subtitle.isEmpty, !title.isEmpty { title += ": " + subtitle }
        let abstract = stripTags(work["abstract"] as? String ?? "")
        return FetchedMetadata(title: collapse(stripTags(title)), info: info, abstract: abstract)
    }

    static func entryType(forCrossref type: String) -> String {
        switch type {
        case "journal-article": "article"
        case "proceedings-article": "inproceedings"
        case "book", "monograph", "edited-book", "reference-book": "book"
        case "book-chapter", "book-section", "book-part": "incollection"
        case "dissertation": "phdthesis"
        case "report", "report-series": "techreport"
        case "posted-content": "unpublished"
        default: "misc"
        }
    }
}

/// Reads citation metadata from a web page's `<head>`: Highwire `citation_*` tags (used by
/// most journals and preprint servers), Dublin Core, Open Graph and finally `<title>`.
public enum PageMetadataParser {
    public static func parse(html: String, url: URL?) -> FetchedMetadata {
        let metas = metaTags(in: html)
        func value(_ names: String...) -> String {
            for name in names { if let v = metas[name]?.first, !v.isEmpty { return v } }
            return ""
        }
        var info = SourceInfo(entryType: "misc")
        info.url = url?.absoluteString ?? ""
        info.authors = (metas["citation_author"] ?? metas["dc.creator"] ?? metas["author"] ?? [])
            .map { BibTeX.normalizeName($0) }
        let date = value("citation_publication_date", "citation_date", "citation_online_date", "dc.date",
                         "article:published_time", "date")
        if let range = date.range(of: #"\d{4}"#, options: .regularExpression) { info.year = Int(date[range]) }
        info.container = value("citation_journal_title", "citation_conference_title", "citation_book_title")
        info.publisher = value("citation_publisher", "dc.publisher", "og:site_name")
        info.volume = value("citation_volume")
        info.issue = value("citation_issue")
        let firstPage = value("citation_firstpage"), lastPage = value("citation_lastpage")
        info.pages = lastPage.isEmpty ? firstPage : "\(firstPage)–\(lastPage)"
        info.doi = DOI.normalize(value("citation_doi", "dc.identifier", "prism.doi")) ?? ""
        info.isbn = value("citation_isbn")
        if !info.container.isEmpty { info.entryType = metas["citation_conference_title"] != nil ? "inproceedings" : "article" }
        let pdf = value("citation_pdf_url")
        if !pdf.isEmpty { info.extraFields["pdfurl"] = pdf }
        var title = value("citation_title", "dc.title", "og:title", "twitter:title")
        if title.isEmpty, let range = html.range(of: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.regularExpression, .caseInsensitive]) {
            title = stripTags(String(html[range]))
        }
        if title.isEmpty { title = url?.host ?? "Untitled Page" }
        let abstract = value("citation_abstract", "dc.description", "description", "og:description")
        return FetchedMetadata(title: collapse(decodeEntities(title)), info: info, abstract: decodeEntities(abstract))
    }

    /// `<meta name|property="x" content="y">` pairs, names lower-cased; repeated names keep
    /// every value in order (several `citation_author` tags, for example).
    static func metaTags(in html: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        guard let regex = try? NSRegularExpression(pattern: #"<meta\s[^>]*>"#, options: [.caseInsensitive]) else { return result }
        let ns = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            guard let name = attribute("name", in: tag) ?? attribute("property", in: tag) ?? attribute("itemprop", in: tag),
                  let content = attribute("content", in: tag) else { continue }
            result[name.lowercased(), default: []].append(decodeEntities(content).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\b"# + name + #"\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        for group in 2...4 {
            let range = match.range(at: group)
            if range.location != NSNotFound { return (tag as NSString).substring(with: range) }
        }
        return nil
    }
}

/// Removes HTML/JATS tags such as `<jats:p>` and collapses the whitespace left behind.
func stripTags(_ text: String) -> String {
    collapse(decodeEntities(text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)))
}

func collapse(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

func decodeEntities(_ text: String) -> String {
    guard text.contains("&") else { return text }
    var out = text
    for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                           ("&apos;", "'"), ("&nbsp;", " "), ("&ndash;", "–"), ("&mdash;", "—")] {
        out = out.replacingOccurrences(of: entity, with: char)
    }
    // Numeric entities: &#8217; and &#x2019;
    while let range = out.range(of: #"&#(x[0-9a-fA-F]+|[0-9]+);"#, options: .regularExpression) {
        let body = out[range].dropFirst(2).dropLast()
        let value = body.hasPrefix("x") ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
        out.replaceSubrange(range, with: value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? "")
    }
    return out
}

/// Fetches metadata over the network. The transport is injectable so tests never go online.
public struct MetadataFetcher: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public enum FetchError: LocalizedError {
        case notFound
        case badResponse(Int)
        case nothingToLookUp

        public var errorDescription: String? {
            switch self {
            case .notFound: "No record was found for that identifier."
            case .badResponse(let code): "The server answered with status \(code)."
            case .nothingToLookUp: "Enter a DOI or a web address."
            }
        }
    }

    let transport: Transport

    public init(transport: Transport? = nil) {
        self.transport = transport ?? { request in try await URLSession.shared.data(for: request) }
    }

    /// Looks up a DOI, a doi.org link or any web address. Pages that carry a DOI in their
    /// metadata are completed from Crossref, which has the authoritative record.
    public func lookUp(_ input: String) async throws -> FetchedMetadata {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let doi = DOI.normalize(trimmed), !trimmed.lowercased().hasPrefix("http") || trimmed.contains("doi.org") {
            return try await crossref(doi)
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            if let doi = DOI.normalize(trimmed) { return try await crossref(doi) }
            throw FetchError.nothingToLookUp
        }
        var page = try await webPage(url)
        if !page.info.doi.isEmpty, var work = try? await crossref(page.info.doi) {
            if work.info.url.isEmpty { work.info.url = url.absoluteString }
            work.info.extraFields.merge(page.info.extraFields) { current, _ in current }
            if work.abstract.isEmpty { work.abstract = page.abstract }
            page = work
        }
        return page
    }

    public func crossref(_ doi: String) async throws -> FetchedMetadata {
        let escaped = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?
            .replacingOccurrences(of: "/", with: "%2F") ?? doi
        guard let url = URL(string: "https://api.crossref.org/works/\(escaped)") else { throw FetchError.notFound }
        let data = try await get(url, accept: "application/json")
        return try CrossrefParser.parse(data)
    }

    public func webPage(_ url: URL) async throws -> FetchedMetadata {
        let data = try await get(url, accept: "text/html,application/xhtml+xml")
        let html = String(decoding: data.prefix(2_000_000), as: UTF8.self)
        return PageMetadataParser.parse(html: html, url: url)
    }

    private func get(_ url: URL, accept: String) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Atlas/1.0 (macOS research app)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw http.statusCode == 404 ? FetchError.notFound : FetchError.badResponse(http.statusCode)
        }
        return data
    }
}
