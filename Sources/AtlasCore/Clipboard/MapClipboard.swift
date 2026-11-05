import CoreGraphics
import Foundation
import AtlasLayout

/// Branches copied from a map, independent of the workspace they came from. Pasting makes
/// new nodes, so a copy never shares identity with its original.
public struct MapClipboard: Codable, Equatable, Sendable {
    /// Pasteboard type for copies between Atlas windows.
    public static let pasteboardType = "local.atlas.branches"

    public struct Item: Codable, Equatable, Sendable {
        /// The original node id. It only links items and edges inside the clip.
        public var key: UUID
        public var data: NodeData
        /// The parent's `key`, when the parent was copied too.
        public var parent: UUID?
        /// Centre relative to the first item.
        public var offsetX: Double
        public var offsetY: Double
        public var isCollapsed: Bool

        public init(key: UUID, data: NodeData, parent: UUID?, offset: CGPoint, isCollapsed: Bool = false) {
            self.key = key
            self.data = data
            self.parent = parent
            self.offsetX = offset.x
            self.offsetY = offset.y
            self.isCollapsed = isCollapsed
        }
    }

    /// Parents before children, siblings in order.
    public var items: [Item]
    /// Relations between copied nodes, still using the original ids.
    public var edges: [EdgeData]

    public init(items: [Item] = [], edges: [EdgeData] = []) {
        self.items = items
        self.edges = edges
    }

    public var isEmpty: Bool { items.isEmpty }

    /// The copied branches as an outline of titles.
    public var outline: [OutlineText.Item] {
        var children: [UUID: [Item]] = [:]
        var tops: [Item] = []
        for item in items {
            if let parent = item.parent { children[parent, default: []].append(item) } else { tops.append(item) }
        }
        func convert(_ item: Item) -> OutlineText.Item {
            OutlineText.Item(item.data.title, children: (children[item.key] ?? []).map(convert))
        }
        return tops.map(convert)
    }

    /// A clip made from an outline of titles, arranged as a tree growing to the right.
    public init(outline: [OutlineText.Item], kind: NodeKind = .idea, createdAt: Date = .now) {
        let virtualRoot = UUID()
        var items: [Item] = []
        var children: [UUID: [UUID]] = [:]
        var sizes: [UUID: CGSize] = [virtualRoot: .zero]
        func add(_ entry: OutlineText.Item, parent: UUID?) {
            let key = UUID()
            items.append(Item(key: key, data: NodeData(title: entry.title, kind: kind, createdAt: createdAt),
                              parent: parent, offset: .zero))
            children[parent ?? virtualRoot, default: []].append(key)
            // A rough size; the map measures the real one.
            sizes[key] = CGSize(width: min(260, 48 + CGFloat(entry.title.count) * 7), height: 32)
            for child in entry.children { add(child, parent: key) }
        }
        for entry in outline { add(entry, parent: nil) }

        let input = TreeLayout.Input(roots: [virtualRoot], children: children, sizes: sizes,
                                     anchors: [virtualRoot: .zero])
        let positions = TreeLayout.positions(for: input, style: .treeRight)
        let origin = items.first.flatMap { positions[$0.key] } ?? .zero
        for index in items.indices {
            let p = positions[items[index].key] ?? origin
            items[index].offsetX = p.x - origin.x
            items[index].offsetY = p.y - origin.y
        }
        self.init(items: items)
    }
}

extension Workspace {

    /// Copies branches (each node with everything below it, collapsed or not) from a map.
    /// `position` gives each node's centre as shown, since automatic layouts are not stored.
    public func copyBranches(_ nodeIDs: Set<UUID>, in mapID: UUID,
                             position: (UUID) -> CGPoint?) -> MapClipboard {
        let tree = tree(of: mapID)
        let tops = tree.allIDs.filter { id in
            nodeIDs.contains(id) && !tree.ancestors(of: id).contains(where: nodeIDs.contains)
        }
        var included: [UUID] = []
        for top in tops { included += [top] + tree.descendants(of: top) }
        guard let first = included.first else { return MapClipboard() }
        let origin = position(first) ?? placement(of: first, in: mapID)?.data.position ?? .zero
        let set = Set(included)

        var clip = MapClipboard()
        for id in included {
            guard let node = nodes[id] else { continue }
            let p = position(id) ?? placement(of: id, in: mapID)?.data.position ?? origin
            let parent = tree.parent[id].flatMap { set.contains($0) ? $0 : nil }
            clip.items.append(.init(key: id, data: node.data, parent: parent,
                                    offset: CGPoint(x: p.x - origin.x, y: p.y - origin.y),
                                    isCollapsed: tree.collapsed.contains(id)))
        }
        var seen = Set<UUID>()
        for id in included {
            for edgeID in edgeIDsByNode[id] ?? [] where !seen.contains(edgeID) {
                seen.insert(edgeID)
                if let edge = edges[edgeID], set.contains(edge.fromID), set.contains(edge.toID) {
                    clip.edges.append(edge.data)
                }
            }
        }
        clip.edges.sort { $0.createdAt < $1.createdAt }
        return clip
    }

    /// Pastes new copies of a clip's nodes onto a map. The clip's top-level nodes go under
    /// `parentID` (or become roots) at `position` among its children, with the first one
    /// centred on `origin`. Returns the new top-level node ids.
    @discardableResult
    public func paste(_ clip: MapClipboard, into mapID: UUID, under parentID: UUID?,
                      at position: SiblingPosition = .last, origin: CGPoint,
                      actionName: String = "Paste") -> [UUID] {
        guard !clip.isEmpty, maps[mapID] != nil else { return [] }
        let parentID = parentID.flatMap { placement(of: $0, in: mapID) != nil ? $0 : nil }
        return perform(actionName) { tx in
            let now = clock()
            var newIDs: [UUID: UUID] = [:]
            var tops: [UUID] = []
            var nextOrder: [UUID: Double] = [:]
            for item in clip.items {
                let id = UUID()
                newIDs[item.key] = id
                var data = item.data
                data.createdAt = now
                data.updatedAt = now
                data.inbox = .none
                tx.insert(data, id: id)
                let parent = item.parent.flatMap { newIDs[$0] }
                if parent == nil { tops.append(id) }
                let order = parent.map { p -> Double in
                    defer { nextOrder[p, default: 0] += 1 }
                    return nextOrder[p, default: 0]
                } ?? 0
                tx.insert(PlacementData(mapID: mapID, nodeID: id,
                                        position: CGPoint(x: origin.x + item.offsetX, y: origin.y + item.offsetY),
                                        parentID: parent, order: order, isCollapsed: item.isCollapsed))
            }
            for edge in clip.edges {
                guard let from = newIDs[edge.fromID], let to = newIDs[edge.toID] else { continue }
                var copy = edge
                copy.fromID = from
                copy.toID = to
                copy.createdAt = now
                tx.insert(copy)
            }
            // Slot the top-level copies in among their new siblings.
            moveBranches(tops, to: parentID, at: position, in: mapID, actionName: actionName)
            return tops
        }
    }
}
