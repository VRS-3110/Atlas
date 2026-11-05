import AppKit
import AtlasCore
import AtlasLayout

/// Where a dragged branch would land if it were let go now.
struct DropTarget: Equatable {
    enum Slot: Equatable { case child, before, after }

    var nodeID: UUID
    var slot: Slot
}

/// What the canvas draws over the map while nodes are dragged, in map coordinates.
struct DragFeedback: Equatable {
    var drop: DropTarget?
    /// Where a before or after drop would insert the branch (two points, or none).
    var insertionLine: [CGPoint] = []
    var guides: [SnapGuides.Guide] = []
}

/// A drag of nodes: the selection's branches, or the members of a frame.
struct NodeDrag {
    /// The nodes that were picked up, in map order.
    var grabbed: [UUID]
    /// The node under the pointer; snapping and dropping are worked out for it.
    var lead: UUID
    /// Everything that follows the pointer: the grabbed nodes and their visible branches.
    var moving: Set<UUID>
    /// Where each moving node was drawn when the drag began.
    var start: [UUID: CGPoint]
    /// Where the lead node was in view coordinates when the drag began.
    var pointerStart: CGPoint
    var offset: CGSize = .zero
    var drop: DropTarget?
    /// The frame being dragged by its title, if any. Frame drags move nodes but never
    /// re-parent them.
    var frameID: UUID?
}

/// A drag that began on empty canvas (or anywhere while Space is held).
enum BackgroundDrag {
    case pan(last: CGPoint)
    case marquee(start: CGPoint, base: Set<UUID>)
}

/// Moving nodes, dropping branches onto other nodes, snapping, marquee selection and
/// panning with Space.
extension MapController {

    // MARK: Pointer drags that start on a node

    /// A drag that started on a node: moves the node (with the rest of the selection), or
    /// pans the canvas while Space is held. Points are in view coordinates.
    func nodePointerDragChanged(_ id: UUID, start: CGPoint, location: CGPoint, translation: CGSize) {
        if backgroundDrag != nil || (nodeDrag == nil && isSpaceHeld) {
            backgroundDragChanged(start: start, location: location)
        } else {
            dragChanged(id, translation: translation, location: location)
        }
    }

    func nodePointerDragEnded() {
        dragEnded()
        backgroundDragEnded()
    }

    // MARK: Moving nodes

    /// Moves the dragged nodes with the pointer. `translation` and `location` are in view
    /// coordinates; without a location the pointer is taken to have started on the node's
    /// centre.
    func dragChanged(_ id: UUID, translation: CGSize, location: CGPoint? = nil) {
        if nodeDrag == nil {
            guard visibleSet.contains(id) else { return }
            commitEditingIfNeeded()
            relationPicker = nil
            if !selection.contains(id) { select(id) }
            beginDrag(grabbed: selectedBranchRoots, lead: id)
        }
        updateDrag(translation: translation, location: location)
    }

    /// Drags the members of a frame by its title tab.
    func frameDragChanged(_ frameID: UUID, translation: CGSize) {
        if nodeDrag == nil {
            guard let frame = workspace.frames[frameID] else { return }
            commitEditingIfNeeded()
            if selectedFrameID != frameID { selectFrame(frameID) }
            let members = Set(frame.nodeIDs)
            let tops = visibleIDs.filter { members.contains($0) && !tree.ancestors(of: $0).contains(where: members.contains) }
            guard let lead = tops.first else { return }
            beginDrag(grabbed: tops, lead: lead, frameID: frameID)
        }
        updateDrag(translation: translation, location: nil)
    }

    private func beginDrag(grabbed: [UUID], lead: UUID, frameID: UUID? = nil) {
        var moving = Set<UUID>()
        for id in grabbed {
            moving.insert(id)
            for child in tree.descendants(of: id) where visibleSet.contains(child) { moving.insert(child) }
        }
        var start: [UUID: CGPoint] = [:]
        for id in moving { start[id] = displayCenter(id) }
        let pointer = displayCenter(lead).map(viewport.viewPoint) ?? .zero
        nodeDrag = NodeDrag(grabbed: grabbed, lead: lead, moving: moving, start: start,
                            pointerStart: pointer, frameID: frameID)
    }

    private func updateDrag(translation: CGSize, location: CGPoint?) {
        guard var drag = nodeDrag else { return }
        let zoom = viewport.zoom
        var offset = CGSize(width: translation.width / zoom, height: translation.height / zoom)
        let pointer = location ?? CGPoint(x: drag.pointerStart.x + translation.width,
                                          y: drag.pointerStart.y + translation.height)
        drag.drop = drag.frameID == nil ? dropTarget(at: worldPoint(pointer), excluding: drag.moving) : nil

        // Snap the lead node to its neighbours' edges and centre lines (⌘ turns this off).
        var guides: [SnapGuides.Guide] = []
        if drag.drop == nil, !NSEvent.modifierFlags.contains(.command), let leadStart = drag.start[drag.lead] {
            let moved = Geometry.rect(center: CGPoint(x: leadStart.x + offset.width, y: leadStart.y + offset.height),
                                      size: nodeSize(drag.lead))
            let snap = SnapGuides.snap(moved, to: snapCandidates(excluding: drag.moving), threshold: 6 / zoom)
            offset.width += snap.offset.width
            offset.height += snap.offset.height
            guides = snap.guides
        }
        drag.offset = offset
        nodeDrag = drag
        for id in drag.moving {
            guard let start = drag.start[id] else { continue }
            display(id).center = CGPoint(x: start.x + offset.width, y: start.y + offset.height)
        }

        let feedback = DragFeedback(drop: drag.drop, insertionLine: drag.drop.map(insertionLine) ?? [], guides: guides)
        if dragFeedback != feedback { dragFeedback = feedback }
        let highlight = drag.drop?.slot == .child ? drag.drop?.nodeID : nil
        if dropHighlightID != highlight { dropHighlightID = highlight }
    }

    /// Finishes a node drag: re-parents onto the drop target, or stores the new positions
    /// (pinning them in an automatic layout). Safe to call more than once.
    func dragEnded() {
        guard let drag = nodeDrag else { return }
        nodeDrag = nil
        dragFeedback = nil
        dropHighlightID = nil
        if let drop = drag.drop {
            finishDrop(drag, onto: drop)
        } else if hypot(drag.offset.width, drag.offset.height) > 0.5 {
            finishMove(drag)
        }
        // The nodes spring to where the layout has them now (back again if nothing changed).
        refreshPositions(animated: true)
    }

    /// Nodes near the view that a dragged node can line up with.
    private func snapCandidates(excluding: Set<UUID>) -> [CGRect] {
        let area = visibleWorldRect.insetBy(dx: -100, dy: -100)
        return visibleIDs.compactMap { id in
            guard !excluding.contains(id), let rect = worldRect(id), area.intersects(rect) else { return nil }
            return rect
        }
    }

    // MARK: Dropping onto nodes

    /// The drop target under a map point. The middle of a node makes the branch its child;
    /// with a tree or org chart layout, the top and bottom quarters (left and right in an
    /// org chart) put it before or after that node instead.
    func dropTarget(at point: CGPoint, excluding: Set<UUID>) -> DropTarget? {
        guard let id = visibleIDs.last(where: { !excluding.contains($0) && worldRect($0)?.contains(point) == true }),
              let rect = worldRect(id) else { return nil }
        let siblingDrops = tree.parent[id] != nil && style != .free && style != .radial
        if siblingDrops {
            if style == .orgChart {
                let band = rect.width * 0.25
                if point.x < rect.minX + band { return DropTarget(nodeID: id, slot: .before) }
                if point.x > rect.maxX - band { return DropTarget(nodeID: id, slot: .after) }
            } else {
                let band = rect.height * 0.3
                if point.y < rect.minY + band { return DropTarget(nodeID: id, slot: .before) }
                if point.y > rect.maxY - band { return DropTarget(nodeID: id, slot: .after) }
            }
        }
        return DropTarget(nodeID: id, slot: .child)
    }

    private func insertionLine(_ drop: DropTarget) -> [CGPoint] {
        guard drop.slot != .child, let rect = worldRect(drop.nodeID) else { return [] }
        if style == .orgChart {
            let x = drop.slot == .before ? rect.minX - 8 : rect.maxX + 8
            return [CGPoint(x: x, y: rect.minY - 2), CGPoint(x: x, y: rect.maxY + 2)]
        }
        let y = drop.slot == .before ? rect.minY - 6 : rect.maxY + 6
        return [CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX, y: y)]
    }

    private func finishDrop(_ drag: NodeDrag, onto drop: DropTarget) {
        let parent: UUID?
        let slot: SiblingPosition
        switch drop.slot {
        case .child: (parent, slot) = (drop.nodeID, .last)
        case .before: (parent, slot) = (tree.parent[drop.nodeID], .before(drop.nodeID))
        case .after: (parent, slot) = (tree.parent[drop.nodeID], .after(drop.nodeID))
        }

        var positions: [UUID: CGPoint] = [:]
        if style == .free, let parent, let leadStored = placement(drag.lead)?.data.position {
            // The branch moves next to its new parent, keeping its own shape.
            let target = childPosition(for: parent)
            positions = shiftedBranches(drag.grabbed, by: CGSize(width: target.x - leadStored.x,
                                                                 height: target.y - leadStored.y))
        } else if style == .mindMap, let parent, tree.parent[parent] == nil, let rootX = targets[parent]?.x {
            // A main branch goes on the side of the central topic it was dropped on.
            let side: CGFloat = switch drop.slot {
            case .child: (displayCenter(drag.lead)?.x ?? rootX) < rootX ? -1 : 1
            case .before, .after: self.side(of: drop.nodeID, relativeTo: parent)
            }
            for id in drag.grabbed {
                let y = placement(id)?.data.position.y ?? 0
                positions[id] = CGPoint(x: rootX + side * 200, y: y)
            }
        }

        let expand = drop.slot == .child && tree.collapsed.contains(drop.nodeID)
        let mapID = self.mapID
        let pinned: Bool? = style == .free ? nil : false
        workspace.perform("Move Branch") { _ in
            let moved = workspace.moveBranches(drag.grabbed, to: parent, at: slot, in: mapID, positions: positions,
                                               pinned: pinned)
            if moved, expand { workspace.setCollapsed(false, nodeIDs: [drop.nodeID], in: mapID) }
        }
    }

    // MARK: Dropping on empty canvas

    private func finishMove(_ drag: NodeDrag) {
        let offset = drag.offset
        if style == .free {
            let positions = shiftedBranches(drag.grabbed, by: offset)
            let name = drag.frameID != nil ? "Move Group" : drag.grabbed.count == 1 ? "Move Node" : "Move Nodes"
            workspace.setPositions(positions, in: mapID, actionName: name)
            return
        }

        guard let leadStart = drag.start[drag.lead] else { return }
        let leadEnd = CGPoint(x: leadStart.x + offset.width, y: leadStart.y + offset.height)

        // In a mind map, dragging a main branch across its central topic moves it to the
        // other side, among the branches already there.
        if style == .mindMap, drag.grabbed == [drag.lead], let root = tree.parent[drag.lead], tree.parent[root] == nil,
           let rootX = targets[root]?.x, (leadEnd.x < rootX) != (side(of: drag.lead, relativeTo: root) < 0) {
            let side: CGFloat = leadEnd.x < rootX ? -1 : 1
            let others = tree.children(of: root).filter {
                $0 != drag.lead && !tree.pinned.contains($0) && self.side(of: $0, relativeTo: root) == side
            }
            let below = others.first { (targets[$0]?.y ?? 0) > leadEnd.y }
            workspace.moveBranches([drag.lead], to: root, at: below.map { .before($0) } ?? .last, in: mapID,
                                   positions: [drag.lead: CGPoint(x: rootX + side * 200, y: leadEnd.y)],
                                   pinned: false, actionName: "Move Branch")
            return
        }

        // Elsewhere the moved nodes are pinned where they were put, unless they were let go
        // close to where the layout already has them. Roots simply move.
        let leadIsRoot = tree.parent[drag.lead] == nil
        if !leadIsRoot, let target = targets[drag.lead], hypot(leadEnd.x - target.x, leadEnd.y - target.y) < 20 {
            return
        }
        var positions: [UUID: CGPoint] = [:]
        var pinning = Set<UUID>()
        for top in drag.grabbed {
            guard let start = drag.start[top] else { continue }
            positions[top] = CGPoint(x: start.x + offset.width, y: start.y + offset.height)
            if tree.parent[top] != nil { pinning.insert(top) }
            // Pinned nodes further down stay where they are relative to the branch.
            for id in tree.descendants(of: top) where tree.pinned.contains(id) {
                guard let stored = placement(id)?.data.position else { continue }
                positions[id] = CGPoint(x: stored.x + offset.width, y: stored.y + offset.height)
            }
        }
        let name = drag.frameID != nil ? "Move Group" : pinning.isEmpty ? "Move" : "Pin in Place"
        workspace.setPositions(positions, in: mapID, pinning: pinning, actionName: name)
    }

    /// Stored positions for whole branches (collapsed parts included) moved by an offset.
    func shiftedBranches(_ tops: [UUID], by offset: CGSize) -> [UUID: CGPoint] {
        var positions: [UUID: CGPoint] = [:]
        for top in tops {
            for id in [top] + tree.descendants(of: top) {
                guard let stored = placement(id)?.data.position else { continue }
                positions[id] = CGPoint(x: stored.x + offset.width, y: stored.y + offset.height)
            }
        }
        return positions
    }

    // MARK: Marquee selection and panning

    /// A drag on empty canvas: pans while Space is held, otherwise draws a selection
    /// rectangle (⇧ or ⌘ adds to the selection). Points are in view coordinates.
    func backgroundDragChanged(start: CGPoint, location: CGPoint) {
        if backgroundDrag == nil {
            commitEditingIfNeeded()
            relationPicker = nil
            if isSpaceHeld {
                spaceDidPan = true
                backgroundDrag = .pan(last: start)
            } else {
                let flags = NSEvent.modifierFlags
                let extending = flags.contains(.shift) || flags.contains(.command)
                if !extending { clearSelection() }
                backgroundDrag = .marquee(start: start, base: extending ? selection : [])
            }
        }
        switch backgroundDrag {
        case .pan(let last):
            pan(by: CGSize(width: location.x - last.x, height: location.y - last.y))
            backgroundDrag = .pan(last: location)
        case .marquee(let start, let base):
            let rect = CGRect(x: min(start.x, location.x), y: min(start.y, location.y),
                              width: abs(location.x - start.x), height: abs(location.y - start.y))
            marquee = rect
            let world = viewport.worldRect(rect)
            let hits = visibleIDs.filter { worldRect($0)?.intersects(world) == true }
            let selected = base.union(hits)
            if selected != selection { setSelection(selected, primary: hits.last ?? primarySelection) }
        case nil:
            break
        }
    }

    func backgroundDragEnded() {
        guard backgroundDrag != nil else { return }
        backgroundDrag = nil
        marquee = nil
        focusCanvas()
    }

    // MARK: Space bar

    /// Space down: the canvas pans while it is held. Returns false for key repeats.
    func spaceDown() {
        guard !isSpaceHeld else { return }
        isSpaceHeld = true
        spaceDidPan = false
        NSCursor.openHand.set()
    }

    /// Space up: if the canvas was not panned, Space acts on the selection: it edits a
    /// node's title, a connection's relation or a frame's title.
    func spaceUp() {
        guard isSpaceHeld else { return }
        isSpaceHeld = false
        NSCursor.arrow.set()
        if !spaceDidPan { activateSelection() }
        spaceDidPan = false
    }

    /// Return or Space on a selected connection or frame, or Space on a node.
    func activateSelection() {
        if let edge = selectedEdgeID {
            showRelationPicker(for: [edge])
        } else if let frame = selectedFrameID {
            beginFrameEditing(frame)
        } else {
            beginEditing()
        }
    }
}
