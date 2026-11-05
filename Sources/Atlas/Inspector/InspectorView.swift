import AtlasCore
import AtlasLayout
import SwiftUI

/// The right-hand inspector of a map: the selected connection, frame, node or nodes, or
/// the map itself.
struct InspectorView: View {
    let controller: MapController

    var body: some View {
        let workspace = controller.workspace
        Group {
            if let edgeID = controller.selectedEdgeID, let edge = workspace.edges[edgeID] {
                EdgeInspector(edge: edge, controller: controller)
                    .id(edgeID)
            } else if let frameID = controller.selectedFrameID, let frame = workspace.frames[frameID] {
                FrameInspector(frame: frame, controller: controller)
                    .id(frameID)
            } else if controller.selection.count == 1, let id = controller.primarySelection, let node = workspace.nodes[id] {
                NodeInspector(node: node, workspace: workspace, currentMapID: controller.mapID, pin: pinControl(for: id))
                    .id(id)
            } else if controller.selection.count > 1 {
                SelectionInspector(controller: controller)
            } else {
                MapInspector(controller: controller)
            }
        }
    }

    /// Pinning only means something for a non-root node under an automatic layout.
    private func pinControl(for id: UUID) -> PinControl? {
        guard controller.style != .free, controller.tree.parent[id] != nil else { return nil }
        return PinControl(isPinned: controller.tree.pinned.contains(id)) { controller.togglePin() }
    }
}

/// A connection between two nodes: its ends, relation, label and line.
private struct EdgeInspector: View {
    let edge: GraphEdge
    let controller: MapController

    var body: some View {
        let workspace = controller.workspace
        let data = edge.data
        Form {
            Section("Connection") {
                endpoint("From", data.fromID)
                endpoint("To", data.toID)
                Button { workspace.reverseEdge(edge) } label: {
                    Label("Reverse Direction", systemImage: "arrow.left.arrow.right")
                }
            }
            Section("Relation") {
                Picker("Relation", selection: Binding(get: { data.relation },
                                                      set: { workspace.setRelation($0, label: data.label, of: [edge.id]) })) {
                    ForEach(RelationType.allCases) { relation in
                        Text(relation.title).tag(relation)
                    }
                }
                TextField(data.relation == .custom ? "Label" : "Label (optional)",
                          text: Binding(get: { data.label }, set: { label in
                              guard label != edge.label else { return }
                              workspace.updateEdge(edge, "Edit Label", coalesce: "edge-label-\(edge.id.uuidString)") {
                                  $0.label = label
                              }
                          }))
                Picker("Line", selection: Binding(get: { data.lineStyle },
                                                  set: { style in workspace.updateEdge(edge, "Change Line") { $0.lineStyle = style } })) {
                    ForEach(LineStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Arrow", isOn: Binding(get: { data.hasArrow },
                                              set: { arrow in workspace.updateEdge(edge, "Change Arrow") { $0.hasArrow = arrow } }))
            }
            Section {
                Button("Delete Connection", role: .destructive) { controller.deleteSelection() }
            } footer: {
                Text("Double-click a connection, or press Return, to pick its relation on the map.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func endpoint(_ label: String, _ id: UUID) -> some View {
        LabeledContent(label) {
            if let node = controller.workspace.nodes[id] {
                Button(node.data.displayTitle) {
                    controller.select(id)
                    controller.ensureVisible(id)
                }
                .buttonStyle(.link)
                .lineLimit(1)
            }
        }
    }
}

/// A labelled frame around a group of nodes.
private struct FrameInspector: View {
    let frame: MapFrame
    let controller: MapController

    var body: some View {
        let workspace = controller.workspace
        Form {
            Section("Group") {
                TextField("Title", text: Binding(get: { frame.title }, set: { title in
                    guard title != frame.title else { return }
                    workspace.updateFrame(frame, "Rename Group", coalesce: "frame-title-\(frame.id.uuidString)") {
                        $0.title = title
                    }
                }))
                LabeledContent("Nodes", value: "\(frame.nodeIDs.count)")
                Button("Select Nodes") { controller.selectMembers(of: frame.id) }
            }
            Section("Colour") {
                ColorPalette(selected: frame.color, showsDefault: false) { color in
                    if let color { controller.setFrameColor(color) }
                }
            }
            Section {
                Button("Ungroup") { controller.ungroup() }
            } footer: {
                Text("A group frames its nodes and their branches, and follows them as they move. Drag its title to move the whole group.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Bulk edits for several selected nodes.
private struct SelectionInspector: View {
    let controller: MapController

    var body: some View {
        Form {
            Section {
                Text("\(controller.selection.count) nodes selected")
                    .font(.headline)
            }
            Section("Type") {
                KindGrid { controller.setKind($0) }
            }
            Section("Colour") {
                ColorPalette(selected: nil, defaultColor: nil) { controller.setColor($0) }
            }
            Section("Arrange") {
                HStack(spacing: 4) {
                    ForEach(Arrange.Alignment.allCases) { alignment in
                        Button { controller.align(alignment) } label: {
                            Image(systemName: alignment.symbolName).frame(maxWidth: .infinity)
                        }
                        .help("Align \(alignment.title)")
                        .accessibilityLabel("Align \(alignment.title)")
                    }
                }
                HStack(spacing: 4) {
                    ForEach(Arrange.Axis.allCases) { axis in
                        Button { controller.distribute(axis) } label: {
                            Label("Distribute", systemImage: axis.symbolName).frame(maxWidth: .infinity)
                        }
                        .help("Distribute \(axis.title)")
                        .accessibilityLabel("Distribute \(axis.title)")
                    }
                }
                .disabled(!controller.canDistribute)
                Button { controller.groupSelection() } label: { Label("Group  (⌥⌘G)", systemImage: "rectangle.dashed") }
                Button { controller.connectSelection() } label: {
                    Label("Connect to \(controller.primarySelection.flatMap { controller.workspace.nodes[$0]?.data.displayTitle } ?? "Primary")  (⌘L)",
                          systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                if controller.canPin {
                    Button { controller.togglePin() } label: {
                        Label(controller.selectionIsPinned ? "Unpin" : "Pin in Place", systemImage: "pin")
                    }
                }
            }
            Section {
                Button("Delete \(controller.selection.count) Nodes", role: .destructive) { controller.deleteSelection() }
            }
        }
        .formStyle(.grouped)
    }
}

/// Map details shown when nothing is selected.
private struct MapInspector: View {
    let controller: MapController
    @State private var name = ""

    var body: some View {
        let workspace = controller.workspace
        let map = controller.map
        let placements = workspace.placements(in: map.id)
        Form {
            Section("Map") {
                TextField("Name", text: $name)
                    .onSubmit { workspace.renameMap(map, to: name) }
                    .onAppear { name = map.name }
                    .onChange(of: map.name) { _, newName in name = newName }
                LabeledContent("Nodes", value: "\(placements.count)")
                LabeledContent("Connections", value: "\(controller.mapEdges.count)")
                LabeledContent("Created", value: map.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
            Section("Layout") {
                LayoutGrid(selected: controller.style) { controller.setLayoutStyle($0) }
                if controller.style != .free, !controller.tree.pinned.isEmpty {
                    LabeledContent("Pinned nodes", value: "\(controller.tree.pinned.count)")
                    Button("Unpin All") { controller.unpinAll() }
                }
            }
            Section("Node Types") {
                let counts = Dictionary(grouping: placements.keys.compactMap { workspace.nodes[$0]?.kind }, by: { $0 })
                ForEach(NodeKind.allCases.filter { counts[$0] != nil }) { kind in
                    LabeledContent {
                        Text("\(counts[kind]?.count ?? 0)")
                    } label: {
                        Label(kind.pluralTitle, systemImage: kind.symbolName)
                            .foregroundStyle(kind.defaultColor.color)
                    }
                }
            }
            Section {
                Text("Select a node to see its details. Tab adds a child, Return a sibling, and Space edits the title. Drag a node onto another to move it there, or drag from the dots on its edge to connect it. ⌘K finds anything.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// A grid of buttons, one per node kind.
struct KindGrid: View {
    var selected: NodeKind?
    let onSelect: (NodeKind) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], spacing: 6) {
            ForEach(NodeKind.allCases) { kind in
                Button { onSelect(kind) } label: {
                    Label(kind.title, systemImage: kind.symbolName)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(kind == selected ? kind.defaultColor.color.opacity(0.25) : Color.primary.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(kind == selected ? kind.defaultColor.color : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(kind.defaultColor.color)
                .accessibilityLabel(kind.title)
                .accessibilityAddTraits(kind == selected ? .isSelected : [])
            }
        }
    }
}

/// A grid of buttons, one per layout style.
struct LayoutGrid: View {
    var selected: LayoutStyle
    let onSelect: (LayoutStyle) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
            ForEach(LayoutStyle.allCases) { style in
                Button { onSelect(style) } label: {
                    Label(style.title, systemImage: style.symbolName)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 6)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(style == selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(style == selected ? Color.accentColor : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(style.title)
                .accessibilityAddTraits(style == selected ? .isSelected : [])
            }
        }
    }
}

/// Colour swatches. `nil` means "use the type's default colour".
struct ColorPalette: View {
    var selected: NodeColor?
    var defaultColor: NodeColor?
    var showsDefault = true
    let onSelect: (NodeColor?) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 22), spacing: 6)], spacing: 6) {
            if showsDefault { defaultButton }
            ForEach(NodeColor.allCases) { color in
                Button { onSelect(color) } label: {
                    Circle()
                        .fill(color.color)
                        .frame(width: 20, height: 20)
                        .overlay { if selected == color { selectionRing } }
                }
                .buttonStyle(.plain)
                .help(color.title)
                .accessibilityLabel(color.title)
            }
        }
    }

    private var defaultButton: some View {
        Button { onSelect(nil) } label: {
            Circle()
                .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                .background(Circle().fill((defaultColor?.color ?? .clear).opacity(0.5)))
                .frame(width: 20, height: 20)
                .overlay { if selected == nil, defaultColor != nil { selectionRing } }
        }
        .buttonStyle(.plain)
        .help("Default colour for this type")
    }

    private var selectionRing: some View {
        Circle().strokeBorder(Color.primary, lineWidth: 2).padding(-3)
    }
}
