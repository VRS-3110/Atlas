import AppKit
import AtlasCore
import Observation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// What arrived in a drop, once its item providers have been read.
enum DroppedItem {
    /// A node dragged from elsewhere in Atlas (Inbox, sources, backlog).
    case node(UUID)
    case file(URL)
    case web(URL)
    case text(String)
    /// Image data without a file (for example an image dragged out of a web page).
    case imageData(Data, name: String)
}

/// Reads drops from Safari, Preview, Finder and Atlas itself, and turns them into nodes.
@MainActor
enum DropImport {
    /// Atlas drags its own nodes as text with this prefix.
    static let nodePrefix = "atlas-node:"

    static let acceptedTypes: [UTType] = [.fileURL, .url, .utf8PlainText, .plainText, .image]

    static func dragText(for nodeID: UUID) -> String { nodePrefix + nodeID.uuidString }

    static func nodeID(fromDragText text: String) -> UUID? {
        guard text.hasPrefix(nodePrefix) else { return nil }
        return UUID(uuidString: String(text.dropFirst(nodePrefix.count)))
    }

    // MARK: Reading providers

    static func load(_ providers: [NSItemProvider]) async -> [DroppedItem] {
        var items: [DroppedItem] = []
        for provider in providers {
            if let item = await load(provider) { items.append(item) }
        }
        return items
    }

    private static func load(_ provider: NSItemProvider) async -> DroppedItem? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadURL(provider, type: .fileURL), url.isFileURL {
            return .file(url)
        }
        if provider.canLoadObject(ofClass: String.self), let text = await loadString(provider) {
            if let id = nodeID(fromDragText: text) { return .node(id) }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true, !trimmed.contains(" ") {
                return .web(url)
            }
            if !trimmed.isEmpty { return .text(trimmed) }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = await loadURL(provider, type: .url) {
            return url.isFileURL ? .file(url) : .web(url)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = await loadData(provider, type: .image) {
            return .imageData(data, name: provider.suggestedName ?? "Image")
        }
        return nil
    }

    private static func loadURL(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                continuation.resume(returning: url)
            }
        }
    }

    private static func loadString(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { string, _ in continuation.resume(returning: string) }
        }
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: Making nodes

    /// A node for a dropped item, plus a file to attach once it exists.
    static func node(for item: DroppedItem, workspace: Workspace) -> (data: NodeData, attach: URL?)? {
        let now = workspace.clock()
        switch item {
        case .node:
            return nil
        case .file(let url):
            let type = UTType(filenameExtension: url.pathExtension)
            let name = url.deletingPathExtension().lastPathComponent
            if type?.conforms(to: .pdf) == true {
                var info = SourceInfo()
                info.citationKey = CitationKey.unique(title: name, info: info, taken: workspace.citationKeys())
                return (NodeData(title: name, kind: .source, createdAt: now, source: info), url)
            }
            return (NodeData(title: name, kind: .note, createdAt: now), url)
        case .web(let url):
            var data = CaptureParser.node(from: url.absoluteString, date: now)
            if var info = data.source {
                info.citationKey = CitationKey.unique(title: data.title, info: info, taken: workspace.citationKeys())
                data.source = info
            }
            data.inbox = .none
            return (data, nil)
        case .text(let text):
            let title = text.count > 120 ? text.prefix(100).split(separator: " ").dropLast().joined(separator: " ") + "…" : text
            let body = text.count > 120 ? text : ""
            return (NodeData(title: String(title), body: body, kind: .quote, createdAt: now), nil)
        case .imageData(let data, let name):
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(name)").appendingPathExtension("png")
            guard (try? data.write(to: url)) != nil else { return nil }
            return (NodeData(title: name, kind: .note, createdAt: now), url)
        }
    }

    /// Adds dropped items to the Inbox. Returns how many were added.
    @discardableResult
    static func addToInbox(_ items: [DroppedItem], workspace: Workspace) -> Int {
        var count = 0
        workspace.perform(items.count == 1 ? "Add to Inbox" : "Add \(items.count) Items to Inbox") { _ in
            for item in items {
                if case .node(let id) = item, let node = workspace.nodes[id], node.inbox == .archived {
                    workspace.unarchive([id])
                    count += 1
                    continue
                }
                guard let (data, attach) = node(for: item, workspace: workspace) else { continue }
                let added = workspace.addToInbox([data]).first
                if let added, let attach { _ = try? workspace.attachFile(at: attach, to: added.id) }
                if let added { finish(added.id, workspace: workspace) }
                count += 1
            }
        }
        return count
    }

    /// Adds dropped items to a map: onto the node under the drop point as children, or as
    /// free nodes at the drop point. Atlas nodes dropped here are placed on the map.
    static func addToMap(_ items: [DroppedItem], controller: MapController, atView point: CGPoint) {
        let workspace = controller.workspace
        let target = controller.node(atView: point)
        var world = controller.worldPoint(point)
        var placed: [UUID] = []
        workspace.perform("Drop on Map") { _ in
            for item in items {
                let id: UUID
                if case .node(let existing) = item {
                    guard workspace.nodes[existing] != nil, existing != target else { continue }
                    workspace.placeNode(existing, on: controller.mapID, at: world, parent: target)
                    id = existing
                } else {
                    guard let (data, attach) = node(for: item, workspace: workspace) else { continue }
                    let created = workspace.addNode(data, to: controller.mapID, at: world, parent: target, actionName: "Drop on Map")
                    if let attach { _ = try? workspace.attachFile(at: attach, to: created.id) }
                    id = created.id
                }
                placed.append(id)
                world.y += 56
            }
        }
        for id in placed { finish(id, workspace: workspace) }
        if let first = placed.first {
            controller.select(first)
            for id in placed.dropFirst() { controller.select(id, extending: true) }
        }
    }

    /// Fills in sources: details from the web for links and DOIs, and from the PDF itself.
    static func finish(_ nodeID: UUID, workspace: Workspace) {
        guard let node = workspace.nodes[nodeID], node.source != nil else { return }
        if let pdf = workspace.document(of: nodeID) {
            MetadataService.shared.readPDF(pdf, into: nodeID, workspace: workspace)
        } else {
            MetadataService.shared.fetch(nodeID, workspace: workspace)
        }
    }
}

/// Looks up source details in the background and applies them when they arrive.
@MainActor
@Observable
final class MetadataService {
    static let shared = MetadataService()

    /// Sources being looked up right now.
    private(set) var inFlight: Set<UUID> = []
    /// The last failure per source, shown in the inspector.
    private(set) var failures: [UUID: String] = [:]
    @ObservationIgnored private let fetcher = MetadataFetcher()

    /// Looks up the source by its DOI, or else its web address.
    func fetch(_ nodeID: UUID, workspace: Workspace) {
        guard let info = workspace.nodes[nodeID]?.source, !inFlight.contains(nodeID) else { return }
        let query = !info.doi.isEmpty ? info.doi : !info.url.isEmpty ? info.url : (workspace.nodes[nodeID]?.link ?? "")
        guard !query.isEmpty else { return }
        lookUp(query, into: nodeID, workspace: workspace)
    }

    /// Looks up `query` (a DOI or link) and applies what it finds to the source.
    func lookUp(_ query: String, into nodeID: UUID, workspace: Workspace) {
        inFlight.insert(nodeID)
        failures[nodeID] = nil
        Task {
            do {
                let result = try await fetcher.lookUp(query)
                workspace.applyMetadata(result, to: nodeID)
            } catch {
                failures[nodeID] = error.localizedDescription
            }
            inFlight.remove(nodeID)
        }
    }

    /// Uses a PDF's own title and author, and looks up a DOI printed on its first pages.
    func readPDF(_ url: URL, into nodeID: UUID, workspace: Workspace) {
        guard let document = PDFDocument(url: url) else { return }
        let attributes = document.documentAttributes ?? [:]
        var text = ""
        for index in 0..<min(document.pageCount, 2) { text += document.page(at: index)?.string ?? "" }
        if let doi = DOI.normalize(text) {
            if let node = workspace.nodes[nodeID] {
                workspace.updateNode(node, "Fetch Details") { $0.source?.doi = doi }
            }
            lookUp(doi, into: nodeID, workspace: workspace)
            return
        }
        let title = (attributes[PDFDocumentAttribute.titleAttribute] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let author = (attributes[PDFDocumentAttribute.authorAttribute] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard title.count > 3 || !author.isEmpty else { return }
        var info = SourceInfo()
        info.authors = author.isEmpty ? [] : BibTeX.authors(from: author.replacingOccurrences(of: ";", with: " and "))
        if let date = attributes[PDFDocumentAttribute.creationDateAttribute] as? Date {
            info.year = Calendar.current.component(.year, from: date)
        }
        workspace.applyMetadata(FetchedMetadata(title: title, info: info), to: nodeID)
    }
}
