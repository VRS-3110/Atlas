import AtlasCore
import SwiftUI

/// Captured items waiting to be filed: onto a map, into the sources library, into the
/// planner, or into the archive.
struct InboxView: View {
    @Bindable var window: WindowState
    @Environment(Workspace.self) private var workspace
    @AppStorage("atlas.showInspector") private var showInspector = true
    @State private var showArchived = false
    @State private var captureText = ""
    @State private var isDropTargeted = false
    @FocusState private var captureFocused: Bool

    var body: some View {
        let items = showArchived ? workspace.archivedNodes : workspace.inboxNodes
        VStack(spacing: 0) {
            captureField
            Divider()
            if items.isEmpty {
                ContentUnavailableView {
                    Label(showArchived ? "No Archived Items" : "Inbox Zero", systemImage: showArchived ? "archivebox" : "tray")
                } description: {
                    Text(showArchived ? "Archived captures appear here." :
                        "Press \(CaptureShortcut.current == .off ? "the capture shortcut" : CaptureShortcut.current.title) anywhere in macOS, type above, or drop links, PDFs, images and text here.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $window.inboxSelection) {
                    ForEach(items) { node in
                        InboxRow(node: node)
                            .tag(node.id)
                            .draggable(DropImport.dragText(for: node.id))
                            .contextMenu { menu(for: window.inboxSelection.contains(node.id) ? window.inboxSelection : [node.id]) }
                    }
                }
                .onDeleteCommand { archiveOrDelete(window.inboxSelection) }
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 3).padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: DropImport.acceptedTypes, isTargeted: $isDropTargeted) { providers in
            Task {
                let dropped = await DropImport.load(providers)
                DropImport.addToInbox(dropped, workspace: workspace)
            }
            return true
        }
        .navigationTitle(showArchived ? "Archive" : "Inbox")
        .navigationSubtitle("\(items.count) item\(items.count == 1 ? "" : "s")")
        .toolbar { toolbar }
        .inspector(isPresented: $showInspector) {
            inspector.inspectorColumnWidth(min: 260, ideal: 300, max: 440)
        }
    }

    private var captureField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
            TextField("Capture an idea, question, link or DOI and press Return", text: $captureText)
                .textFieldStyle(.plain)
                .focused($captureFocused)
                .onSubmit {
                    if let node = workspace.capture(captureText) {
                        DropImport.finish(node.id, workspace: workspace)
                        window.inboxSelection = [node.id]
                    }
                    captureText = ""
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        let selected = window.inboxSelection
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Show", selection: $showArchived) {
                Text("Inbox").tag(false)
                Text("Archived").tag(true)
            }
            .pickerStyle(.segmented)
            .help("Show the Inbox or the archive")
            Menu {
                addToMapMenu(selected)
            } label: {
                Label("Add to Map", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .disabled(selected.isEmpty)
            .help("File the selected items onto a map")
            Button { workspace.convertToSources(selected); fetchDetails(selected) } label: {
                Label("Make Source", systemImage: "books.vertical")
            }
            .disabled(selected.isEmpty)
            .help("Move the selected items to the sources library")
            Button { workspace.convertToTasks(selected) } label: {
                Label("Make Task", systemImage: "checkmark.circle")
            }
            .disabled(selected.isEmpty)
            .help("Turn the selected items into tasks (⌘T)")
            Button { archiveOrDelete(selected) } label: {
                Label(showArchived ? "Move to Inbox" : "Archive", systemImage: showArchived ? "tray.and.arrow.up" : "archivebox")
            }
            .disabled(selected.isEmpty)
            .help(showArchived ? "Put the selected items back in the Inbox" : "Archive the selected items (⌫)")
            Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if window.inboxSelection.count == 1, let id = window.inboxSelection.first, let node = workspace.nodes[id] {
            NodeInspector(node: node, workspace: workspace)
        } else {
            ContentUnavailableView(window.inboxSelection.isEmpty ? "No Selection" : "\(window.inboxSelection.count) Items",
                                   systemImage: "tray",
                                   description: Text("Select an item to edit it, or drag it onto a map in another window."))
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<UUID>) -> some View {
        Menu("Add to Map") { addToMapMenu(ids) }
        Button("Make Source") { workspace.convertToSources(ids); fetchDetails(ids) }
        Button("Make Task") { workspace.convertToTasks(ids) }
        Divider()
        Button(showArchived ? "Move to Inbox" : "Archive") { archiveOrDelete(ids) }
        Button("Delete", role: .destructive) {
            workspace.deleteNodes(ids, actionName: ids.count == 1 ? "Delete Item" : "Delete Items")
        }
    }

    @ViewBuilder
    private func addToMapMenu(_ ids: Set<UUID>) -> some View {
        ForEach(workspace.sortedMaps) { map in
            Button(map.name) { file(ids, onto: map) }
        }
    }

    /// Files items under the map's first root (its central topic), so automatic layouts
    /// place them; on a map without nodes they become roots.
    private func file(_ ids: Set<UUID>, onto map: MindMap) {
        let tree = workspace.tree(of: map.id)
        let parent = tree.roots.first
        workspace.perform(ids.count == 1 ? "Add to Map" : "Add Items to Map") { _ in
            for id in ids.sorted(by: { (workspace.nodes[$0]?.createdAt ?? .now) < (workspace.nodes[$1]?.createdAt ?? .now) }) {
                let position = parent.map { workspace.suggestedChildPosition(parent: $0, in: map.id) } ?? .zero
                workspace.placeNode(id, on: map.id, at: position, parent: parent)
            }
        }
        window.inboxSelection = []
    }

    private func archiveOrDelete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if showArchived { workspace.unarchive(ids) } else { workspace.archive(ids) }
        window.inboxSelection = []
    }

    private func fetchDetails(_ ids: Set<UUID>) {
        for id in ids { DropImport.finish(id, workspace: workspace) }
    }
}

private struct InboxRow: View {
    let node: Node

    var body: some View {
        let data = node.data
        HStack(spacing: 10) {
            Image(systemName: data.leadingSymbol)
                .foregroundStyle(data.effectiveColor.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(data.displayTitle).lineLimit(2)
                HStack(spacing: 6) {
                    Text(data.kind.title)
                    if let link = data.link ?? data.source?.url, !link.isEmpty {
                        Text(link).lineLimit(1).truncationMode(.middle)
                    }
                    if !data.attachments.isEmpty {
                        Label("\(data.attachments.count)", systemImage: "paperclip").labelStyle(.titleAndIcon)
                    }
                    ForEach(data.tags, id: \.self) { Text("#\($0)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if MetadataService.shared.inFlight.contains(node.id) {
                ProgressView().controlSize(.small)
            }
            Text(data.createdAt, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
