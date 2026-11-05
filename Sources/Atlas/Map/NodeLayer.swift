import AtlasCore
import SwiftUI

/// All visible nodes, laid out in world coordinates and transformed by the viewport.
/// The transform is applied here, outside `NodeLayerContent`, so panning and zooming
/// never re-evaluate the individual node views.
struct NodeLayer: View {
    let controller: MapController

    var body: some View {
        let viewport = controller.viewport
        if controller.isOverview {
            NodeOverviewLayer(controller: controller)
        } else {
            NodeLayerContent(controller: controller)
                .scaleEffect(viewport.zoom, anchor: .topLeading)
                .offset(x: viewport.offset.x, y: viewport.offset.y)
        }
    }
}

/// Large maps zoomed far out: every node as a tinted shape in one canvas. The shapes are
/// gathered here (redone when nodes move), and only the canvas follows the viewport.
private struct NodeOverviewLayer: View {
    let controller: MapController

    var body: some View {
        let selection = controller.selection
        let focused = controller.focusedIDs
        let items = controller.renderedIDs.compactMap { id -> OverviewItem? in
            guard let rect = controller.worldRect(id), let node = controller.workspace.nodes[id] else { return nil }
            let topic = controller.isTopic(id)
            return OverviewItem(rect: rect, color: node.data.effectiveColor.color, isTopic: topic,
                                isSelected: selection.contains(id),
                                isDimmed: focused.map { !$0.contains(id) } ?? false)
        }
        OverviewCanvas(items: items, controller: controller)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct OverviewItem {
    var rect: CGRect
    var color: Color
    var isTopic: Bool
    var isSelected: Bool
    var isDimmed: Bool
}

private struct OverviewCanvas: View {
    let items: [OverviewItem]
    let controller: MapController

    var body: some View {
        let viewport = controller.viewport
        Canvas { context, size in
            context.translateBy(x: viewport.offset.x, y: viewport.offset.y)
            context.scaleBy(x: viewport.zoom, y: viewport.zoom)
            let visible = CGRect(x: -viewport.offset.x / viewport.zoom, y: -viewport.offset.y / viewport.zoom,
                                 width: size.width / viewport.zoom, height: size.height / viewport.zoom)
            let background = Color(nsColor: .textBackgroundColor)
            for item in items where item.rect.intersects(visible) {
                let path = Path(roundedRect: item.rect, cornerRadius: min(10, item.rect.height / 2))
                let opacity = item.isDimmed ? 0.25 : 1
                context.fill(path, with: .color(background.opacity(opacity)))
                context.fill(path, with: .color(item.color.opacity((item.isTopic ? 0.35 : 0.22) * opacity)))
                context.stroke(path, with: .color(item.color.opacity(0.8 * opacity)), lineWidth: item.isTopic ? 3 : 2)
                if item.isSelected {
                    context.stroke(Path(roundedRect: item.rect.insetBy(dx: -6, dy: -6), cornerRadius: 12),
                                   with: .color(.accentColor), lineWidth: 2.5 / viewport.zoom)
                }
            }
        }
    }
}

private struct NodeLayerContent: View {
    let controller: MapController

    var body: some View {
        let selection = controller.selection
        let editing = controller.editingNodeID
        let tree = controller.tree
        let showPins = controller.style != .free
        let focused = controller.focusedIDs
        let dropTarget = controller.dropHighlightID
        ZStack(alignment: .topLeading) {
            ForEach(controller.renderedIDs, id: \.self) { id in
                if let node = controller.workspace.nodes[id] {
                    NodeView(node: node, display: controller.display(id), controller: controller,
                             isSelected: selection.contains(id), isEditing: editing == id,
                             isTopic: tree.parent[id] == nil && !tree.children(of: id).isEmpty,
                             hiddenCount: tree.hiddenCount(under: id),
                             isPinned: showPins && tree.pinned.contains(id),
                             isDimmed: focused.map { !$0.contains(id) } ?? false,
                             isDropTarget: dropTarget == id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct NodeView: View {
    let node: Node
    /// Where the node is drawn; observed per node, so animating one node redraws only it.
    let display: NodeDisplay
    let controller: MapController
    let isSelected: Bool
    let isEditing: Bool
    let isTopic: Bool
    let hiddenCount: Int
    let isPinned: Bool
    let isDimmed: Bool
    let isDropTarget: Bool

    @GestureState private var isDragging = false

    var body: some View {
        let data = node.data
        let size = controller.metrics.size(for: data, isTopic: isTopic)
        let shape = NodeShape(kind: data.kind, isTopic: isTopic)
        NodeCard(data: data, size: size, isTopic: isTopic, isSelected: isSelected)
            .opacity(isEditing ? 0 : 1)
            .overlay {
                if isDropTarget {
                    shape.fill(Color.accentColor.opacity(0.12))
                    shape.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [6, 3]))
                        .padding(-5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.secondary))
                        .offset(x: 6, y: -6)
                        .help("Pinned: automatic layouts leave this node where it is")
                }
            }
            .overlay(alignment: .trailing) {
                if hiddenCount > 0 {
                    CollapsedBadge(count: hiddenCount, color: data.effectiveColor.color)
                        .offset(x: 16)
                        .onTapGesture { controller.workspace.setCollapsed(false, nodeIDs: [node.id], in: controller.mapID) }
                }
            }
            .contentShape(shape)
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(CanvasView.coordinateSpace))
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { value in
                        controller.nodePointerDragChanged(node.id, start: value.startLocation, location: value.location,
                                                          translation: value.translation)
                    }
                    .onEnded { _ in controller.nodePointerDragEnded() }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { controller.beginEditing(node.id) })
            .simultaneousGesture(TapGesture().onEnded { controller.handleClick(on: node.id) })
            .onChange(of: isDragging) { _, dragging in
                if !dragging { controller.nodePointerDragEnded() }
            }
            .onHover { inside in controller.hoverChanged(node.id, inside: inside) }
            .contextMenu { NodeContextMenu(controller: controller, nodeID: node.id) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(data))
            .accessibilityValue(accessibilityPosition())
            .accessibilityHint("Arrow keys move between nodes. Tab adds a child, Return a sibling, Space edits.")
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            .accessibilityAction { controller.handleClick(on: node.id) }
            .accessibilityAction(named: "Edit Title") { controller.beginEditing(node.id) }
            .accessibilityAction(named: "Add Child") {
                controller.select(node.id)
                controller.addChild()
            }
            .accessibilityAction(named: hiddenCount > 0 ? "Expand" : "Collapse") {
                controller.select(node.id)
                controller.toggleCollapse()
            }
            .opacity(isDimmed ? 0.22 : 1)
            .animation(.easeInOut(duration: 0.2), value: isDimmed)
            .position(display.center)
    }

    /// "Level 2, 1 of 3, 4 children": where the node sits in the outline.
    private func accessibilityPosition() -> String {
        let tree = controller.tree
        let siblings = tree.siblings(of: node.id)
        var parts = ["level \(tree.ancestors(of: node.id).count + 1)"]
        if let index = siblings.firstIndex(of: node.id), siblings.count > 1 {
            parts.append("\(index + 1) of \(siblings.count)")
        }
        let children = tree.children(of: node.id).count
        if children > 0 { parts.append("\(children) child\(children == 1 ? "" : "ren")") }
        if let parent = tree.parent[node.id], let title = controller.workspace.nodes[parent]?.data.displayTitle {
            parts.append("under \(title)")
        }
        return parts.joined(separator: ", ")
    }

    private func accessibilityLabel(_ data: NodeData) -> String {
        var parts = ["\(data.kind.title): \(data.displayTitle)"]
        if let task = data.task { parts.append("task \(task.status.title.lowercased())") }
        if !data.tags.isEmpty { parts.append("tagged " + data.tags.joined(separator: ", ")) }
        if !data.body.isEmpty { parts.append("has notes") }
        if !data.citations.isEmpty { parts.append("\(data.citations.count) linked source\(data.citations.count == 1 ? "" : "s")") }
        if hiddenCount > 0 { parts.append("collapsed, \(hiddenCount) hidden") }
        if isPinned { parts.append("pinned") }
        return parts.joined(separator: ", ")
    }
}

/// The visual body of a node: shape, icon, title and badges.
struct NodeCard: View {
    let data: NodeData
    let size: CGSize
    let isTopic: Bool
    let isSelected: Bool

    var body: some View {
        let tint = data.effectiveColor.color
        let shape = NodeShape(kind: data.kind, isTopic: isTopic)
        let badges = NodeMetrics.badgeCount(for: data)
        HStack(alignment: .center, spacing: NodeMetrics.spacing) {
            Image(systemName: data.leadingSymbol)
                .font(.system(size: isTopic ? 14 : 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: NodeMetrics.iconWidth)
            Text(data.displayTitle)
                .font(Font(NodeMetrics.titleFont(isTopic: isTopic, kind: data.kind) as CTFont))
                .foregroundStyle(data.title.isEmpty ? .secondary : .primary)
                .strikethrough(data.task?.status == .done || data.task?.status == .cancelled, color: .secondary)
                .lineLimit(8)
                .frame(width: NodeMetrics.textWidth(nodeWidth: size.width, badges: badges), alignment: .leading)
            if badges > 0 { NodeBadges(data: data) }
        }
        .padding(.horizontal, NodeMetrics.horizontalPadding)
        .frame(width: size.width, height: size.height)
        .background {
            shape.fill(Color(nsColor: .textBackgroundColor))
            shape.fill(tint.opacity(isTopic ? 0.2 : 0.12))
        }
        .overlay {
            shape.stroke(tint.opacity(0.8), lineWidth: isTopic ? 2 : 1.2)
        }
        .overlay {
            if isSelected {
                shape.stroke(Color.accentColor, lineWidth: 2.5)
                    .padding(-3.5)
            }
        }
    }
}

private struct NodeBadges: View {
    let data: NodeData

    var body: some View {
        HStack(spacing: 0) {
            if let task = data.task, data.kind != .task {
                Image(systemName: task.status.symbolName)
                    .foregroundStyle(task.status == .done ? Color.green : Color.secondary)
                    .frame(width: NodeMetrics.badgeWidth)
                    .help("Task: \(task.status.title)")
            }
            if !data.citations.isEmpty {
                HStack(spacing: 1) {
                    Image(systemName: "book.closed")
                    Text("\(data.citations.count)")
                }
                .foregroundStyle(.secondary)
                .frame(width: NodeMetrics.badgeWidth)
                .help("\(data.citations.count) linked source\(data.citations.count == 1 ? "" : "s")")
            }
            if !data.attachments.isEmpty {
                Image(systemName: "paperclip")
                    .foregroundStyle(.secondary)
                    .frame(width: NodeMetrics.badgeWidth)
            }
        }
        .font(.system(size: 10, weight: .medium))
    }
}

private struct CollapsedBadge: View {
    let count: Int
    let color: Color

    var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 18)
            .background(Capsule().fill(color))
            .help("\(count) hidden node\(count == 1 ? "" : "s") – click to expand")
    }
}

struct NodeContextMenu: View {
    let controller: MapController
    let nodeID: UUID

    var body: some View {
        Button("Add Child") { prepare(); controller.addChild() }
        Button("Add Sibling") { prepare(); controller.addSibling() }
        Button("Edit Title") { controller.beginEditing(nodeID) }
        Divider()
        Button("Cut") { prepare(); controller.cutSelection() }
        Button("Copy") { prepare(); controller.copySelection() }
        Button("Paste") { controller.select(nodeID); controller.paste() }
            .disabled(!controller.canPaste)
        Button("Duplicate") { prepare(); controller.duplicateSelection() }
        Divider()
        Menu("Type") {
            ForEach(NodeKind.allCases) { kind in
                Button { prepare(); controller.setKind(kind) } label: { Label(kind.title, systemImage: kind.symbolName) }
            }
        }
        Menu("Colour") {
            Button("Default") { prepare(); controller.setColor(nil) }
            Divider()
            ForEach(NodeColor.allCases) { color in
                Button(color.title) { prepare(); controller.setColor(color) }
            }
        }
        if !controller.tree.children(of: nodeID).isEmpty {
            Button(controller.tree.collapsed.contains(nodeID) ? "Expand Branch" : "Collapse Branch") {
                prepare(); controller.toggleCollapse()
            }
        }
        Divider()
        if controller.selection.count > 1, controller.selection.contains(nodeID) {
            Button("Connect Selected Nodes") { controller.connectSelection() }
        }
        Button("Group") { prepare(); controller.groupSelection() }
        if controller.style != .free, controller.tree.parent[nodeID] != nil {
            Button(controller.tree.pinned.contains(nodeID) ? "Unpin" : "Pin in Place") { prepare(); controller.togglePin() }
        }
        Divider()
        Button("Delete", role: .destructive) { prepare(); controller.deleteSelection() }
    }

    /// Right-clicking a node outside the selection acts on that node alone.
    private func prepare() {
        if !controller.selection.contains(nodeID) { controller.select(nodeID) }
    }
}
