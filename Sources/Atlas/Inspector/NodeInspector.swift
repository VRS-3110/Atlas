import AppKit
import AtlasCore
import SwiftUI

/// Everything about one node. Every field writes straight to the shared workspace, so the
/// map, the sidebar and other windows update as you type.
/// Whether a node keeps its place when an automatic layout runs, and how to change it.
struct PinControl {
    var isPinned: Bool
    var toggle: () -> Void
}

struct NodeInspector: View {
    let node: Node
    let workspace: Workspace
    var currentMapID: UUID?
    /// Shown for nodes on a map with an automatic layout.
    var pin: PinControl?
    @Environment(WindowState.self) private var window
    @State private var showPreview = false

    var body: some View {
        let data = node.data
        Form {
            Section {
                TextField("Title", text: binding(\.title, "Rename", coalesce: "title"), axis: .vertical)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1...6)
                KindGrid(selected: data.kind) { kind in
                    workspace.updateNode(node, "Change Type") { $0.setKind(kind) }
                }
            }

            Section("Colour") {
                ColorPalette(selected: data.color, defaultColor: data.kind.defaultColor) { color in
                    workspace.updateNode(node, "Change Colour") { $0.color = color }
                }
            }

            if let pin {
                Section {
                    Toggle("Pinned in place", isOn: Binding(get: { pin.isPinned }, set: { _ in pin.toggle() }))
                } header: {
                    Text("Layout")
                } footer: {
                    Text("A pinned node stays where you put it; the automatic layout arranges its branch around it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Tags") {
                TagEditor(tags: data.tags,
                          onAdd: { tags in workspace.updateNode(node, "Add Tag") { $0.addTags(tags) } },
                          onRemove: { tag in workspace.updateNode(node, "Remove Tag") { $0.removeTag(tag) } })
            }

            Section {
                if showPreview {
                    MarkdownPreview(text: data.body)
                } else {
                    TextEditor(text: binding(\.body, "Edit Notes", coalesce: "body"))
                        .font(.body)
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                }
            } header: {
                HStack {
                    Text("Notes")
                    Spacer()
                    Picker("Mode", selection: $showPreview) {
                        Text("Edit").tag(false)
                        Text("Preview").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            } footer: {
                Text("Markdown. Link other nodes with [[Title]].")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TaskSection(node: node, workspace: workspace)

            if data.source != nil {
                SourceSection(node: node, workspace: workspace)
            }

            CitesSection(node: node, workspace: workspace, currentMapID: currentMapID)

            if !data.attachments.isEmpty {
                AttachmentsSection(node: node, workspace: workspace)
            }

            BacklinksSection(node: node, workspace: workspace, currentMapID: currentMapID)

            Section("Info") {
                LabeledContent("Created", value: data.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Modified", value: data.updatedAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .formStyle(.grouped)
    }

    /// A binding that writes through the workspace. Typing coalesces into one undo step.
    private func binding<T: Equatable>(_ keyPath: WritableKeyPath<NodeData, T>, _ action: String,
                                       coalesce: String? = nil) -> Binding<T> {
        Binding(
            get: { node.data[keyPath: keyPath] },
            set: { value in
                guard node.data[keyPath: keyPath] != value else { return }
                workspace.updateNode(node, action, coalesce: coalesce.map { "\($0)-\(node.id.uuidString)" }) {
                    $0[keyPath: keyPath] = value
                }
            }
        )
    }
}

/// Task planning fields, or a button that turns the node into a task.
private struct TaskSection: View {
    let node: Node
    let workspace: Workspace

    var body: some View {
        if let task = node.task {
            Section("Task") {
                Picker("Status", selection: taskBinding(\.status, task)) {
                    ForEach(TaskStatus.allCases) { Label($0.title, systemImage: $0.symbolName).tag($0) }
                }
                Picker("Priority", selection: taskBinding(\.priority, task)) {
                    ForEach(TaskPriority.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Due Date", isOn: Binding(
                    get: { task.due != nil },
                    set: { on in update("Set Due Date") { $0.due = on ? Calendar.current.startOfDay(for: .now).addingTimeInterval(86_400) : nil } }
                ))
                if let due = task.due {
                    DatePicker("Due", selection: Binding(get: { due }, set: { d in update("Set Due Date") { $0.due = d } }),
                               displayedComponents: .date)
                }
                if task.journeyManMinutes >= 1 {
                    LabeledContent("Tracked in JourneyMan", value: JourneyManLink.durationText(minutes: task.journeyManMinutes))
                }
                if let url = JourneyManSync.shared.taskURL(for: node.id) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open in JourneyMan", systemImage: "arrow.up.forward.app")
                    }
                }
                Button("Remove Task", role: .destructive) {
                    workspace.updateNode(node, "Remove Task") { $0.task = nil }
                }
                .disabled(node.kind == .task)
            }
        } else {
            Section {
                Button {
                    workspace.updateNode(node, "Make Task") { $0.task = TaskInfo() }
                } label: {
                    Label("Make Task", systemImage: "checkmark.circle")
                }
            }
        }
    }

    private func update(_ action: String, _ mutate: @escaping (inout TaskInfo) -> Void) {
        workspace.updateNode(node, action) { data in
            guard var task = data.task else { return }
            mutate(&task)
            data.task = task
        }
    }

    private func taskBinding<T: Equatable>(_ keyPath: WritableKeyPath<TaskInfo, T>, _ task: TaskInfo) -> Binding<T> {
        Binding(get: { node.task?[keyPath: keyPath] ?? task[keyPath: keyPath] },
                set: { value in
                    let now = workspace.clock()
                    update("Edit Task") { t in
                        if keyPath == \TaskInfo.status, let status = value as? TaskStatus {
                            t.setStatus(status, at: now)
                        } else {
                            t[keyPath: keyPath] = value
                        }
                    }
                })
    }
}

/// Bibliographic fields for source nodes, its document, quotes and citation.
private struct SourceSection: View {
    let node: Node
    let workspace: Workspace
    @Environment(WindowState.self) private var window
    @State private var newQuote = ""
    @State private var newPage = ""

    private static let entryTypes = ["article", "book", "incollection", "inproceedings", "phdthesis", "mastersthesis",
                                     "techreport", "unpublished", "online", "misc"]

    var body: some View {
        let service = MetadataService.shared
        Section("Source") {
            Picker("Type", selection: Binding(get: { node.source?.entryType ?? "misc" },
                                              set: { value in edit("Edit Source Type") { $0.entryType = value } })) {
                ForEach(Self.entryTypes, id: \.self) { Text($0).tag($0) }
                if let type = node.source?.entryType, !Self.entryTypes.contains(type) { Text(type).tag(type) }
            }
            TextField("Authors", text: Binding(
                get: { node.source?.authors.joined(separator: "; ") ?? "" },
                set: { text in
                    let authors = text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    edit("Edit Authors") { $0.authors = authors }
                }
            ), prompt: Text("Last, First; Last, First"))
            TextField("Year", text: Binding(
                get: { node.source?.year.map(String.init) ?? "" },
                set: { text in edit("Edit Year") { $0.year = Int(text.trimmingCharacters(in: .whitespaces)) } }
            ))
            field("Journal / Container", \.container)
            field("Volume", \.volume)
            field("Issue", \.issue)
            field("Pages", \.pages)
            field("Publisher", \.publisher)
            field("URL", \.url)
            field("DOI", \.doi)
            field("ISBN", \.isbn)
            LabeledContent("Citation Key") {
                HStack {
                    TextField("Citation Key", text: Binding(
                        get: { node.source?.citationKey ?? "" },
                        set: { value in edit("Edit Citation Key") { $0.citationKey = value.replacingOccurrences(of: " ", with: "") } }
                    ))
                    .labelsHidden()
                    .font(.system(.body, design: .monospaced))
                    Button { workspace.regenerateCitationKey(node.id) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Make a new key from the first author, year and title")
                }
            }
            HStack {
                Button {
                    MetadataService.shared.fetch(node.id, workspace: workspace)
                } label: {
                    Label("Fetch Details", systemImage: "arrow.down.circle")
                }
                .disabled(service.inFlight.contains(node.id) || (node.source?.doi.isEmpty != false && node.source?.url.isEmpty != false))
                .help("Fill empty fields from Crossref (DOI) or the web page (URL)")
                if service.inFlight.contains(node.id) { ProgressView().controlSize(.small) }
                Spacer()
                Button { copyCitation() } label: { Label("Cite", systemImage: "quote.opening") }
                    .help("Copy a formatted reference (⇧⌘C)")
            }
            if let failure = service.failures[node.id] {
                Label(failure, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                if workspace.document(of: node.id) != nil {
                    Button { openDocument() } label: { Label("Open PDF", systemImage: "doc.richtext") }
                } else {
                    Button { attachPDF() } label: { Label("Attach PDF…", systemImage: "paperclip") }
                }
                if let url = node.source.flatMap({ URL(string: $0.doi.isEmpty ? $0.url : "https://doi.org/\($0.doi)") }),
                   url.scheme?.hasPrefix("http") == true {
                    Spacer()
                    Link(destination: url) { Label("Open Link", systemImage: "safari") }
                }
            }
        }
        Section("Quotes") {
            ForEach(workspace.quotes(of: node.id)) { quote in
                Button { window.reveal(quote.id, in: workspace) } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("“\(quote.data.displayTitle)”").lineLimit(3)
                        Spacer()
                        if let page = quote.citations.first(where: { $0.sourceID == node.id })?.page, !page.isEmpty {
                            Text("p. \(page)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Copy Citation") { copy(workspace.citationText(for: quote.id)) }
                    Button("Delete Quote", role: .destructive) { workspace.deleteNodes([quote.id], actionName: "Delete Quote") }
                }
            }
            HStack {
                TextField("New quote", text: $newQuote, axis: .vertical).lineLimit(1...4)
                TextField("Page", text: $newPage).frame(width: 46)
                Button("Add") {
                    workspace.addQuote(newQuote, page: newPage, sourceID: node.id)
                    newQuote = ""
                    newPage = ""
                }
                .disabled(newQuote.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func field(_ title: String, _ keyPath: WritableKeyPath<SourceInfo, String>) -> some View {
        TextField(title, text: Binding(
            get: { node.source?[keyPath: keyPath] ?? "" },
            set: { value in edit("Edit \(title)") { $0[keyPath: keyPath] = value } }
        ))
    }

    private func edit(_ action: String, _ mutate: (inout SourceInfo) -> Void) {
        workspace.updateNode(node, action, coalesce: "\(action)-\(node.id.uuidString)") { data in
            var info = data.source ?? SourceInfo()
            mutate(&info)
            data.source = info
        }
    }

    private func copyCitation() { copy(workspace.citationText(for: node.id)) }

    private func copy(_ text: String?) {
        guard let text else { return }
        MapController.pasteboard.clearContents()
        MapController.pasteboard.setString(text, forType: .string)
    }

    private func openDocument() {
        window.selection = .sources
        window.sourceSelection = [node.id]
        window.openDocumentID = node.id
    }

    private func attachPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = try? workspace.attachFile(at: url, to: node.id)
        DropImport.finish(node.id, workspace: workspace)
    }
}

/// The sources a node cites, with pages, and a way to cite another.
private struct CitesSection: View {
    let node: Node
    let workspace: Workspace
    var currentMapID: UUID?
    @Environment(WindowState.self) private var window

    var body: some View {
        let sources = workspace.sourceNodes.filter { $0.id != node.id }
        if node.source == nil, !node.citations.isEmpty || !sources.isEmpty {
            Section("Cites") {
                ForEach(node.citations, id: \.sourceID) { citation in
                    if let source = workspace.nodes[citation.sourceID] {
                        HStack {
                            Button { window.reveal(source.id, in: workspace, preferring: currentMapID) } label: {
                                Label(source.data.displayTitle, systemImage: "book.closed").lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            TextField("Page", text: Binding(get: { citation.page },
                                                            set: { workspace.setCitationPage($0, from: node.id, to: source.id) }))
                                .frame(width: 50)
                                .help("Page")
                            Button { workspace.removeCitation(from: node.id, to: source.id) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Stop citing this source")
                        }
                    }
                }
                HStack {
                    Menu("Cite a Source") {
                        ForEach(sources.filter { s in !node.citations.contains { $0.sourceID == s.id } }) { source in
                            Button(source.data.displayTitle) { workspace.addCitation(from: node.id, to: source.id) }
                        }
                    }
                    .disabled(sources.isEmpty)
                    if !node.citations.isEmpty {
                        Spacer()
                        Button { copy(workspace.citationText(for: node.id)) } label: { Label("Cite", systemImage: "quote.opening") }
                            .help("Copy this node with its citations (⇧⌘C)")
                    }
                }
            }
        }
    }

    private func copy(_ text: String?) {
        guard let text else { return }
        MapController.pasteboard.clearContents()
        MapController.pasteboard.setString(text, forType: .string)
    }
}

/// Files attached to the node.
private struct AttachmentsSection: View {
    let node: Node
    let workspace: Workspace

    var body: some View {
        Section("Attachments") {
            ForEach(node.attachments) { attachment in
                HStack {
                    Button {
                        if let url = workspace.url(of: attachment) { NSWorkspace.shared.open(url) }
                    } label: {
                        Label(attachment.originalName, systemImage: attachment.contentType == "com.adobe.pdf" ? "doc.richtext" : "doc")
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button("Show in Finder") {
                        if let url = workspace.url(of: attachment) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    Button("Remove", role: .destructive) { workspace.detach(attachment.id, from: node.id) }
                }
            }
        }
    }
}

/// Where the node appears and what points at it.
private struct BacklinksSection: View {
    let node: Node
    let workspace: Workspace
    var currentMapID: UUID?
    @Environment(WindowState.self) private var window

    var body: some View {
        let links = workspace.backlinks(of: node.id)
        Section("Appears On") {
            if links.maps.isEmpty {
                Text("Not on any map").foregroundStyle(.secondary)
            }
            ForEach(links.maps) { map in
                Button { window.reveal(node.id, in: workspace, preferring: map.id) } label: {
                    HStack {
                        Label(map.name, systemImage: "point.3.connected.trianglepath.dotted")
                        Spacer()
                        if map.id == currentMapID { Text("This map").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        if !links.incoming.isEmpty || !links.outgoing.isEmpty || !links.citedBy.isEmpty || !links.mentionedBy.isEmpty {
            Section("Linked") {
                ForEach(links.outgoing, id: \.edge.id) { item in
                    linkRow(item.node, detail: item.edge.data.displayLabel.isEmpty ? "→" : "\(item.edge.data.displayLabel) →")
                }
                ForEach(links.incoming, id: \.edge.id) { item in
                    linkRow(item.node, detail: item.edge.data.displayLabel.isEmpty ? "←" : "← \(item.edge.data.displayLabel)")
                }
                ForEach(links.citedBy) { citing in linkRow(citing, detail: "cites this") }
                ForEach(links.mentionedBy) { mention in linkRow(mention, detail: "mentions this") }
            }
        }
    }

    private func linkRow(_ other: Node, detail: String) -> some View {
        Button { window.reveal(other.id, in: workspace, preferring: currentMapID) } label: {
            HStack {
                Label(other.data.displayTitle, systemImage: other.kind.symbolName)
                    .foregroundStyle(other.data.effectiveColor.color)
                    .lineLimit(1)
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Renders Markdown inline (bold, italics, links, code), keeping line breaks.
struct MarkdownPreview: View {
    let text: String

    var body: some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let rendered = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        Group {
            if text.isEmpty {
                Text("No notes").foregroundStyle(.secondary)
            } else {
                Text(rendered).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
    }
}
