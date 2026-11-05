import AtlasCore
import AtlasLayout
import SwiftUI

/// One row of the command palette.
struct PaletteItem: Identifiable {
    enum Kind: Int {
        case command, map, section, node, source

        var title: String {
            switch self {
            case .command: "Command"
            case .map: "Map"
            case .section: "Section"
            case .node: "Node"
            case .source: "Source"
            }
        }

        /// Breaks near-ties in favour of places and commands over individual nodes.
        var bonus: Int {
            switch self {
            case .map, .section: 8
            case .command: 6
            case .source: 2
            case .node: 0
            }
        }
    }

    let id: String
    let kind: Kind
    let title: String
    var subtitle = ""
    let symbol: String
    var tint: Color = .secondary
    var shortcut = ""
    let run: @MainActor () -> Void
}

/// ⌘K: jump to any node, map, source or section, or run a command, by typing a few
/// letters of its name. ↑ and ↓ choose, Return runs, Esc closes.
struct CommandPalette: View {
    let window: WindowState
    @Environment(Workspace.self) private var workspace
    @State private var query = ""
    @State private var items: [PaletteItem] = []
    @State private var recent: [PaletteItem] = []
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let results = Self.results(for: query, items: items, recent: recent)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                TextField("Jump to a node, map or source, or run a command", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($fieldFocused)
                    .onSubmit { run(results) }
                    .onKeyPress(.downArrow) {
                        highlighted = min(highlighted + 1, max(results.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        highlighted = max(highlighted - 1, 0)
                        return .handled
                    }
                    .onExitCommand { close() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            Divider()
            if results.isEmpty {
                Text(items.isEmpty ? "" : "No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(18)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                row(item, isHighlighted: index == highlighted)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        highlighted = index
                                        run(results)
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 400)
                    .onChange(of: highlighted) { _, index in
                        if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
                    }
                }
            }
        }
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .onAppear {
            (items, recent) = buildItems()
            fieldFocused = true
        }
        .onChange(of: query) { highlighted = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    private func row(_ item: PaletteItem, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .foregroundStyle(item.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !item.shortcut.isEmpty {
                Text(item.shortcut)
                    .font(.system(size: 11.5).monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(item.kind.title)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(isHighlighted ? Color.accentColor.opacity(0.22) : .clear))
    }

    // MARK: Running

    private func run(_ results: [PaletteItem]) {
        guard results.indices.contains(highlighted) else { return }
        let item = results[highlighted]
        close()
        DispatchQueue.main.async { item.run() }
    }

    private func close() {
        window.isPaletteVisible = false
        window.activeMapController?.focusCanvasSoon()
    }

    // MARK: Searching

    /// Fuzzy matches on titles, best first. With no query: recently edited nodes, then maps,
    /// sections and commands.
    static func results(for query: String, items: [PaletteItem], recent: [PaletteItem], limit: Int = 60) -> [PaletteItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            return recent + items.filter { $0.kind != .node && $0.kind != .source }
        }
        var scored: [(score: Int, item: PaletteItem)] = []
        for item in items {
            if let score = FuzzyMatch.score(query, item.title) { scored.append((score + item.kind.bonus, item)) }
        }
        return scored
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.item.kind != $1.item.kind { return $0.item.kind.rawValue < $1.item.kind.rawValue }
                return $0.item.title.localizedStandardCompare($1.item.title) == .orderedAscending
            }
            .prefix(limit)
            .map(\.item)
    }

    // MARK: What can be found

    private func buildItems() -> (all: [PaletteItem], recent: [PaletteItem]) {
        var items = commandItems()
        let window = window
        let workspace = workspace

        for map in workspace.sortedMaps {
            let count = workspace.placements(in: map.id).count
            items.append(PaletteItem(id: "map.\(map.id)", kind: .map, title: map.name,
                                     subtitle: "\(count) node\(count == 1 ? "" : "s")",
                                     symbol: SidebarItem.map(map.id).symbolName) {
                window.selection = .map(map.id)
            })
        }

        let sections: [SidebarItem] = [.inbox, .today, .week, .sources, .tags, .review]
        for (index, section) in sections.enumerated() {
            items.append(PaletteItem(id: "section.\(section.title)", kind: .section, title: section.title,
                                     symbol: section.symbolName, shortcut: "⌘\(index + 1)") {
                window.selection = section
            })
        }

        // Nodes on a map, labelled with the map they are on (this window's map first).
        var nodes: [PaletteItem] = []
        var recentNodes: [(date: Date, item: PaletteItem)] = []
        let current = window.currentMapID
        for node in workspace.nodes.values where node.inbox != .archived && !node.title.isEmpty {
            let maps = workspace.maps(containing: node.id)
            let subtitle: String
            if let map = maps.first(where: { $0.id == current }) ?? maps.first {
                subtitle = map.name + (maps.count > 1 ? " and \(maps.count - 1) more" : "")
            } else if node.inbox == .inbox {
                subtitle = "Inbox"
            } else if node.source != nil {
                subtitle = "Sources" + (node.source.map { $0.citationKey.isEmpty ? "" : " · \($0.citationKey)" } ?? "")
            } else if node.kind == .quote, let source = node.citations.first.flatMap({ workspace.nodes[$0.sourceID] }) {
                subtitle = "Quote from \(source.title)"
            } else if node.task != nil {
                subtitle = "Planner"
            } else {
                continue
            }
            let item = PaletteItem(id: "node.\(node.id)", kind: node.kind == .source ? .source : .node,
                                   title: node.title, subtitle: subtitle, symbol: node.kind.symbolName,
                                   tint: node.data.effectiveColor.color) {
                window.reveal(node.id, in: workspace, preferring: current)
            }
            nodes.append(item)
            recentNodes.append((node.updatedAt, item))
        }
        let recent = recentNodes.sorted { $0.date > $1.date }.prefix(5).map(\.item)
        return (items + nodes, Array(recent))
    }

    private func commandItems() -> [PaletteItem] {
        var items: [PaletteItem] = []
        func command(_ title: String, _ symbol: String, _ shortcut: String = "", enabled: Bool = true,
                     _ run: @escaping @MainActor () -> Void) {
            guard enabled else { return }
            items.append(PaletteItem(id: "command.\(title)", kind: .command, title: title, symbol: symbol,
                                     tint: .accentColor, shortcut: shortcut, run: run))
        }
        let workspace = workspace
        let window = window

        if let map = window.activeMapController {
            let hasSelection = !map.selection.isEmpty
            command("Add Child", "plus.square", "Tab") { map.addChild() }
            command("Add Sibling", "plus.rectangle", "↩", enabled: hasSelection) { map.addSibling() }
            command("Duplicate", "plus.square.on.square", "⌘D", enabled: map.canCopy) { map.duplicateSelection() }
            command("Connect Selected Nodes", "point.topleft.down.to.point.bottomright.curvepath", "⌘L",
                    enabled: map.canConnectSelection) { map.connectSelection() }
            command("Indent", "increase.indent", "⌘]", enabled: hasSelection) { map.indentSelection() }
            command("Outdent", "decrease.indent", "⌘[", enabled: hasSelection) { map.outdentSelection() }
            command("Collapse or Expand Branch", "chevron.right.circle", "⌘.", enabled: hasSelection) { map.toggleCollapse() }
            command("Select All", "checklist", "⌘A") { map.selectAll() }
            command(map.selectionIsTask ? "Remove Task" : "Make Task", "checkmark.circle", "⌘T", enabled: hasSelection) { map.toggleTask() }
            command("Copy Citation", "quote.opening", "⇧⌘C", enabled: map.canCite) { map.copyCitation() }
            for template in ResearchTemplate.allCases {
                command("Insert \(template.title)", template.symbolName) { map.insertTemplate(template) }
            }
            for (index, style) in LayoutStyle.allCases.enumerated() {
                command(style == .free ? "Free Placement" : "\(style.title) Layout", style.symbolName, "⌥⌘\(index + 1)",
                        enabled: map.style != style) { map.setLayoutStyle(style) }
            }
            command("Unpin All", "pin.slash", enabled: map.style != .free && !map.tree.pinned.isEmpty) { map.unpinAll() }
            command(map.selectionIsPinned ? "Unpin" : "Pin in Place", "pin", enabled: map.canPin) { map.togglePin() }
            for alignment in Arrange.Alignment.allCases {
                command("Align \(alignment.title)", alignment.symbolName, enabled: map.canAlign) { map.align(alignment) }
            }
            for axis in Arrange.Axis.allCases {
                command("Distribute \(axis.title)", axis.symbolName, enabled: map.canDistribute) { map.distribute(axis) }
            }
            command("Group", "rectangle.dashed", "⌥⌘G", enabled: map.canGroup) { map.groupSelection() }
            command("Ungroup", "rectangle.slash", "⇧⌥⌘G", enabled: map.canUngroup) { map.ungroup() }
            command(map.isFocusMode ? "Leave Focus Mode" : "Focus Mode", "scope", "⇧⌘F") { map.toggleFocusMode() }
            command("Zoom to Fit", "arrow.up.left.and.arrow.down.right", "⌘9") { map.zoomToFit() }
            command("Actual Size", "1.magnifyingglass", "⌘0") { map.actualSize() }
            command("Zoom In", "plus.magnifyingglass", "⌘=") { map.zoomIn() }
            command("Zoom Out", "minus.magnifyingglass", "⌘−") { map.zoomOut() }
            let minimap = UserDefaults.standard.object(forKey: "atlas.showMinimap") as? Bool ?? true
            command(minimap ? "Hide Minimap" : "Show Minimap", "map", "⇧⌘M") {
                UserDefaults.standard.set(!minimap, forKey: "atlas.showMinimap")
            }
        }

        let inspector = UserDefaults.standard.object(forKey: "atlas.showInspector") as? Bool ?? true
        command(inspector ? "Hide Inspector" : "Show Inspector", "sidebar.trailing") {
            UserDefaults.standard.set(!inspector, forKey: "atlas.showInspector")
        }
        command("New Map", "plus.rectangle.on.rectangle", "⌘N") {
            let map = workspace.createMap(named: "Untitled Map")
            window.selection = .map(map.id)
        }
        command("Quick Capture", "tray.and.arrow.down") { QuickCapture.shared.show() }
        for template in ResearchTemplate.allCases {
            command("New \(template.title) Map", template.symbolName) {
                let map = workspace.createMap(from: template)
                window.selection = .map(map.id)
            }
        }
        if let name = workspace.history.undoActionName {
            command("Undo \(name)", "arrow.uturn.backward", "⌘Z") {
                if let set = workspace.undo() { window.activeMapController?.selectAfterHistoryStep(set) }
            }
        }
        if let name = workspace.history.redoActionName {
            command("Redo \(name)", "arrow.uturn.forward", "⇧⌘Z") {
                if let set = workspace.redo() { window.activeMapController?.selectAfterHistoryStep(set) }
            }
        }
        return items
    }
}
