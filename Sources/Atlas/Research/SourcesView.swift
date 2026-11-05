import AppKit
import AtlasCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// One row of the sources table, flattened so every column can sort.
struct SourceRow: Identifiable {
    let id: UUID
    let title: String
    let authors: String
    let year: Int
    let container: String
    let key: String
    let used: Int
    let hasDocument: Bool
    let added: Date

    var yearText: String { year == Int.min ? "" : String(year) }
}

/// The sources library: a sortable, filterable table with a PDF beside it.
struct SourcesView: View {
    @Bindable var window: WindowState
    @Environment(Workspace.self) private var workspace
    @AppStorage("atlas.showInspector") private var showInspector = true
    @State private var sortOrder = [KeyPathComparator(\SourceRow.title)]
    @State private var search = ""
    @State private var tagFilter: String?
    @State private var yearFilter: Int?
    @State private var authorFilter: String?
    @State private var showLookup = false
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument = BibTeXDocument(text: "")
    @State private var message: String?
    @State private var isDropTargeted = false

    var body: some View {
        let rows = filteredRows()
        // The filter bar sits above the table (not as an inset over it, which hid the column
        // headers), and the split view exists only while a PDF is open, so the page never
        // asks for more width than the window has.
        VStack(spacing: 0) {
            filterBar(count: rows.count)
            if let id = window.openDocumentID, let url = workspace.document(of: id), let node = workspace.nodes[id] {
                HSplitView {
                    table(rows)
                        .frame(minWidth: 360, maxWidth: .infinity)
                    DocumentPane(url: url, source: node, workspace: workspace) { window.openDocumentID = nil }
                        .frame(minWidth: 320, idealWidth: 480, maxWidth: .infinity)
                }
            } else {
                table(rows)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Title, author, key")
        .navigationTitle("Sources")
        .toolbar { toolbar }
        .inspector(isPresented: $showInspector) {
            inspector.inspectorColumnWidth(min: 260, ideal: 300, max: 440)
        }
        .sheet(isPresented: $showLookup) {
            LookupSheet(workspace: workspace) { id in window.sourceSelection = [id] }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [BibTeXDocument.type, .plainText], allowsMultipleSelection: true) { result in
            importBibTeX(result)
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: BibTeXDocument.type,
                      defaultFilename: "Atlas Sources.bib") { _ in }
        .alert("Sources", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
        .onDrop(of: DropImport.acceptedTypes, isTargeted: $isDropTargeted) { providers in
            Task { await dropped(providers) }
            return true
        }
    }

    private func table(_ rows: [SourceRow]) -> some View {
        Table(rows, selection: $window.sourceSelection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title) { row in
                HStack(spacing: 5) {
                    if row.hasDocument { Image(systemName: "doc.richtext").foregroundStyle(.secondary).help("PDF attached") }
                    Text(row.title).lineLimit(1)
                    if MetadataService.shared.inFlight.contains(row.id) { ProgressView().controlSize(.mini) }
                }
                .draggable(DropImport.dragText(for: row.id))
            }
            .width(min: 160, ideal: 280)
            TableColumn("Authors", value: \.authors) { Text($0.authors).lineLimit(1) }
                .width(min: 90, ideal: 150)
            TableColumn("Year", value: \.year) { Text($0.yearText).monospacedDigit() }
                .width(min: 40, ideal: 50, max: 70)
            TableColumn("Journal / Publisher", value: \.container) { Text($0.container).lineLimit(1) }
                .width(min: 80, ideal: 140)
            TableColumn("Key", value: \.key) { Text($0.key).font(.system(.body, design: .monospaced)).lineLimit(1) }
                .width(min: 70, ideal: 120)
            TableColumn("Used", value: \.used) { row in
                Text(row.used == 0 ? "–" : "\(row.used)").monospacedDigit()
                    .help("Maps and nodes that use this source")
            }
            .width(min: 34, ideal: 44, max: 60)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            rowMenu(ids)
        } primaryAction: { ids in
            if let id = ids.first { openDocument(id) }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label(workspace.sourceNodes.isEmpty ? "No Sources Yet" : "No Matches", systemImage: "books.vertical")
                } description: {
                    Text(workspace.sourceNodes.isEmpty
                         ? "Add a source by DOI or link, import a BibTeX file, or drop PDFs here."
                         : "Clear the search or filters to see every source.")
                }
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 3).padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    private func filterBar(count: Int) -> some View {
        HStack(spacing: 10) {
            filterMenu("Tag", value: tagFilter.map { "#\($0)" }) {
                Button("Any Tag") { tagFilter = nil }
                Divider()
                ForEach(sourceTags, id: \.self) { tag in Button("#\(tag)") { tagFilter = tag } }
            }
            filterMenu("Year", value: yearFilter.map(String.init)) {
                Button("Any Year") { yearFilter = nil }
                Divider()
                ForEach(workspace.sourceYears, id: \.self) { year in Button(String(year)) { yearFilter = year } }
            }
            filterMenu("Author", value: authorFilter) {
                Button("Any Author") { authorFilter = nil }
                Divider()
                ForEach(workspace.sourceAuthors, id: \.self) { name in Button(name) { authorFilter = name } }
            }
            if tagFilter != nil || yearFilter != nil || authorFilter != nil {
                Button("Clear") { tagFilter = nil; yearFilter = nil; authorFilter = nil }
                    .buttonStyle(.link)
            }
            Spacer()
            Text("\(count) of \(workspace.sourceNodes.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func filterMenu<Content: View>(_ title: String, value: String?, @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            Text(value.map { "\(title): \($0)" } ?? title)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(value == nil ? Color.secondary : Color.accentColor)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        let selected = window.sourceSelection
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("New Source") {
                    let node = workspace.addSource(title: "Untitled Source")
                    window.sourceSelection = [node.id]
                    showInspector = true
                }
                Button("Add by DOI or Link…") { showLookup = true }
                Button("Import BibTeX…") { importing = true }
            } label: {
                Label("Add", systemImage: "plus")
            } primaryAction: {
                showLookup = true
            }
            .help("Add a source by DOI or link; more options in the menu")
            Button {
                exportDocument = BibTeXDocument(text: workspace.bibTeX(for: selected.isEmpty ? nil : Array(selected)))
                exporting = true
            } label: {
                Label("Export BibTeX", systemImage: "square.and.arrow.up")
            }
            .disabled(workspace.sourceNodes.isEmpty)
            .help(selected.isEmpty ? "Export every source as BibTeX" : "Export the selected sources as BibTeX")
            Button { copyCitations(selected) } label: { Label("Cite", systemImage: "quote.opening") }
                .disabled(selected.isEmpty)
                .help("Copy formatted references for the selected sources (⇧⌘C)")
            Button { if let id = selected.first { openDocument(id) } } label: {
                Label("Open PDF", systemImage: "doc.richtext")
            }
            .disabled(selected.count != 1)
            .help("Show the source's PDF beside the library (double-click a row)")
            Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if window.sourceSelection.count == 1, let id = window.sourceSelection.first, let node = workspace.nodes[id] {
            NodeInspector(node: node, workspace: workspace)
        } else {
            ContentUnavailableView(window.sourceSelection.isEmpty ? "No Selection" : "\(window.sourceSelection.count) Sources",
                                   systemImage: "books.vertical",
                                   description: Text("Select a source to see its details, quotes and where it is used."))
        }
    }

    @ViewBuilder
    private func rowMenu(_ ids: Set<UUID>) -> some View {
        if ids.count == 1, let id = ids.first {
            Button("Open PDF") { openDocument(id) }
            Button("Attach PDF…") { attachDocument(to: id) }
            Button("Fetch Details") { MetadataService.shared.fetch(id, workspace: workspace) }
            Divider()
        }
        Button("Copy Citation") { copyCitations(ids) }
        Button("Copy BibTeX") { copy(workspace.bibTeX(for: Array(ids))) }
        Menu("Add to Map") {
            ForEach(workspace.sortedMaps) { map in
                Button(map.name) {
                    let parent = workspace.tree(of: map.id).roots.first
                    workspace.perform("Add to Map") { _ in
                        for id in ids {
                            let point = parent.map { workspace.suggestedChildPosition(parent: $0, in: map.id) } ?? .zero
                            workspace.placeNode(id, on: map.id, at: point, parent: parent)
                        }
                    }
                }
            }
        }
        Menu("New Literature Review from Selection") {
            Button("Create Map") {
                let map = workspace.createMap(from: .literatureReview, sources: Array(ids))
                window.selection = .map(map.id)
            }
        }
        Divider()
        Button("Delete", role: .destructive) {
            workspace.deleteNodes(ids, actionName: ids.count == 1 ? "Delete Source" : "Delete Sources")
        }
    }

    // MARK: Data

    private var sourceTags: [String] {
        Array(Set(workspace.sourceNodes.flatMap(\.tags))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func filteredRows() -> [SourceRow] {
        let words = search.lowercased().split(separator: " ").map(String.init)
        let rows = workspace.sourceNodes.compactMap { node -> SourceRow? in
            guard let info = node.source else { return nil }
            if let tagFilter, !node.data.hasTag(tagFilter) { return nil }
            if let yearFilter, info.year != yearFilter { return nil }
            if let authorFilter, !info.authors.contains(where: { CitationKey.familyName($0) == authorFilter }) { return nil }
            if !words.isEmpty {
                let text = node.data.searchableText.lowercased()
                guard words.allSatisfy(text.contains) else { return nil }
            }
            return SourceRow(id: node.id, title: node.data.displayTitle,
                             authors: info.authors.map(CitationKey.familyName).joined(separator: ", "),
                             year: info.year ?? Int.min, container: info.container.isEmpty ? info.publisher : info.container,
                             key: info.citationKey, used: workspace.usage(of: node.id).count,
                             hasDocument: workspace.document(of: node.id) != nil, added: node.createdAt)
        }
        return rows.sorted(using: sortOrder)
    }

    // MARK: Actions

    private func openDocument(_ id: UUID) {
        if workspace.document(of: id) != nil {
            window.openDocumentID = id
        } else {
            attachDocument(to: id)
        }
    }

    private func attachDocument(to id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = "Choose the PDF for this source."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try workspace.attachFile(at: url, to: id)
            window.openDocumentID = id
        } catch {
            message = "The file could not be attached: \(error.localizedDescription)"
        }
    }

    private func copyCitations(_ ids: Set<UUID>) {
        let text = ids.compactMap { workspace.citationText(for: $0) }.sorted().joined(separator: "\n")
        copy(text)
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        MapController.pasteboard.clearContents()
        MapController.pasteboard.setString(text, forType: .string)
    }

    private func importBibTeX(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        var text = ""
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                text += (String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "") + "\n"
            }
        }
        let imported = workspace.importBibTeX(text)
        if imported.added.isEmpty, imported.merged.isEmpty {
            message = "No BibTeX entries were found in the file."
        } else {
            window.sourceSelection = Set(imported.added)
            message = "Imported \(imported.added.count) source\(imported.added.count == 1 ? "" : "s")"
                + (imported.merged.isEmpty ? "." : "; \(imported.merged.count) matched existing sources and filled in their missing details.")
        }
    }

    private func dropped(_ providers: [NSItemProvider]) async {
        let items = await DropImport.load(providers)
        var added: [UUID] = []
        for item in items {
            switch item {
            case .file(let url) where url.pathExtension.lowercased() == "bib":
                if let text = try? String(contentsOf: url, encoding: .utf8) { added += workspace.importBibTeX(text).added }
            case .file, .web:
                guard let (data, attach) = DropImport.node(for: item, workspace: workspace) else { continue }
                var source = data
                if source.source == nil { source.setKind(.source) }
                let node = workspace.addSource(title: source.title, info: source.source ?? SourceInfo(), actionName: "Add Source")
                if let attach { _ = try? workspace.attachFile(at: attach, to: node.id) }
                DropImport.finish(node.id, workspace: workspace)
                added.append(node.id)
            case .text(let text):
                if let doi = DOI.normalize(text) {
                    let node = workspace.addSource(title: "doi:\(doi)", info: SourceInfo(doi: doi), actionName: "Add Source")
                    MetadataService.shared.fetch(node.id, workspace: workspace)
                    added.append(node.id)
                } else {
                    added += workspace.importBibTeX(text).added
                }
            case .node(let id):
                workspace.convertToSources([id])
                added.append(id)
            case .imageData:
                continue
            }
        }
        if !added.isEmpty { window.sourceSelection = Set(added) }
    }
}

/// Adds a source by looking up a DOI or a web address.
private struct LookupSheet: View {
    let workspace: Workspace
    let created: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Source").font(.headline)
            Text("Paste a DOI (10.1038/…), a doi.org link, or the address of an article page. Atlas reads the details from Crossref or the page.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("DOI or link", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(lookUp)
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Without Details") { addBlank() }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                Button("Look Up", action: lookUp)
                    .keyboardShortcut(.defaultAction)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func lookUp() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        busy = true
        failure = nil
        Task {
            do {
                let found = try await MetadataFetcher().lookUp(text)
                let node = workspace.addSource(title: found.title, info: found.info, body: found.abstract, actionName: "Add Source")
                created(node.id)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            busy = false
        }
    }

    private func addBlank() {
        var data = CaptureParser.node(from: query)
        if data.source == nil { data.setKind(.source) }
        let node = workspace.addSource(title: data.title, info: data.source ?? SourceInfo(), actionName: "Add Source")
        created(node.id)
        dismiss()
    }
}

/// A source's PDF beside the library. Selecting text and pressing Add Quote makes a quote
/// card citing the source and page.
private struct DocumentPane: View {
    let url: URL
    let source: Node
    let workspace: Workspace
    let close: () -> Void
    @State private var view = PDFView()
    @State private var added: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(source.data.displayTitle, systemImage: "doc.richtext").lineLimit(1).font(.headline)
                Spacer()
                if let added { Text(added).font(.caption).foregroundStyle(.secondary) }
                Button("Add Quote", systemImage: "quote.bubble") { addQuote() }
                    .help("Make a quote card from the selected text, citing this page")
                Button("Open in Preview", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
                    .labelStyle(.iconOnly)
                    .help("Open the PDF in Preview")
                Button("Close", systemImage: "xmark") { close() }
                    .labelStyle(.iconOnly)
                    .keyboardShortcut(.cancelAction)
                    .help("Close the PDF")
            }
            .buttonStyle(.borderless)
            .padding(8)
            Divider()
            PDFKitView(url: url, view: view)
        }
    }

    private func addQuote() {
        guard let selection = view.currentSelection, let text = selection.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            added = "Select some text first"
            return
        }
        var page = ""
        if let first = selection.pages.first {
            if let label = first.label { page = label } else if let document = first.document { page = String(document.index(for: first) + 1) }
        }
        workspace.addQuote(text, page: page, sourceID: source.id)
        added = page.isEmpty ? "Quote added" : "Quote added (p. \(page))"
    }
}

private struct PDFKitView: NSViewRepresentable {
    let url: URL
    let view: PDFView

    func makeNSView(context: Context) -> PDFView {
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url { nsView.document = PDFDocument(url: url) }
    }
}

/// A `.bib` file for the exporter.
struct BibTeXDocument: FileDocument {
    static let type = UTType(filenameExtension: "bib", conformingTo: .plainText) ?? .plainText
    static var readableContentTypes: [UTType] { [type, .plainText] }

    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
