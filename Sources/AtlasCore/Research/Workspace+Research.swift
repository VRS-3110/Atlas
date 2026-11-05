import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Capture, Inbox triage, the sources library, citations and attachments.
extension Workspace {

    // MARK: Capture and Inbox

    /// Adds typed or dropped text to the Inbox (see `CaptureParser` for the rules).
    @discardableResult
    public func capture(_ text: String, kind: NodeKind? = nil) -> Node? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var data = CaptureParser.node(from: trimmed, kind: kind, date: clock())
        if data.source != nil, var info = data.source {
            info.citationKey = CitationKey.unique(title: data.title, info: info, taken: citationKeys())
            data.source = info
        }
        return createNode(data, actionName: "Capture")
    }

    /// Adds ready-made nodes to the Inbox as one step (used for drops).
    @discardableResult
    public func addToInbox(_ items: [NodeData], actionName: String = "Add to Inbox") -> [Node] {
        guard !items.isEmpty else { return [] }
        return perform(actionName) { tx in
            items.map { item in
                var data = item
                data.inbox = .inbox
                return tx.insert(data)
            }
        }
    }

    /// Archives Inbox items: kept, searchable from the Inbox's Archived list, but out of the way.
    public func archive(_ ids: some Sequence<UUID>) {
        perform("Archive") { tx in
            for id in ids { if let node = nodes[id] { tx.update(node) { $0.inbox = .archived } } }
        }
    }

    /// Puts archived items back in the Inbox.
    public func unarchive(_ ids: some Sequence<UUID>) {
        perform("Move to Inbox") { tx in
            for id in ids { if let node = nodes[id], node.inbox == .archived { tx.update(node) { $0.inbox = .inbox } } }
        }
    }

    public var archivedNodes: [Node] {
        nodes.values.filter { $0.inbox == .archived }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Makes nodes sources (filed in the sources library) with a citation key each.
    public func convertToSources(_ ids: some Sequence<UUID>) {
        perform("Make Source") { tx in
            var taken = citationKeys()
            for id in ids {
                guard let node = nodes[id] else { continue }
                tx.update(node) { data in
                    data.setKind(.source)
                    var info = data.source ?? SourceInfo()
                    if info.url.isEmpty, let link = data.link { info.url = link }
                    if info.citationKey.isEmpty {
                        info.citationKey = CitationKey.unique(title: data.title, info: info, taken: taken)
                        taken.insert(info.citationKey)
                    }
                    data.source = info
                    if data.inbox != .none { data.inbox = .none }
                }
            }
        }
    }

    /// Turns nodes into tasks (filed in the planner). The node keeps its own kind and stays
    /// on its maps, which show the task's status.
    public func convertToTasks(_ ids: some Sequence<UUID>) {
        perform("Make Task") { tx in
            for id in ids {
                guard let node = nodes[id] else { continue }
                tx.update(node) { data in
                    if data.task == nil { data.task = TaskInfo() }
                    if data.inbox != .none { data.inbox = .none }
                }
            }
        }
    }

    // MARK: Sources

    /// Every citation key in use.
    public func citationKeys(excluding excluded: UUID? = nil) -> Set<String> {
        Set(nodes.values.compactMap { $0.id == excluded ? nil : $0.source?.citationKey }.filter { !$0.isEmpty })
    }

    /// Creates a source in the library, giving it a unique citation key if it has none.
    @discardableResult
    public func addSource(title: String, info: SourceInfo = SourceInfo(), body: String = "", tags: [String] = [],
                          actionName: String = "New Source") -> Node {
        var info = info
        if info.citationKey.isEmpty || citationKeys().contains(info.citationKey) {
            info.citationKey = CitationKey.unique(title: title, info: info, taken: citationKeys())
        }
        return createNode(NodeData(title: title, body: body, kind: .source, tags: tags, createdAt: clock(), source: info),
                          actionName: actionName)
    }

    /// A fresh citation key for a source from its current title, authors and year.
    public func regenerateCitationKey(_ sourceID: UUID) {
        guard let node = nodes[sourceID], var info = node.source else { return }
        info.citationKey = CitationKey.unique(title: node.title, info: info, taken: citationKeys(excluding: sourceID))
        updateNode(node, "Regenerate Citation Key") { $0.source = info }
    }

    /// Fills a source from fetched metadata. Fields the user already filled in are kept;
    /// a placeholder title (the link itself) is replaced.
    public func applyMetadata(_ fetched: FetchedMetadata, to sourceID: UUID) {
        guard let node = nodes[sourceID] else { return }
        // A key Atlas generated (rather than one the user typed) follows the new details.
        let oldKey = node.source?.citationKey ?? ""
        let keyWasGenerated = oldKey.isEmpty || oldKey.hasPrefix(CitationKey.base(title: node.title, info: node.source ?? SourceInfo()))
        updateNode(node, "Fetch Details") { data in
            let placeholder = data.title.isEmpty || data.title.hasPrefix("doi:") || data.title == data.link
                || data.link.flatMap(URL.init(string:)).map { CaptureParser.placeholderTitle(for: $0) == data.title } == true
                || data.source.map { $0.url == data.title || $0.doi == data.title } == true
                || data.attachments.contains { ($0.originalName as NSString).deletingPathExtension == data.title }
            if placeholder, !fetched.title.isEmpty { data.title = fetched.title }
            data.setKind(.source)
            var info = data.source ?? SourceInfo()
            let new = fetched.info
            if info.authors.isEmpty { info.authors = new.authors }
            if info.year == nil { info.year = new.year }
            if info.entryType == "misc" || info.entryType.isEmpty { info.entryType = new.entryType }
            for keyPath in [\SourceInfo.publisher, \.container, \.volume, \.issue, \.pages, \.url, \.doi, \.isbn]
                where info[keyPath: keyPath].isEmpty {
                info[keyPath: keyPath] = new[keyPath: keyPath]
            }
            info.extraFields.merge(new.extraFields) { current, _ in current }
            data.source = info
            if data.body.isEmpty, !fetched.abstract.isEmpty { data.body = fetched.abstract }
        }
        if keyWasGenerated { regenerateCitationKey(sourceID) }
    }

    /// The result of a BibTeX import.
    public struct BibImportResult: Equatable, Sendable {
        public var added: [UUID] = []
        /// Entries matching an existing source (same DOI or citation key); their empty fields were filled in.
        public var merged: [UUID] = []
        public var skipped = 0
    }

    /// Imports BibTeX as one undo step. An entry matching an existing source by DOI or
    /// citation key fills in that source's empty fields instead of adding a duplicate.
    @discardableResult
    public func importBibTeX(_ text: String) -> BibImportResult {
        let entries = BibTeX.parse(text)
        var result = BibImportResult()
        guard !entries.isEmpty else { return result }
        perform(entries.count == 1 ? "Import Source" : "Import Sources") { tx in
            var taken = citationKeys()
            for entry in entries {
                let imported = BibTeX.source(from: entry)
                if let existing = matchingSource(doi: imported.info.doi, key: imported.info.citationKey) {
                    tx.update(existing) { data in
                        var info = data.source ?? SourceInfo()
                        let new = imported.info
                        if info.authors.isEmpty { info.authors = new.authors }
                        if info.year == nil { info.year = new.year }
                        for keyPath in [\SourceInfo.publisher, \.container, \.volume, \.issue, \.pages, \.url, \.doi, \.isbn]
                            where info[keyPath: keyPath].isEmpty {
                            info[keyPath: keyPath] = new[keyPath: keyPath]
                        }
                        info.extraFields.merge(new.extraFields) { current, _ in current }
                        data.source = info
                        data.addTags(imported.tags)
                    }
                    result.merged.append(existing.id)
                    continue
                }
                var info = imported.info
                if info.citationKey.isEmpty || taken.contains(where: { $0.caseInsensitiveCompare(info.citationKey) == .orderedSame }) {
                    info.citationKey = CitationKey.unique(title: imported.title, info: info, taken: taken)
                }
                taken.insert(info.citationKey)
                let node = tx.insert(NodeData(title: imported.title, kind: .source, tags: imported.tags,
                                              createdAt: clock(), source: info))
                result.added.append(node.id)
            }
        }
        return result
    }

    func matchingSource(doi: String, key: String) -> Node? {
        sourceNodes.first { node in
            guard let info = node.source else { return false }
            if !doi.isEmpty, info.doi.caseInsensitiveCompare(doi) == .orderedSame { return true }
            return !key.isEmpty && info.citationKey == key
        }
    }

    /// BibTeX for the given sources (all sources when `ids` is nil), sorted by citation key.
    public func bibTeX(for ids: [UUID]? = nil) -> String {
        let sources = (ids?.compactMap { nodes[$0] } ?? sourceNodes).filter { $0.source != nil }
        let entries = sources.map { node in
            BibTeX.entry(title: node.title, info: node.source ?? SourceInfo(), tags: node.tags)
        }
        return BibTeX.format(entries.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending })
    }

    // MARK: Quotes and citations

    /// Creates a quote citing `sourceID` at `page`. It is placed on `mapID` when given;
    /// otherwise it lives in the source's quote list.
    @discardableResult
    public func addQuote(_ text: String, page: String = "", sourceID: UUID, on mapID: UUID? = nil,
                         at position: CGPoint = .zero, parent: UUID? = nil) -> Node? {
        guard nodes[sourceID]?.source != nil else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.count > 120 ? CaptureParser.shortened(trimmed, to: 100) : trimmed
        let body = trimmed.count > 120 ? trimmed : ""
        let data = NodeData(title: title.isEmpty ? "Quote" : title, body: body, kind: .quote, createdAt: clock(),
                            citations: [Citation(sourceID: sourceID, page: page)])
        if let mapID, maps[mapID] != nil {
            return addNode(data, to: mapID, at: position, parent: parent, actionName: "Add Quote")
        }
        return createNode(data, actionName: "Add Quote")
    }

    /// Quote nodes citing the source, in page order.
    public func quotes(of sourceID: UUID) -> [Node] {
        citingNodes(of: sourceID).filter { $0.kind == .quote }.sorted {
            let a = $0.citations.first { $0.sourceID == sourceID }?.page ?? ""
            let b = $1.citations.first { $0.sourceID == sourceID }?.page ?? ""
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    /// Links a node to a source (as evidence, a claim's support, a quote's origin…).
    public func addCitation(from nodeID: UUID, to sourceID: UUID, page: String = "") {
        guard let node = nodes[nodeID], nodeID != sourceID, nodes[sourceID]?.source != nil,
              !node.citations.contains(where: { $0.sourceID == sourceID }) else { return }
        updateNode(node, "Cite Source") { $0.citations.append(Citation(sourceID: sourceID, page: page)) }
    }

    public func removeCitation(from nodeID: UUID, to sourceID: UUID) {
        guard let node = nodes[nodeID] else { return }
        updateNode(node, "Remove Citation") { $0.citations.removeAll { $0.sourceID == sourceID } }
    }

    public func setCitationPage(_ page: String, from nodeID: UUID, to sourceID: UUID) {
        guard let node = nodes[nodeID] else { return }
        updateNode(node, "Edit Page", coalesce: "page-\(nodeID)") { data in
            for i in data.citations.indices where data.citations[i].sourceID == sourceID { data.citations[i].page = page }
        }
    }

    /// The text the Cite command copies: for a source its reference; for a quote the quote
    /// with an in-text citation and the reference; for anything else citing a source, the
    /// in-text citations and references of what it cites.
    public func citationText(for nodeID: UUID) -> String? {
        guard let node = nodes[nodeID] else { return nil }
        if let info = node.source {
            return CitationFormatter.reference(info, title: node.title)
        }
        let cited = node.citations.compactMap { c in nodes[c.sourceID].flatMap { s in s.source.map { (c, s, $0) } } }
        guard !cited.isEmpty else { return nil }
        if node.kind == .quote, let (citation, source, info) = cited.first {
            let text = node.body.isEmpty ? node.title : node.body
            return CitationFormatter.quote(text, page: citation.page, source: info, sourceTitle: source.title)
        }
        let inText = cited.map { CitationFormatter.inText($0.2, title: $0.1.title, page: $0.0.page) }.joined(separator: "; ")
        let references = cited.map { CitationFormatter.reference($0.2, title: $0.1.title) }.joined(separator: "\n")
        return "\(node.title) (\(inText))\n\n\(references)"
    }

    // MARK: Sources library

    /// Where a source is used: maps it is on, nodes citing it, and its quotes.
    public struct SourceUsage {
        public var maps: [MindMap] = []
        public var citing: [Node] = []
        public var quotes: [Node] = []
        public var count: Int { maps.count + citing.count }
    }

    public func usage(of sourceID: UUID) -> SourceUsage {
        let citing = citingNodes(of: sourceID)
        var mapIDs = Set(maps(containing: sourceID).map(\.id))
        for node in citing { mapIDs.formUnion(maps(containing: node.id).map(\.id)) }
        return SourceUsage(maps: sortedMaps.filter { mapIDs.contains($0.id) }, citing: citing,
                           quotes: citing.filter { $0.kind == .quote })
    }

    /// Distinct years and family names across the library, for the filter menus.
    public var sourceYears: [Int] { Array(Set(sourceNodes.compactMap { $0.source?.year })).sorted(by: >) }

    public var sourceAuthors: [String] {
        let names = sourceNodes.flatMap { $0.source?.authors.map(CitationKey.familyName) ?? [] }
        return Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Attachments

    public enum AttachmentError: LocalizedError {
        case noWorkspaceFolder
        public var errorDescription: String? { "Atlas has no folder to keep attachments in." }
    }

    /// Copies a file into the workspace's Attachments folder and attaches it to the node.
    /// A PDF attached to a source becomes the source's document. Copying is not undone
    /// with the attachment: undo detaches the file, which stays in the folder.
    @discardableResult
    public func attachFile(at fileURL: URL, to nodeID: UUID) throws -> Attachment? {
        guard let node = nodes[nodeID] else { return nil }
        guard let folder = attachmentsFolder else { throw AttachmentError.noWorkspaceFolder }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID()
        let ext = fileURL.pathExtension
        let stored = ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
        let destination = folder.appendingPathComponent(stored)
        try fm.copyItem(at: fileURL, to: destination)
        let type = UTType(filenameExtension: ext)?.identifier ?? "public.data"
        let size = ((try? fm.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let attachment = Attachment(id: id, storedName: stored, originalName: fileURL.lastPathComponent,
                                    contentType: type, byteCount: size, addedAt: clock())
        updateNode(node, "Attach File") { data in
            data.attachments.append(attachment)
            if type == UTType.pdf.identifier, data.source != nil, data.source?.attachmentID == nil {
                data.source?.attachmentID = attachment.id
            }
        }
        return attachment
    }

    public func detach(_ attachmentID: UUID, from nodeID: UUID) {
        guard let node = nodes[nodeID] else { return }
        updateNode(node, "Remove Attachment") { data in
            data.attachments.removeAll { $0.id == attachmentID }
            if data.source?.attachmentID == attachmentID {
                data.source?.attachmentID = data.attachments.first { $0.contentType == UTType.pdf.identifier }?.id
            }
        }
    }

    public func url(of attachment: Attachment) -> URL? {
        attachmentsFolder?.appendingPathComponent(attachment.storedName)
    }

    /// The PDF (or other file) holding a source, if one is attached.
    public func document(of nodeID: UUID) -> URL? {
        guard let node = nodes[nodeID] else { return nil }
        let attachment = node.source?.attachmentID.flatMap { id in node.attachments.first { $0.id == id } }
            ?? node.attachments.first { $0.contentType == UTType.pdf.identifier }
        return attachment.flatMap(url(of:))
    }
}
