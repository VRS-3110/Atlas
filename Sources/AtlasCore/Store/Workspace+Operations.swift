import CoreGraphics
import Foundation
import AtlasLayout

/// High-level, undoable editing commands. Each public method is one undo step.
extension Workspace {

    // MARK: Nodes

    /// Edits one node. Pass a `coalesce` key for continuous edits such as typing.
    public func updateNode(_ node: Node, _ actionName: String, coalesce: String? = nil,
                           coalesceWindow: TimeInterval? = nil, _ mutate: (inout NodeData) -> Void) {
        perform(actionName, coalesce: coalesce, coalesceWindow: coalesceWindow) { tx in tx.update(node, mutate) }
    }

    /// Applies the same edit to several nodes as one undo step.
    public func updateNodes(_ ids: some Sequence<UUID>, _ actionName: String,
                            _ mutate: (inout NodeData) -> Void) {
        perform(actionName) { tx in
            for id in ids { if let node = nodes[id] { tx.update(node, mutate) } }
        }
    }

    /// Creates a node that is not on any map (inbox captures, sources, planner tasks).
    @discardableResult
    public func createNode(_ data: NodeData, actionName: String = "New Node") -> Node {
        perform(actionName) { tx in tx.insert(data) }
    }

    /// Deletes nodes everywhere: from every map, with their edges and frame memberships.
    /// Children on maps move up to the deleted node's parent.
    public func deleteNodes(_ ids: Set<UUID>, actionName: String = "Delete") {
        guard !ids.isEmpty else { return }
        perform(actionName) { tx in
            for id in ids { deleteNodeCompletely(id, promoteChildren: true, tx: tx) }
        }
    }

    // MARK: Maps

    @discardableResult
    public func createMap(named name: String, layout: LayoutStyle = .mindMap,
                          rootTitle: String? = "Central Topic") -> MindMap {
        perform("New Map") { tx in
            let sortIndex = (maps.values.map(\.sortIndex).max() ?? 0) + 1
            let map = tx.insert(MapData(name: name, layoutStyle: layout, sortIndex: sortIndex, createdAt: clock()))
            if let rootTitle {
                let root = tx.insert(NodeData(title: rootTitle, kind: .idea, createdAt: clock()))
                tx.insert(PlacementData(mapID: map.id, nodeID: root.id, position: .zero))
            }
            return map
        }
    }

    public func renameMap(_ map: MindMap, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        perform("Rename Map") { tx in tx.update(map) { $0.name = trimmed } }
    }

    /// Deletes the map. Nodes that then appear nowhere else are deleted too.
    public func deleteMap(_ map: MindMap) {
        perform("Delete Map") { tx in
            let nodeIDs = Array(placements(in: map.id).keys)
            for frameID in frameIDsByMap[map.id] ?? [] {
                if let frame = frames[frameID] { tx.delete(frame) }
            }
            for placement in placements(in: map.id).values { tx.delete(placement) }
            for id in nodeIDs { deleteIfOrphaned(id, tx: tx) }
            tx.delete(map)
        }
    }

    /// Moves a map to a new position in the sidebar order.
    public func moveMap(_ map: MindMap, toIndex index: Int) {
        var ordered = sortedMaps.filter { $0.id != map.id }
        ordered.insert(map, at: max(0, min(index, ordered.count)))
        perform("Reorder Maps") { tx in
            for (i, m) in ordered.enumerated() { tx.update(m) { $0.sortIndex = Double(i) } }
        }
    }

    // MARK: Placing nodes on maps

    /// Creates a node on a map.
    @discardableResult
    public func addNode(_ data: NodeData, id: UUID = UUID(), to mapID: UUID, at position: CGPoint,
                        parent parentID: UUID? = nil, after siblingID: UUID? = nil,
                        actionName: String = "Add Node", coalesce: String? = nil) -> Node {
        perform(actionName, coalesce: coalesce) { tx in
            let node = tx.insert(data, id: id)
            insertPlacement(nodeID: node.id, mapID: mapID, at: position, parent: parentID,
                            after: siblingID, tx: tx)
            return node
        }
    }

    /// Adds a new empty child under `parentID`.
    @discardableResult
    public func addChild(to parentID: UUID, in mapID: UUID, at position: CGPoint? = nil,
                         data: NodeData? = nil) -> Node {
        let position = position ?? suggestedChildPosition(parent: parentID, in: mapID)
        return addNode(data ?? NodeData(createdAt: clock()), to: mapID, at: position,
                       parent: parentID, actionName: "Add Child")
    }

    /// Adds a new empty sibling right after `nodeID`. For a root node this adds a child
    /// instead, the usual mind-map behaviour for the central topic.
    @discardableResult
    public func addSibling(of nodeID: UUID, in mapID: UUID, at position: CGPoint? = nil,
                           data: NodeData? = nil) -> Node {
        guard let placement = placement(of: nodeID, in: mapID) else {
            return addNode(data ?? NodeData(createdAt: clock()), to: mapID, at: position ?? .zero)
        }
        guard let parentID = placement.parentID else {
            return addChild(to: nodeID, in: mapID, at: position, data: data)
        }
        let position = position ?? suggestedSiblingPosition(of: nodeID, in: mapID)
        return addNode(data ?? NodeData(createdAt: clock()), to: mapID, at: position,
                       parent: parentID, after: nodeID, actionName: "Add Sibling")
    }

    /// Puts an existing node (from the inbox, sources library or planner) onto a map.
    /// If it is already there, it is moved instead.
    public func placeNode(_ nodeID: UUID, on mapID: UUID, at position: CGPoint,
                          parent parentID: UUID? = nil) {
        guard let node = nodes[nodeID] else { return }
        perform("Add to Map") { tx in
            if let existing = placement(of: nodeID, in: mapID) {
                tx.update(existing) { $0.position = position }
            } else {
                insertPlacement(nodeID: nodeID, mapID: mapID, at: position, parent: parentID,
                                after: nil, tx: tx)
            }
            if node.inbox != .none { tx.update(node) { $0.inbox = .none } }
        }
    }

    /// Removes nodes and their descendants from one map. Nodes left on no map that are not
    /// sources, tasks or inbox items are deleted, with their edges.
    public func removeFromMap(_ nodeIDs: Set<UUID>, mapID: UUID, actionName: String = "Delete") {
        guard !nodeIDs.isEmpty else { return }
        let tree = tree(of: mapID)
        var doomed = Set<UUID>()
        for id in nodeIDs {
            doomed.insert(id)
            doomed.formUnion(tree.descendants(of: id))
        }
        perform(actionName) { tx in
            for id in doomed {
                if let p = placement(of: id, in: mapID) { tx.delete(p) }
            }
            for frameID in frameIDsByMap[mapID] ?? [] {
                guard let frame = frames[frameID] else { continue }
                let remaining = frame.nodeIDs.filter { !doomed.contains($0) }
                if remaining.isEmpty { tx.delete(frame) }
                else if remaining.count != frame.nodeIDs.count { tx.update(frame) { $0.nodeIDs = remaining } }
            }
            for id in doomed { deleteIfOrphaned(id, tx: tx) }
        }
    }

    // MARK: Positions and structure

    /// Sets absolute positions for nodes on one map as a single undo step. Nodes in
    /// `pinning` are also pinned, so automatic layouts leave them where they were put.
    public func setPositions(_ positions: [UUID: CGPoint], in mapID: UUID, pinning: Set<UUID> = [],
                             actionName: String = "Move") {
        perform(actionName) { tx in
            for (nodeID, point) in positions {
                guard let p = placement(of: nodeID, in: mapID) else { continue }
                tx.update(p) {
                    $0.position = point
                    if pinning.contains(nodeID) { $0.isPinned = true }
                }
            }
        }
    }

    /// Moves nodes on one map by an offset.
    public func moveNodes(_ nodeIDs: some Sequence<UUID>, by delta: CGSize, in mapID: UUID,
                          actionName: String = "Move", coalesce: String? = nil) {
        perform(actionName, coalesce: coalesce) { tx in
            for id in nodeIDs {
                guard let p = placement(of: id, in: mapID) else { continue }
                tx.update(p) {
                    $0.x += delta.width
                    $0.y += delta.height
                }
            }
        }
    }

    public func setCollapsed(_ collapsed: Bool, nodeIDs: some Sequence<UUID>, in mapID: UUID) {
        perform(collapsed ? "Collapse" : "Expand") { tx in
            for id in nodeIDs {
                guard let p = placement(of: id, in: mapID) else { continue }
                tx.update(p) { $0.isCollapsed = collapsed }
            }
        }
    }

    public func setPinned(_ pinned: Bool, nodeIDs: some Sequence<UUID>, in mapID: UUID) {
        perform(pinned ? "Pin" : "Unpin") { tx in
            for id in nodeIDs {
                guard let p = placement(of: id, in: mapID) else { continue }
                tx.update(p) { $0.isPinned = pinned }
            }
        }
    }

    /// Makes `nodeID` a child of `newParentID` (or a root for nil), placed after `siblingID`
    /// or last. Refuses moves that would create a cycle.
    @discardableResult
    public func reparent(_ nodeID: UUID, to newParentID: UUID?, after siblingID: UUID? = nil,
                         in mapID: UUID) -> Bool {
        guard let placement = placement(of: nodeID, in: mapID) else { return false }
        if let newParentID {
            guard newParentID != nodeID, self.placement(of: newParentID, in: mapID) != nil else { return false }
            if tree(of: mapID).isDescendant(newParentID, of: nodeID) { return false }
        }
        let order = siblingOrder(parent: newParentID, after: siblingID, in: mapID, excluding: nodeID)
        perform("Move Branch") { tx in
            tx.update(placement) {
                $0.parentID = newParentID
                $0.order = order
            }
        }
        return true
    }

    // MARK: Edges

    /// Connects two nodes with a relation. Returns nil when the ends are the same node.
    /// Pass a `coalesce` key to fold a follow-up edit (picking the relation) into this step.
    @discardableResult
    public func connect(_ fromID: UUID, to toID: UUID, relation: RelationType = .related,
                        label: String = "", coalesce: String? = nil) -> GraphEdge? {
        guard fromID != toID, nodes[fromID] != nil, nodes[toID] != nil else { return nil }
        return perform("Connect", coalesce: coalesce) { tx in
            tx.insert(EdgeData(from: fromID, to: toID, relation: relation, label: label, createdAt: clock()))
        }
    }

    public func updateEdge(_ edge: GraphEdge, _ actionName: String = "Edit Connection",
                           coalesce: String? = nil, coalesceWindow: TimeInterval? = nil,
                           _ mutate: (inout EdgeData) -> Void) {
        perform(actionName, coalesce: coalesce, coalesceWindow: coalesceWindow) { tx in tx.update(edge, mutate) }
    }

    /// Sets the relation of several edges, restyling each to the relation's defaults.
    public func setRelation(_ relation: RelationType, label: String = "", of edgeIDs: [UUID],
                            coalesce: String? = nil) {
        perform(edgeIDs.count == 1 ? "Change Relation" : "Change Relations", coalesce: coalesce,
                coalesceWindow: coalesce == nil ? nil : .infinity) { tx in
            for id in edgeIDs {
                guard let edge = edges[id] else { continue }
                tx.update(edge) {
                    $0.relation = relation
                    $0.label = relation == .custom ? label : ""
                    $0.lineStyle = relation.defaultLineStyle
                    $0.hasArrow = relation.defaultHasArrow
                }
            }
        }
    }

    /// Swaps an edge's ends.
    public func reverseEdge(_ edge: GraphEdge) {
        perform("Reverse Connection") { tx in
            tx.update(edge) { swap(&$0.fromID, &$0.toID) }
        }
    }

    public func deleteEdges(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        perform(ids.count == 1 ? "Delete Connection" : "Delete Connections") { tx in
            for id in ids { if let e = edges[id] { tx.delete(e) } }
        }
    }

    // MARK: - Helpers

    /// Order value that places a node after `siblingID` (or last) among `parent`'s children.
    func siblingOrder(parent: UUID?, after siblingID: UUID?, in mapID: UUID, excluding: UUID? = nil) -> Double {
        let siblings = placements(in: mapID).values
            .filter { $0.parentID == parent && $0.data.nodeID != excluding }
            .map(\.data)
            .sorted { $0.order < $1.order }
        guard let siblingID, let index = siblings.firstIndex(where: { $0.nodeID == siblingID }) else {
            return (siblings.last?.order ?? -1) + 1
        }
        let current = siblings[index].order
        if index + 1 < siblings.count {
            return (current + siblings[index + 1].order) / 2
        }
        return current + 1
    }

    func insertPlacement(nodeID: UUID, mapID: UUID, at position: CGPoint, parent parentID: UUID?,
                         after siblingID: UUID?, tx: Transaction) {
        let validParent = parentID.flatMap { placement(of: $0, in: mapID) != nil ? $0 : nil }
        let order = siblingOrder(parent: validParent, after: siblingID, in: mapID)
        tx.insert(PlacementData(mapID: mapID, nodeID: nodeID, position: position,
                                parentID: validParent, order: order))
    }

    /// A reasonable spot for a new child before any layout runs: to the side of the parent,
    /// below its last child.
    public func suggestedChildPosition(parent parentID: UUID, in mapID: UUID) -> CGPoint {
        guard let parent = placement(of: parentID, in: mapID) else { return .zero }
        let tree = tree(of: mapID)
        let side: CGFloat = {
            guard let grand = tree.parent[parentID], let gp = placement(of: grand, in: mapID) else { return 1 }
            return parent.x >= gp.x ? 1 : -1
        }()
        if let last = tree.children(of: parentID).last, let lp = placement(of: last, in: mapID) {
            return CGPoint(x: lp.x, y: lp.y + 56)
        }
        return CGPoint(x: parent.x + 220 * side, y: parent.y)
    }

    public func suggestedSiblingPosition(of nodeID: UUID, in mapID: UUID) -> CGPoint {
        guard let p = placement(of: nodeID, in: mapID) else { return .zero }
        return CGPoint(x: p.x, y: p.y + 56)
    }

    /// Whether a node has any home left: a map, the inbox, the sources library, the planner,
    /// or (for a quote) its source's quote list.
    func isOrphaned(_ node: Node) -> Bool {
        (placementIDsByNode[node.id] ?? []).isEmpty && node.inbox == .none
            && node.source == nil && node.task == nil
            && !(node.kind == .quote && !node.citations.isEmpty)
    }

    func deleteIfOrphaned(_ nodeID: UUID, tx: Transaction) {
        guard let node = nodes[nodeID], isOrphaned(node) else { return }
        deleteNodeCompletely(nodeID, promoteChildren: false, tx: tx)
    }

    func deleteNodeCompletely(_ nodeID: UUID, promoteChildren: Bool, tx: Transaction) {
        guard let node = nodes[nodeID] else { return }
        for placementID in placementIDsByNode[nodeID] ?? [] {
            guard let placement = placements[placementID] else { continue }
            if promoteChildren {
                let mapID = placement.mapID
                for child in placements(in: mapID).values where child.parentID == nodeID {
                    tx.update(child) { $0.parentID = placement.parentID }
                }
            }
            tx.delete(placement)
        }
        for edgeID in edgeIDsByNode[nodeID] ?? [] {
            if let edge = edges[edgeID] { tx.delete(edge) }
        }
        for frame in frames.values where frame.nodeIDs.contains(nodeID) {
            let remaining = frame.nodeIDs.filter { $0 != nodeID }
            if remaining.isEmpty { tx.delete(frame) } else { tx.update(frame) { $0.nodeIDs = remaining } }
        }
        if node.source != nil {
            for citing in citingNodes(of: nodeID) {
                tx.update(citing) { $0.citations.removeAll { $0.sourceID == nodeID } }
            }
        }
        tx.delete(node)
    }
}
