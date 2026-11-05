import AtlasCore
import AtlasLayout
import CoreGraphics
import Foundation

/// Where nodes go. With free placement that is wherever they were put. With an automatic
/// layout it is computed from the tree and the node sizes every time either changes, so
/// layouts never add undo steps of their own. Roots and pinned nodes keep their stored
/// positions and the layout grows around them.
extension MapController {

    // MARK: Display positions

    /// The observable display position of a node, created on first use.
    func display(_ id: UUID) -> NodeDisplay {
        if let existing = displays[id] { return existing }
        let display = NodeDisplay(targets[id] ?? placement(id)?.data.position ?? .zero)
        displays[id] = display
        return display
    }

    func displayCenter(_ id: UUID) -> CGPoint? {
        displays[id]?.center ?? targets[id] ?? placement(id)?.data.position
    }

    /// Recomputes every node's target and springs the nodes there. New nodes grow out of
    /// their parent; nodes being dragged stay under the pointer.
    func refreshPositions(animated: Bool) {
        targets = computeTargets()
        for id in displays.keys where targets[id] == nil { displays[id] = nil }
        defer {
            let bounds = targetBounds
            if bounds != contentBounds { contentBounds = bounds }
            updateCulling(force: true)
        }

        var start: [UUID: CGPoint] = [:]
        var end: [UUID: CGPoint] = [:]
        let dragging = nodeDrag?.moving ?? []
        for (id, target) in targets where !dragging.contains(id) {
            if displays[id] == nil {
                let origin = animated ? tree.parent[id].flatMap { displays[$0]?.center } : nil
                displays[id] = NodeDisplay(origin ?? target)
            }
            let current = displays[id]!.center
            if current != target {
                start[id] = current
                end[id] = target
            }
        }
        guard !end.isEmpty else { return }
        if animated {
            // Nodes already settled stay out of the animation, so retargeting mid-flight
            // does not restart them.
            layoutAnimator.animate(from: start, to: end) { [weak self] id, point in
                guard let self, self.nodeDrag?.moving.contains(id) != true else { return }
                self.displays[id]?.center = point
            }
        } else {
            layoutAnimator.stop()
            for (id, point) in end { displays[id]?.center = point }
        }
    }

    /// Every visible node's target position. Pass `includeHidden` to also place nodes inside
    /// collapsed branches (used when freezing a layout into free placement).
    func computeTargets(includeHidden: Bool = false, style: LayoutStyle? = nil) -> [UUID: CGPoint] {
        let style = style ?? self.style
        let ids = includeHidden ? tree.allIDs.filter { workspace.nodes[$0] != nil } : visibleIDs
        let present = Set(ids)
        var stored: [UUID: CGPoint] = [:]
        for id in ids { if let p = placement(id) { stored[id] = p.data.position } }
        guard style != .free else { return stored }

        let roots = tree.roots.filter(present.contains)
        var children: [UUID: [UUID]] = [:]
        for id in ids where includeHidden || !tree.collapsed.contains(id) {
            let kids = tree.children(of: id).filter(present.contains)
            if !kids.isEmpty { children[id] = kids }
        }
        var anchors: [UUID: CGPoint] = [:]
        for root in roots { anchors[root] = stored[root] }
        for id in tree.pinned where present.contains(id) { anchors[id] = stored[id] }
        var sizes: [UUID: CGSize] = [:]
        for id in ids { sizes[id] = nodeSize(id) }

        // A mind map keeps each main branch on the side of the central topic it was put on.
        var leftSide = Set<UUID>()
        if style == .mindMap {
            for root in roots {
                guard let rootX = stored[root]?.x else { continue }
                for kid in children[root] ?? [] where (stored[kid]?.x ?? rootX) < rootX { leftSide.insert(kid) }
            }
        }

        let input = TreeLayout.Input(roots: roots, children: children, sizes: sizes, anchors: anchors,
                                     leftSide: leftSide)
        var result = TreeLayout.positions(for: input, style: style)
        for (id, point) in stored where result[id] == nil { result[id] = point }
        return result
    }

    /// The layout's centres for a set of nodes, as shown (used when copying).
    func laidOutCenter(_ id: UUID) -> CGPoint? { targets[id] ?? placement(id)?.data.position }

    // MARK: Switching style

    /// Applies a layout style. Switching to free placement stores the laid-out positions,
    /// including those of collapsed branches, so nothing jumps; switching to a mind map
    /// shares the main branches between the two sides of each central topic.
    func setLayoutStyle(_ newStyle: LayoutStyle) {
        guard newStyle != style else { return }
        commitEditingIfNeeded()
        var positions: [UUID: CGPoint] = [:]
        if newStyle == .free {
            positions = computeTargets(includeHidden: true)
            for id in tree.pinned { positions[id] = nil }
        } else if newStyle == .mindMap {
            positions = balancedSides()
        }
        workspace.setLayoutStyle(newStyle, of: map, positions: positions)
    }

    /// Stored positions that put the first half of each root's branches (by size) on its
    /// right and the rest on its left.
    private func balancedSides() -> [UUID: CGPoint] {
        var positions: [UUID: CGPoint] = [:]
        for root in tree.roots {
            guard let rootPoint = placement(root)?.data.position else { continue }
            let kids = tree.children(of: root).filter { !tree.pinned.contains($0) }
            let weights = kids.map { CGFloat(1 + tree.descendants(of: $0).count) }
            let total = weights.reduce(0, +)
            var right: CGFloat = 0
            for (kid, weight) in zip(kids, weights) {
                let onRight = right + weight / 2 <= total / 2 || right == 0
                if onRight { right += weight }
                let y = placement(kid)?.data.position.y ?? rootPoint.y
                positions[kid] = CGPoint(x: rootPoint.x + (onRight ? 200 : -200), y: y)
            }
        }
        return positions
    }

    /// The side of a root a node's stored position puts it on (mind maps), as -1 or 1.
    func side(of id: UUID, relativeTo root: UUID) -> CGFloat {
        guard let x = placement(id)?.data.position.x, let rootX = placement(root)?.data.position.x else { return 1 }
        return x < rootX ? -1 : 1
    }

    /// Siblings that line up with a node on screen: in a mind map, the central topic's
    /// branches on the same side; otherwise all of them.
    func visualSiblings(of id: UUID) -> [UUID] {
        let siblings = tree.siblings(of: id)
        guard style == .mindMap, let parent = tree.parent[id], tree.parent[parent] == nil else { return siblings }
        let side = side(of: id, relativeTo: parent)
        return siblings.filter { tree.pinned.contains($0) == false && self.side(of: $0, relativeTo: parent) == side }
    }
}
