import Foundation

/// A snapshot of one map's parent/child structure, built from its placements.
/// Cheap to build (linear in the number of placements) and safe against bad data:
/// placements whose parent is missing become roots, and cycles are broken.
public struct MapTree: Sendable {
    public let mapID: UUID
    /// Root node ids, in sibling order.
    public let roots: [UUID]
    /// Parent node id → ordered child node ids.
    public let children: [UUID: [UUID]]
    /// Child node id → parent node id.
    public let parent: [UUID: UUID]
    public let collapsed: Set<UUID>
    public let pinned: Set<UUID>

    public init(mapID: UUID, placements: [Placement]) {
        self.mapID = mapID
        let present = Set(placements.map(\.data.nodeID))
        var parent: [UUID: UUID] = [:]
        var buckets: [UUID: [(order: Double, id: UUID)]] = [:]
        var rootList: [(order: Double, id: UUID)] = []
        var collapsed = Set<UUID>()
        var pinned = Set<UUID>()

        for p in placements {
            let d = p.data
            if d.isCollapsed { collapsed.insert(d.nodeID) }
            if d.isPinned { pinned.insert(d.nodeID) }
            if let pid = d.parentID, pid != d.nodeID, present.contains(pid) {
                parent[d.nodeID] = pid
            }
        }

        // Break cycles: walk up from every node; if we revisit a node, cut its parent link.
        for start in parent.keys {
            var seen: Set<UUID> = [start]
            var current = start
            while let up = parent[current] {
                if seen.contains(up) {
                    parent[current] = nil
                    break
                }
                seen.insert(up)
                current = up
            }
        }

        for p in placements {
            let d = p.data
            if let pid = parent[d.nodeID] {
                buckets[pid, default: []].append((d.order, d.nodeID))
            } else {
                rootList.append((d.order, d.nodeID))
            }
        }

        func sorted(_ items: [(order: Double, id: UUID)]) -> [UUID] {
            items.sorted { $0.order != $1.order ? $0.order < $1.order : $0.id.uuidString < $1.id.uuidString }
                .map(\.id)
        }

        self.parent = parent
        self.children = buckets.mapValues(sorted)
        self.roots = sorted(rootList)
        self.collapsed = collapsed
        self.pinned = pinned
    }

    public func children(of id: UUID) -> [UUID] { children[id] ?? [] }

    /// Siblings including the node itself, in order.
    public func siblings(of id: UUID) -> [UUID] {
        if let p = parent[id] { return children(of: p) }
        return roots
    }

    public func ancestors(of id: UUID) -> [UUID] {
        var result: [UUID] = []
        var current = id
        while let up = parent[current] {
            result.append(up)
            current = up
        }
        return result
    }

    public func depth(of id: UUID) -> Int { ancestors(of: id).count }

    public func root(of id: UUID) -> UUID { ancestors(of: id).last ?? id }

    /// All descendants in pre-order (not including the node itself).
    public func descendants(of id: UUID) -> [UUID] {
        var result: [UUID] = []
        var stack = children(of: id).reversed() as [UUID]
        while let next = stack.popLast() {
            result.append(next)
            stack.append(contentsOf: children(of: next).reversed())
        }
        return result
    }

    /// Whether `ancestor` is above `id` in the tree.
    public func isDescendant(_ id: UUID, of ancestor: UUID) -> Bool {
        ancestors(of: id).contains(ancestor)
    }

    /// True when no ancestor is collapsed.
    public func isVisible(_ id: UUID) -> Bool {
        !ancestors(of: id).contains { collapsed.contains($0) }
    }

    /// Visible node ids in pre-order (descendants of collapsed nodes are skipped).
    public var visibleIDs: [UUID] {
        var result: [UUID] = []
        var stack = roots.reversed() as [UUID]
        while let next = stack.popLast() {
            result.append(next)
            if !collapsed.contains(next) {
                stack.append(contentsOf: children(of: next).reversed())
            }
        }
        return result
    }

    /// Number of nodes hidden under a collapsed node (0 when expanded).
    public func hiddenCount(under id: UUID) -> Int {
        collapsed.contains(id) ? descendants(of: id).count : 0
    }

    /// Every node id in the tree in pre-order.
    public var allIDs: [UUID] {
        var result: [UUID] = []
        var stack = roots.reversed() as [UUID]
        while let next = stack.popLast() {
            result.append(next)
            stack.append(contentsOf: children(of: next).reversed())
        }
        return result
    }
}
