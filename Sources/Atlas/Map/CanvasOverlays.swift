import AtlasCore
import AtlasLayout
import SwiftUI

/// Feedback drawn over the map in view coordinates (so it stays crisp at any zoom): snap
/// guides, where a dropped branch would go, the marquee, a connection being dragged out,
/// the connection handles of the node under the pointer, and the relation menu.
struct InteractionOverlay: View {
    let controller: MapController

    var body: some View {
        ZStack(alignment: .topLeading) {
            FeedbackCanvas(controller: controller)
            ConnectHandles(controller: controller)
            if let picker = controller.relationPicker {
                RelationPickerView(controller: controller, picker: picker)
            }
        }
    }
}

private struct FeedbackCanvas: View {
    let controller: MapController

    var body: some View {
        let viewport = controller.viewport
        let feedback = controller.dragFeedback
        let marquee = controller.marquee
        let connection = connectionLine(viewport)
        Canvas { context, _ in
            if let feedback {
                for guide in feedback.guides {
                    let a = guide.isVertical ? CGPoint(x: guide.position, y: guide.from) : CGPoint(x: guide.from, y: guide.position)
                    let b = guide.isVertical ? CGPoint(x: guide.position, y: guide.to) : CGPoint(x: guide.to, y: guide.position)
                    var path = Path()
                    path.move(to: viewport.viewPoint(a))
                    path.addLine(to: viewport.viewPoint(b))
                    context.stroke(path, with: .color(.pink), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                if feedback.insertionLine.count == 2 {
                    let a = viewport.viewPoint(feedback.insertionLine[0])
                    let b = viewport.viewPoint(feedback.insertionLine[1])
                    var path = Path()
                    path.move(to: a)
                    path.addLine(to: b)
                    context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    for end in [a, b] {
                        context.fill(Path(ellipseIn: CGRect(x: end.x - 4, y: end.y - 4, width: 8, height: 8)),
                                     with: .color(.accentColor))
                    }
                }
            }
            if let marquee {
                context.fill(Path(marquee), with: .color(Color.accentColor.opacity(0.1)))
                context.stroke(Path(marquee), with: .color(Color.accentColor.opacity(0.8)), lineWidth: 1)
            }
            if let connection {
                if let target = connection.target {
                    let ring = Path(roundedRect: target.insetBy(dx: -4, dy: -4), cornerRadius: 10)
                    context.fill(ring, with: .color(Color.accentColor.opacity(0.1)))
                    context.stroke(ring, with: .color(.accentColor), lineWidth: 2.5)
                }
                var path = Path()
                path.move(to: connection.start)
                path.addLine(to: connection.end)
                context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4]))
                let angle = atan2(connection.end.y - connection.start.y, connection.end.x - connection.start.x)
                var head = Path()
                head.move(to: connection.end)
                head.addLine(to: CGPoint(x: connection.end.x - 10 * cos(angle - .pi / 7), y: connection.end.y - 10 * sin(angle - .pi / 7)))
                head.addLine(to: CGPoint(x: connection.end.x - 10 * cos(angle + .pi / 7), y: connection.end.y - 10 * sin(angle + .pi / 7)))
                head.closeSubpath()
                context.fill(head, with: .color(.accentColor))
            }
        }
        .allowsHitTesting(false)
    }

    /// The line of a connection being dragged out, from the node's edge to the pointer (or
    /// to the edge of the node under it), in view coordinates.
    private func connectionLine(_ viewport: Viewport) -> (start: CGPoint, end: CGPoint, target: CGRect?)? {
        guard let drag = controller.connectDrag, let from = controller.worldRect(drag.from) else { return nil }
        let targetRect = drag.target.flatMap { controller.worldRect($0) }
        let aim = targetRect.map { CGPoint(x: $0.midX, y: $0.midY) } ?? drag.pointer
        let start = Geometry.borderPoint(of: from, toward: aim)
        let end = targetRect.map { Geometry.borderPoint(of: $0, toward: CGPoint(x: from.midX, y: from.midY)) } ?? drag.pointer
        return (viewport.viewPoint(start), viewport.viewPoint(end), targetRect.map(viewport.viewRect))
    }
}

/// Dots on the edges of the node under the pointer; drag one onto another node to connect
/// the two.
private struct ConnectHandles: View {
    let controller: MapController
    @GestureState private var isDragging = false

    private enum Side: CaseIterable, Identifiable {
        case top, right, bottom, left

        var id: Self { self }

        func point(on rect: CGRect) -> CGPoint {
            switch self {
            case .top: CGPoint(x: rect.midX, y: rect.minY)
            case .right: CGPoint(x: rect.maxX, y: rect.midY)
            case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
            case .left: CGPoint(x: rect.minX, y: rect.midY)
            }
        }
    }

    var body: some View {
        // While a connection is dragged out, its handles must stay put or the drag would end.
        let id = controller.connectDrag?.from ?? controller.hoveredNodeID
        if let id, controller.editingNodeID != id, controller.dragFeedback == nil, controller.marquee == nil,
           controller.viewport.zoom >= 0.3, let rect = controller.viewRect(id) {
            // A collapsed node's count badge sits on its right edge.
            let sides = Side.allCases.filter { $0 != .right || controller.tree.hiddenCount(under: id) == 0 }
            ForEach(sides) { side in
                handle(id, at: side.point(on: rect))
            }
        }
    }

    private func handle(_ id: UUID, at point: CGPoint) -> some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(Color(nsColor: .textBackgroundColor), lineWidth: 1.5))
            .frame(width: 22, height: 22)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(CanvasView.coordinateSpace))
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { controller.connectDragChanged(from: id, location: $0.location) }
                    .onEnded { _ in controller.connectDragEnded() }
            )
            .onChange(of: isDragging) { _, dragging in
                if !dragging { controller.connectDragEnded() }
            }
            .onHover { inside in controller.hoverChanged(id, inside: inside) }
            .help("Drag onto another node to connect them")
            .accessibilityLabel("Connect")
            .position(point)
    }
}

/// The inline menu of relation types. Digits 1–6 pick one from the keyboard.
private struct RelationPickerView: View {
    let controller: MapController
    let picker: RelationPicker

    var body: some View {
        let anchor = controller.viewport.viewPoint(picker.anchor)
        let current = controller.pickerRelation
        let width = controller.canvasSize.width
        HStack(spacing: 2) {
            ForEach(Array(RelationType.allCases.enumerated()), id: \.element) { index, relation in
                Button { controller.pickRelation(relation) } label: {
                    HStack(spacing: 5) {
                        Text("\(index + 1)")
                            .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Circle().fill(relation.color).frame(width: 7, height: 7)
                        Text(relation.title).font(.system(size: 11.5, weight: .medium))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(relation == current ? Color.accentColor.opacity(0.2) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(relation.title) (\(index + 1))")
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .fixedSize()
        .position(x: min(max(anchor.x, 270), max(width - 270, 270)), y: max(anchor.y - 30, 24))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Relation")
    }
}

/// A small overview of the whole map. Click or drag in it to move the view.
struct MinimapView: View {
    let controller: MapController
    /// The overview's extent is held still while dragging in it, so it does not shift
    /// under the pointer as the view moves.
    @State private var heldBounds: CGRect?

    static let size = CGSize(width: 190, height: 124)
    private static let inset: CGFloat = 8

    var body: some View {
        // Only the view rectangle follows the viewport; the nodes are drawn by a child that
        // redraws when they move or when the overview's extent changes.
        let visible = controller.visibleWorldRect
        let bounds = heldBounds ?? Self.extent(content: controller.contentBounds, visible: visible)
        let transform = Self.transform(for: bounds)
        ZStack {
            MinimapNodes(controller: controller, bounds: bounds).equatable()
            Canvas { context, _ in
                let view = visible.applying(transform)
                context.fill(Path(roundedRect: view, cornerRadius: 3), with: .color(Color.accentColor.opacity(0.08)))
                context.stroke(Path(roundedRect: view, cornerRadius: 3), with: .color(Color.accentColor.opacity(0.9)), lineWidth: 1.5)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if heldBounds == nil { heldBounds = bounds }
                    let map = Self.transform(for: heldBounds ?? bounds).inverted()
                    controller.centre(onWorld: value.location.applying(map), animated: value.translation == .zero)
                }
                .onEnded { _ in heldBounds = nil }
        )
        .help("Overview: click or drag to move around the map (⇧⌘M hides it)")
        .accessibilityElement()
        .accessibilityLabel("Minimap")
        .accessibilityHint("Drag to move around the map")
    }

    /// The map's extent, grown to take in the view when it strays outside. The growth is
    /// rounded to quarter-map steps so small pans do not redraw the nodes.
    static func extent(content: CGRect?, visible: CGRect) -> CGRect {
        guard let content else { return visible.insetBy(dx: -40, dy: -40) }
        var bounds = content.insetBy(dx: -40, dy: -40)
        guard !bounds.contains(visible) else { return bounds }
        let step = max(bounds.width, bounds.height, 200) / 4
        let grown = bounds.union(visible)
        let minX = bounds.minX - ((bounds.minX - grown.minX) / step).rounded(.up) * step
        let minY = bounds.minY - ((bounds.minY - grown.minY) / step).rounded(.up) * step
        let maxX = bounds.maxX + ((grown.maxX - bounds.maxX) / step).rounded(.up) * step
        let maxY = bounds.maxY + ((grown.maxY - bounds.maxY) / step).rounded(.up) * step
        bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return bounds
    }

    /// Maps map coordinates into the overview, fitting `bounds` with a small margin.
    static func transform(for bounds: CGRect) -> CGAffineTransform {
        let inner = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        let scale = min(inner.width / max(bounds.width, 1), inner.height / max(bounds.height, 1))
        return CGAffineTransform(translationX: inner.midX - bounds.midX * scale, y: inner.midY - bounds.midY * scale)
            .scaledBy(x: scale, y: scale)
    }
}

private struct MinimapNodes: View, Equatable {
    let controller: MapController
    let bounds: CGRect

    static func == (a: MinimapNodes, b: MinimapNodes) -> Bool {
        a.controller === b.controller && a.bounds == b.bounds
    }

    var body: some View {
        let transform = MinimapView.transform(for: bounds)
        let nodes = controller.visibleIDs.compactMap { id -> (rect: CGRect, color: Color)? in
            guard let rect = controller.worldRect(id), let node = controller.workspace.nodes[id] else { return nil }
            return (rect.applying(transform), node.data.effectiveColor.color)
        }
        Canvas { context, _ in
            for node in nodes {
                context.fill(Path(roundedRect: node.rect, cornerRadius: min(2, node.rect.height / 2)),
                             with: .color(node.color.opacity(0.8)))
            }
        }
    }
}

/// Shown at the top of the canvas in focus mode.
struct FocusBanner: View {
    let controller: MapController

    var body: some View {
        HStack(spacing: 10) {
            Label(controller.selection.isEmpty ? "Focus mode: select a node" : "Focus", systemImage: "scope")
                .font(.system(size: 12, weight: .semibold))
            if !controller.selection.isEmpty {
                Stepper(value: Binding(get: { controller.focusHops }, set: { controller.focusHops = $0 }), in: 1...6) {
                    Text("\(controller.focusHops) hop\(controller.focusHops == 1 ? "" : "s")")
                        .font(.system(size: 12).monospacedDigit())
                }
                .help("How far from the selection stays bright")
            }
            Button("Done") { controller.isFocusMode = false }
                .controlSize(.small)
                .help("Leave focus mode (⇧⌘F)")
        }
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
    }
}
