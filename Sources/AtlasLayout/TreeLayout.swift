import CoreGraphics
import Foundation

/// Automatic layouts for the tree part of a map, as pure functions of structure and node
/// sizes, so they can be tested without any UI.
///
/// Roots and pinned nodes are anchors: they keep the centres given in `anchors`, and the
/// branch under each anchor is laid out around it. A pinned node takes no room in its
/// parent's branch, so pinning one never pushes its siblings around.
public enum TreeLayout {

    public struct Spacing: Equatable, Sendable {
        /// Sideways layouts: gap between a node and its children's column, and between branches.
        public var level: CGFloat = 48
        public var sibling: CGFloat = 12
        /// Org chart: gap between rows, and between neighbouring branches in a row.
        public var row: CGFloat = 44
        public var column: CGFloat = 18
        /// Radial: gap between rings, and the least gap between neighbours on one ring.
        public var ring: CGFloat = 40
        public var ringNeighbour: CGFloat = 16

        public init() {}
    }

    public struct Input<ID: Hashable> {
        /// Root ids in order. Every root needs an anchor.
        public var roots: [ID]
        /// The visible children of each node, in order. Leave out collapsed branches.
        public var children: [ID: [ID]]
        public var sizes: [ID: CGSize]
        /// Fixed centres: every root, plus pinned nodes.
        public var anchors: [ID: CGPoint]
        /// Mind map only: the children of a root that sit on its left.
        public var leftSide: Set<ID>

        public init(roots: [ID], children: [ID: [ID]], sizes: [ID: CGSize],
                    anchors: [ID: CGPoint], leftSide: Set<ID> = []) {
            self.roots = roots
            self.children = children
            self.sizes = sizes
            self.anchors = anchors
            self.leftSide = leftSide
        }
    }

    /// Centres for every node reachable from the roots. `.free` returns only the anchors.
    public static func positions<ID: Hashable>(for input: Input<ID>, style: LayoutStyle,
                                                spacing: Spacing = Spacing()) -> [ID: CGPoint] {
        var engine = Engine(input: input, style: style, spacing: spacing)
        engine.run()
        return engine.result
    }
}

private struct Engine<ID: Hashable> {
    let input: TreeLayout.Input<ID>
    let style: LayoutStyle
    let spacing: TreeLayout.Spacing
    var result: [ID: CGPoint] = [:]

    /// Pinned nodes waiting to be laid out, with the centre of their parent.
    private var pending: [(id: ID, parent: CGPoint)] = []
    private var heights: [ID: CGFloat] = [:]
    private var widths: [ID: CGFloat] = [:]
    private var leafCounts: [ID: Int] = [:]

    init(input: TreeLayout.Input<ID>, style: LayoutStyle, spacing: TreeLayout.Spacing) {
        self.input = input
        self.style = style
        self.spacing = spacing
    }

    mutating func run() {
        for root in input.roots where result[root] == nil {
            layOut(anchor: root, at: input.anchors[root] ?? .zero, parent: nil)
        }
        var index = 0
        while index < pending.count {
            let next = pending[index]
            index += 1
            guard result[next.id] == nil else { continue }
            layOut(anchor: next.id, at: input.anchors[next.id] ?? next.parent, parent: next.parent)
        }
    }

    // MARK: Helpers

    func size(_ id: ID) -> CGSize { input.sizes[id] ?? CGSize(width: 80, height: 32) }

    /// Children laid out together with their parent. Pinned children are anchors of their own.
    func flowing(_ id: ID) -> [ID] {
        (input.children[id] ?? []).filter { input.anchors[$0] == nil }
    }

    mutating func place(_ id: ID, _ center: CGPoint) {
        result[id] = center
        for child in input.children[id] ?? [] where input.anchors[child] != nil {
            pending.append((child, center))
        }
    }

    mutating func layOut(anchor id: ID, at center: CGPoint, parent: CGPoint?) {
        switch style {
        case .free:
            place(id, center)
        case .treeRight:
            placeBranch(id, center, direction: 1)
        case .orgChart:
            placeOrgChart(id, center)
        case .mindMap, .radial:
            if let parent {
                // A pinned branch grows away from its parent.
                placeBranch(id, center, direction: center.x < parent.x ? -1 : 1)
            } else if style == .mindMap {
                placeMindMapRoot(id, center)
            } else {
                placeRadial(id, center)
            }
        }
    }

    // MARK: Sideways (mind map, tree)

    /// Height of the band a branch needs when it grows sideways.
    mutating func bandHeight(_ id: ID) -> CGFloat {
        if let cached = heights[id] { return cached }
        let kids = flowing(id)
        let value = kids.isEmpty ? size(id).height : max(size(id).height, columnHeight(kids))
        heights[id] = value
        return value
    }

    mutating func columnHeight(_ kids: [ID]) -> CGFloat {
        var total: CGFloat = 0
        for kid in kids { total += bandHeight(kid) }
        return total + spacing.sibling * CGFloat(max(kids.count - 1, 0))
    }

    mutating func placeBranch(_ id: ID, _ center: CGPoint, direction: CGFloat) {
        place(id, center)
        placeColumn(flowing(id), beside: id, at: center, direction: direction)
    }

    /// Stacks `kids` in a column beside their parent, the column centred on the parent.
    mutating func placeColumn(_ kids: [ID], beside parent: ID, at center: CGPoint, direction: CGFloat) {
        guard !kids.isEmpty else { return }
        let edge = center.x + direction * (size(parent).width / 2 + spacing.level)
        var top = center.y - columnHeight(kids) / 2
        for kid in kids {
            let band = bandHeight(kid)
            let kidCenter = CGPoint(x: edge + direction * size(kid).width / 2, y: top + band / 2)
            placeBranch(kid, kidCenter, direction: direction)
            top += band + spacing.sibling
        }
    }

    mutating func placeMindMapRoot(_ id: ID, _ center: CGPoint) {
        place(id, center)
        let kids = flowing(id)
        placeColumn(kids.filter { !input.leftSide.contains($0) }, beside: id, at: center, direction: 1)
        placeColumn(kids.filter { input.leftSide.contains($0) }, beside: id, at: center, direction: -1)
    }

    // MARK: Org chart

    /// Width of the band a branch needs when it grows downwards.
    mutating func bandWidth(_ id: ID) -> CGFloat {
        if let cached = widths[id] { return cached }
        let kids = flowing(id)
        let value = kids.isEmpty ? size(id).width : max(size(id).width, rowWidth(kids))
        widths[id] = value
        return value
    }

    mutating func rowWidth(_ kids: [ID]) -> CGFloat {
        var total: CGFloat = 0
        for kid in kids { total += bandWidth(kid) }
        return total + spacing.column * CGFloat(max(kids.count - 1, 0))
    }

    mutating func placeOrgChart(_ id: ID, _ center: CGPoint) {
        // Each depth shares one centre line, so cards of different heights still line up.
        var rowHeights: [CGFloat] = []
        var level = [id]
        while !level.isEmpty {
            rowHeights.append(level.map { size($0).height }.max() ?? 0)
            level = level.flatMap { flowing($0) }
        }
        var rows = [center.y]
        for depth in rowHeights.indices.dropFirst() {
            rows.append(rows[depth - 1] + rowHeights[depth - 1] / 2 + spacing.row + rowHeights[depth] / 2)
        }
        placeOrgNode(id, x: center.x, depth: 0, rows: rows)
    }

    mutating func placeOrgNode(_ id: ID, x: CGFloat, depth: Int, rows: [CGFloat]) {
        place(id, CGPoint(x: x, y: rows[depth]))
        let kids = flowing(id)
        guard !kids.isEmpty else { return }
        var left = x - rowWidth(kids) / 2
        for kid in kids {
            let band = bandWidth(kid)
            placeOrgNode(kid, x: left + band / 2, depth: depth + 1, rows: rows)
            left += band + spacing.column
        }
    }

    // MARK: Radial

    mutating func leaves(_ id: ID) -> Int {
        if let cached = leafCounts[id] { return cached }
        var total = 0
        for kid in flowing(id) { total += leaves(kid) }
        let value = max(total, 1)
        leafCounts[id] = value
        return value
    }

    struct Slot {
        let id: ID
        let depth: Int
        let angle: CGFloat
    }

    /// Gives each child a slice of its parent's slice, in proportion to its leaves.
    mutating func assignAngles(_ id: ID, depth: Int, start: CGFloat, span: CGFloat, into slots: inout [Slot]) {
        let kids = flowing(id)
        guard !kids.isEmpty else { return }
        let total = CGFloat(leaves(id))
        var angle = start
        for kid in kids {
            let share = span * CGFloat(leaves(kid)) / total
            slots.append(Slot(id: kid, depth: depth + 1, angle: angle + share / 2))
            assignAngles(kid, depth: depth + 1, start: angle, span: share, into: &slots)
            angle += share
        }
    }

    mutating func placeRadial(_ id: ID, _ center: CGPoint) {
        place(id, center)
        let kids = flowing(id)
        guard let first = kids.first else { return }
        // The first branch sits at twelve o'clock and the rest follow clockwise.
        let firstShare = 2 * CGFloat.pi * CGFloat(leaves(first)) / CGFloat(leaves(id))
        var slots: [Slot] = []
        assignAngles(id, depth: 0, start: -.pi / 2 - firstShare / 2, span: 2 * .pi, into: &slots)

        let maxDepth = slots.map(\.depth).max() ?? 0
        guard maxDepth > 0 else { return }
        var reach = [CGFloat](repeating: 0, count: maxDepth + 1)
        reach[0] = halfDiagonal(id)
        for slot in slots { reach[slot.depth] = max(reach[slot.depth], halfDiagonal(slot.id)) }

        var radius = [CGFloat](repeating: 0, count: maxDepth + 1)
        for depth in 1...maxDepth {
            var r = radius[depth - 1] + reach[depth - 1] + spacing.ring + reach[depth]
            // Push the ring out until neighbours on it no longer overlap.
            let ring = slots.filter { $0.depth == depth }.sorted { $0.angle < $1.angle }
            if ring.count > 1 {
                for (i, a) in ring.enumerated() {
                    let b = ring[(i + 1) % ring.count]
                    var gap = b.angle - a.angle
                    if gap <= 0 { gap += 2 * .pi }
                    let needed = (tangentExtent(a.id, a.angle) + tangentExtent(b.id, b.angle)) / 2 + spacing.ringNeighbour
                    let chord = 2 * sin(min(gap, .pi) / 2)
                    if chord > 0.001 { r = max(r, needed / chord) }
                }
            }
            radius[depth] = r
        }
        for slot in slots {
            let r = radius[slot.depth]
            place(slot.id, CGPoint(x: center.x + r * cos(slot.angle), y: center.y + r * sin(slot.angle)))
        }
    }

    func halfDiagonal(_ id: ID) -> CGFloat {
        let s = size(id)
        return hypot(s.width, s.height) / 2
    }

    /// How much room a node takes along a ring at `angle`.
    func tangentExtent(_ id: ID, _ angle: CGFloat) -> CGFloat {
        let s = size(id)
        return s.width * abs(sin(angle)) + s.height * abs(cos(angle))
    }
}
