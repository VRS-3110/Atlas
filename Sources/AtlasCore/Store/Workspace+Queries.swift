import CoreGraphics
import Foundation

extension Workspace {

    // MARK: Maps

    /// Maps in sidebar order.
    public var sortedMaps: [MindMap] {
        maps.values.sorted {
            $0.sortIndex != $1.sortIndex
                ? $0.sortIndex < $1.sortIndex
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func placements(in mapID: UUID) -> [UUID: Placement] {
        placementsByMap[mapID] ?? [:]
    }

    public func placement(of nodeID: UUID, in mapID: UUID) -> Placement? {
        placementsByMap[mapID]?[nodeID]
    }

    public func tree(of mapID: UUID) -> MapTree {
        MapTree(mapID: mapID, placements: Array(placements(in: mapID).values))
    }

    /// Maps the node appears on, in sidebar order.
    public func maps(containing nodeID: UUID) -> [MindMap] {
        let mapIDs = Set((placementIDsByNode[nodeID] ?? []).compactMap { placements[$0]?.data.mapID })
        return sortedMaps.filter { mapIDs.contains($0.id) }
    }

    // MARK: Edges

    public func edges(touching nodeID: UUID) -> [GraphEdge] {
        (edgeIDsByNode[nodeID] ?? []).compactMap { edges[$0] }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Relation edges whose two ends are both on the map.
    public func edges(in mapID: UUID) -> [GraphEdge] {
        let onMap = placements(in: mapID)
        var seen = Set<UUID>()
        var result: [GraphEdge] = []
        for nodeID in onMap.keys {
            for edgeID in edgeIDsByNode[nodeID] ?? [] where !seen.contains(edgeID) {
                seen.insert(edgeID)
                guard let edge = edges[edgeID] else { continue }
                if onMap[edge.fromID] != nil, onMap[edge.toID] != nil { result.append(edge) }
            }
        }
        return result
    }

    public func edge(between a: UUID, and b: UUID) -> GraphEdge? {
        (edgeIDsByNode[a] ?? []).lazy.compactMap { self.edges[$0] }.first { $0.data.connects(a, b) }
    }

    // MARK: Collections

    public var inboxNodes: [Node] {
        nodes.values.filter { $0.inbox == .inbox }.sorted { $0.createdAt > $1.createdAt }
    }

    public var sourceNodes: [Node] {
        nodes.values.filter { $0.source != nil }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public var taskNodes: [Node] {
        nodes.values.filter { $0.task != nil }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Tags with the number of nodes using each. Tags differing only in case are merged.
    public func tagCounts() -> [(tag: String, count: Int)] {
        var counts: [String: (display: String, count: Int)] = [:]
        for node in nodes.values where node.inbox != .archived {
            for tag in node.tags {
                let key = tag.lowercased()
                counts[key, default: (tag, 0)].count += 1
            }
        }
        return counts.values
            .map { (tag: $0.display, count: $0.count) }
            .sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
    }

    public func nodes(taggedWith tag: String) -> [Node] {
        nodes.values.filter { $0.data.hasTag(tag) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Nodes citing the source.
    public func citingNodes(of sourceID: UUID) -> [Node] {
        nodes.values.filter { node in node.citations.contains { $0.sourceID == sourceID } }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: Backlinks

    public struct Backlinks {
        public var maps: [MindMap] = []
        /// Edges pointing at the node, with the node at the other end.
        public var incoming: [(edge: GraphEdge, node: Node)] = []
        /// Edges leaving the node, with the node at the other end.
        public var outgoing: [(edge: GraphEdge, node: Node)] = []
        /// Nodes that cite this node (when it is a source).
        public var citedBy: [Node] = []
        /// Sources this node cites.
        public var cites: [(citation: Citation, source: Node)] = []
        /// Nodes whose body mentions this node as `[[Title]]`.
        public var mentionedBy: [Node] = []

        public var isEmpty: Bool {
            maps.isEmpty && incoming.isEmpty && outgoing.isEmpty && citedBy.isEmpty && cites.isEmpty
                && mentionedBy.isEmpty
        }
    }

    /// Everything that references the node: maps it appears on, relation edges, citations and
    /// `[[wiki links]]` in other nodes' bodies.
    public func backlinks(of nodeID: UUID) -> Backlinks {
        var result = Backlinks()
        guard let node = nodes[nodeID] else { return result }
        result.maps = maps(containing: nodeID)
        for edge in edges(touching: nodeID) {
            if edge.toID == nodeID, let other = nodes[edge.fromID] {
                result.incoming.append((edge, other))
            } else if edge.fromID == nodeID, let other = nodes[edge.toID] {
                result.outgoing.append((edge, other))
            }
        }
        if node.source != nil { result.citedBy = citingNodes(of: nodeID) }
        result.cites = node.citations.compactMap { c in nodes[c.sourceID].map { (c, $0) } }
        let title = node.title.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty {
            let needle = "[[\(title.lowercased())]]"
            result.mentionedBy = nodes.values
                .filter { $0.id != nodeID && $0.body.lowercased().contains(needle) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return result
    }

    // MARK: Graph distance

    /// Number of hops from `start` to every node reachable on the map within `maxHops`,
    /// following both tree links and relation edges in either direction.
    public func hopDistances(from start: UUID, in mapID: UUID, maxHops: Int) -> [UUID: Int] {
        let onMap = placements(in: mapID)
        guard onMap[start] != nil else { return [:] }
        let tree = tree(of: mapID)
        var distance: [UUID: Int] = [start: 0]
        var frontier = [start]
        var hops = 0
        while !frontier.isEmpty, hops < maxHops {
            hops += 1
            var next: [UUID] = []
            for id in frontier {
                var neighbours = tree.children(of: id)
                if let p = tree.parent[id] { neighbours.append(p) }
                for edgeID in edgeIDsByNode[id] ?? [] {
                    guard let edge = edges[edgeID] else { continue }
                    let other = edge.fromID == id ? edge.toID : edge.fromID
                    if onMap[other] != nil { neighbours.append(other) }
                }
                for n in neighbours where distance[n] == nil {
                    distance[n] = hops
                    next.append(n)
                }
            }
            frontier = next
        }
        return distance
    }

    // MARK: Search

    /// Nodes whose title (or, with lower rank, other text) matches every word of `query`.
    public func searchNodes(_ query: String, limit: Int = 50) -> [Node] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var scored: [(score: Int, node: Node)] = []
        for node in nodes.values where node.inbox != .archived {
            let title = node.title.lowercased()
            let text = node.data.searchableText.lowercased()
            guard words.allSatisfy({ text.contains($0) }) else { continue }
            var score = 0
            if title == query.lowercased() { score += 100 }
            if title.hasPrefix(words[0]) { score += 20 }
            score += words.filter { title.contains($0) }.count * 10
            scored.append((score, node))
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.node.updatedAt > $1.node.updatedAt }
            .prefix(limit)
            .map(\.node)
    }
}
