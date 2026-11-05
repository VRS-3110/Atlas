import AppKit
import AtlasCore
import AtlasLayout

/// A connection being dragged out of a node's handle.
struct ConnectDrag: Equatable {
    var from: UUID
    /// The pointer, in map coordinates.
    var pointer: CGPoint
    /// The node under the pointer, which the connection would go to.
    var target: UUID?
}

/// The inline menu of relation types, shown after connecting nodes or for a connection.
struct RelationPicker: Equatable {
    var edgeIDs: [UUID]
    /// Folds the choice into the step that made the connections, so connecting and picking
    /// the relation undo together.
    var coalesceKey: String?
    /// Where the menu points, in map coordinates.
    var anchor: CGPoint
}

/// Relation edges on the canvas: hit testing, connecting by dragging, and picking a relation.
extension MapController {

    /// The curve of a relation edge as drawn now, if both ends are visible.
    func relationCurve(for edge: GraphEdge) -> Geometry.RelationCurve? {
        guard visibleSet.contains(edge.fromID), visibleSet.contains(edge.toID),
              let a = worldRect(edge.fromID), let b = worldRect(edge.toID) else { return nil }
        return Geometry.relationCurve(from: a, to: b)
    }

    /// The connection passing closest to a point in view coordinates, within a few points.
    func edge(atView point: CGPoint) -> UUID? {
        let world = worldPoint(point)
        let tolerance = 6 / viewport.zoom
        var best: (id: UUID, distance: CGFloat)?
        for edge in mapEdges {
            guard let curve = relationCurve(for: edge) else { continue }
            let distance = curve.distance(to: world)
            if distance <= tolerance, distance < (best?.distance ?? .infinity) { best = (edge.id, distance) }
        }
        return best?.id
    }

    // MARK: Dragging out a connection

    /// The pointer moved while dragging from a node's connection handle (view coordinates).
    func connectDragChanged(from id: UUID, location: CGPoint) {
        if connectDrag == nil {
            commitEditingIfNeeded()
            relationPicker = nil
        }
        let world = worldPoint(location)
        let target = visibleIDs.last { $0 != id && worldRect($0)?.contains(world) == true }
        let drag = ConnectDrag(from: id, pointer: world, target: target)
        if connectDrag != drag { connectDrag = drag }
    }

    /// Let go of a connection: over a node it connects the two, then asks for the relation.
    func connectDragEnded() {
        guard let drag = connectDrag else { return }
        connectDrag = nil
        if let target = drag.target { connect([(drag.from, target)]) }
    }

    /// ⌘L: connects each other selected node to the primary one (the last one clicked).
    func connectSelection() {
        commitEditingIfNeeded()
        guard selection.count >= 2, let primary = primarySelection else {
            NSSound.beep()
            return
        }
        let others = visibleIDs.filter { selection.contains($0) && $0 != primary }
        connect(others.map { ($0, primary) })
    }

    var canConnectSelection: Bool { selection.count >= 2 }

    /// Connects pairs of nodes in one undo step and opens the relation menu for the new
    /// connections. A pair that is already connected opens the menu for that connection.
    private func connect(_ pairs: [(from: UUID, to: UUID)]) {
        let key = "connect-\(UUID().uuidString)"
        var created: [UUID] = []
        var existing: [UUID] = []
        workspace.perform("Connect", coalesce: key) { _ in
            for pair in pairs {
                if let edge = workspace.edge(between: pair.from, and: pair.to) {
                    existing.append(edge.id)
                } else if let edge = workspace.connect(pair.from, to: pair.to) {
                    created.append(edge.id)
                }
            }
        }
        if !created.isEmpty {
            showRelationPicker(for: created, coalesceKey: key)
        } else if let edge = existing.first {
            showRelationPicker(for: [edge])
        } else {
            NSSound.beep()
        }
    }

    // MARK: The relation menu

    /// Opens the relation menu at the first connection's midpoint. A single connection is
    /// selected too, so the inspector shows it.
    func showRelationPicker(for edgeIDs: [UUID], coalesceKey: String? = nil) {
        guard let first = edgeIDs.lazy.compactMap({ self.workspace.edges[$0] }).compactMap(relationCurve).first else { return }
        if edgeIDs.count == 1 { selectEdge(edgeIDs[0]) }
        relationPicker = RelationPicker(edgeIDs: edgeIDs, coalesceKey: coalesceKey, anchor: first.midpoint)
        focusCanvas()
    }

    func pickRelation(_ relation: RelationType) {
        guard let picker = relationPicker else { return }
        relationPicker = nil
        workspace.setRelation(relation, of: picker.edgeIDs, coalesce: picker.coalesceKey)
        focusCanvas()
    }

    /// Digit keys 1–6 pick a relation while the menu is open.
    func pickRelation(number: Int) -> Bool {
        let all = RelationType.allCases
        guard relationPicker != nil, (1...all.count).contains(number) else { return false }
        pickRelation(all[number - 1])
        return true
    }

    func dismissRelationPicker() {
        relationPicker = nil
    }

    /// The relation shared by every connection in the menu, if they agree.
    var pickerRelation: RelationType? {
        guard let picker = relationPicker else { return nil }
        let relations = Set(picker.edgeIDs.compactMap { workspace.edges[$0]?.relation })
        return relations.count == 1 ? relations.first : nil
    }
}
