import AtlasCore
import AtlasLayout
import SwiftUI

/// Everything the edge canvas draws, in world coordinates. Building it in a view body (not
/// inside the Canvas closure) is what lets SwiftUI observe the positions it depends on.
struct EdgeScene {
    struct Connector {
        var geometry: Geometry.Connector
        var color: Color
        var width: CGFloat
        var opacity: Double
    }

    struct Relation {
        enum Emphasis { case normal, highlighted, selected }

        var curve: Geometry.RelationCurve
        var color: Color
        var style: LineStyle
        var hasArrow: Bool
        var label: String
        var emphasis: Emphasis
        var opacity: Double
        /// The two nodes' rectangles, which the label keeps clear of.
        var ends: [CGRect]
    }

    var connectors: [Connector] = []
    var relations: [Relation] = []
}

extension MapController {
    /// Builds the edge scene. Reads every visible node's display position, so it reruns
    /// whenever one moves.
    func edgeScene() -> EdgeScene {
        var scene = EdgeScene()
        scene.connectors.reserveCapacity(visibleIDs.count)
        let focused = focusedIDs
        let dimmed = 0.12
        for id in visibleIDs {
            guard let parentID = tree.parent[id], visibleSet.contains(parentID),
                  let childRect = worldRect(id), let parentRect = worldRect(parentID),
                  let child = workspace.nodes[id] else { continue }
            let connector = Geometry.treeConnector(from: parentRect, to: childRect, axis: connectorAxis)
            let bright = focused.map { $0.contains(id) && $0.contains(parentID) } ?? true
            scene.connectors.append(.init(geometry: connector,
                                          color: child.data.effectiveColor.color.opacity(0.55),
                                          width: isTopic(parentID) ? 2.5 : 1.8,
                                          opacity: bright ? 1 : dimmed))
        }

        // Connections of the selected or hovered nodes stand out.
        var highlighted = selection
        if let hovered = hoveredNodeID { highlighted.insert(hovered) }
        if let drag = connectDrag { highlighted.insert(drag.from) }
        for edge in mapEdges {
            let data = edge.data
            guard let curve = relationCurve(for: edge) else { continue }
            let emphasis: EdgeScene.Relation.Emphasis =
                edge.id == selectedEdgeID ? .selected
                : highlighted.contains(data.fromID) || highlighted.contains(data.toID) ? .highlighted : .normal
            let bright = focused.map { $0.contains(data.fromID) && $0.contains(data.toID) } ?? true
            scene.relations.append(.init(curve: curve, color: data.relation.color, style: data.lineStyle,
                                         hasArrow: data.hasArrow, label: data.displayLabel, emphasis: emphasis,
                                         opacity: bright || emphasis == .selected ? 1 : dimmed,
                                         ends: [data.fromID, data.toID].compactMap(worldRect)))
        }
        return scene
    }

    /// Org charts always connect top-to-bottom; elsewhere the connector picks the sides
    /// that face each other, so hand-placed nodes still connect naturally.
    var connectorAxis: Geometry.ConnectorAxis? {
        style == .orgChart ? .vertical : nil
    }
}

struct EdgeLayer: View {
    let controller: MapController

    var body: some View {
        EdgeCanvas(scene: controller.edgeScene(), controller: controller)
    }
}

private struct EdgeCanvas: View {
    let scene: EdgeScene
    let controller: MapController

    var body: some View {
        let viewport = controller.viewport
        Canvas { context, _ in
            context.translateBy(x: viewport.offset.x, y: viewport.offset.y)
            context.scaleBy(x: viewport.zoom, y: viewport.zoom)

            for connector in scene.connectors {
                let g = connector.geometry
                var path = Path()
                path.move(to: g.start)
                path.addCurve(to: g.end, control1: g.control1, control2: g.control2)
                context.stroke(path, with: .color(connector.color.opacity(connector.opacity)),
                               style: StrokeStyle(lineWidth: connector.width, lineCap: .round))
            }

            for relation in scene.relations {
                draw(relation, in: &context)
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ relation: EdgeScene.Relation, in context: inout GraphicsContext) {
        let curve = relation.curve
        var path = Path()
        path.move(to: curve.start)
        path.addQuadCurve(to: curve.end, control: curve.control)
        let color = relation.color.opacity(relation.opacity)
        let dash: [CGFloat] = switch relation.style {
        case .solid: []
        case .dashed: [7, 5]
        case .dotted: [1.5, 4]
        }
        if relation.emphasis == .selected {
            context.stroke(path, with: .color(Color.accentColor.opacity(0.35)),
                           style: StrokeStyle(lineWidth: 7, lineCap: .round))
        }
        let width: CGFloat = relation.emphasis == .normal ? 1.6 : 2.4
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
        if relation.hasArrow {
            context.fill(arrowHead(at: curve.end, from: curve.control, length: relation.emphasis == .normal ? 9 : 11),
                         with: .color(color))
        }
        if !relation.label.isEmpty {
            let text = context.resolve(Text(relation.label).font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(color))
            let size = text.measure(in: CGSize(width: 240, height: 40))
            let boxSize = CGSize(width: size.width + 10, height: size.height + 4)
            // Nodes are drawn over the edges, so a label that does not fit between two close
            // nodes moves beside its line instead of being hidden under them.
            let centre = Geometry.labelCenter(on: curve, size: boxSize, avoiding: relation.ends)
            let box = Geometry.rect(center: centre, size: boxSize)
            context.fill(Path(roundedRect: box, cornerRadius: box.height / 2),
                         with: .color(Color(nsColor: .textBackgroundColor).opacity(0.92 * relation.opacity)))
            context.stroke(Path(roundedRect: box, cornerRadius: box.height / 2),
                           with: .color(relation.color.opacity(0.4 * relation.opacity)), lineWidth: 0.8)
            context.draw(text, at: centre)
        }
    }

    private func arrowHead(at tip: CGPoint, from control: CGPoint, length: CGFloat) -> Path {
        let angle = atan2(tip.y - control.y, tip.x - control.x)
        let spread: CGFloat = .pi / 7
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: tip.x - length * cos(angle - spread), y: tip.y - length * sin(angle - spread)))
        path.addLine(to: CGPoint(x: tip.x - length * cos(angle + spread), y: tip.y - length * sin(angle + spread)))
        path.closeSubpath()
        return path
    }
}

/// Dotted background grid that thins out as you zoom out.
struct GridBackground: View {
    let controller: MapController

    var body: some View {
        let viewport = controller.viewport
        Canvas { context, size in
            var spacing: CGFloat = 24 * viewport.zoom
            while spacing < 14 { spacing *= 2 }
            let startX = viewport.offset.x.truncatingRemainder(dividingBy: spacing)
            let startY = viewport.offset.y.truncatingRemainder(dividingBy: spacing)
            let dot: CGFloat = viewport.zoom > 0.5 ? 1.6 : 1.2
            var path = Path()
            var x = startX < 0 ? startX + spacing : startX
            while x < size.width {
                var y = startY < 0 ? startY + spacing : startY
                while y < size.height {
                    path.addRect(CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
                    y += spacing
                }
                x += spacing
            }
            context.fill(path, with: .color(.primary.opacity(0.13)))
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
