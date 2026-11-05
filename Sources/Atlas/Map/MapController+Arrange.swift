import AppKit
import AtlasCore
import AtlasLayout

/// Align and distribute, frames, pins, reordering and indenting, focus mode and hover.
extension MapController {

    // MARK: Align and distribute

    func align(_ alignment: Arrange.Alignment) {
        let rects = selectedRects()
        guard rects.count >= 2 else {
            NSSound.beep()
            return
        }
        place(Arrange.align(rects, to: alignment), actionName: "Align \(alignment.title)")
    }

    func distribute(_ axis: Arrange.Axis) {
        let rects = selectedRects()
        guard rects.count >= 3 else {
            NSSound.beep()
            return
        }
        place(Arrange.distribute(rects, along: axis), actionName: "Distribute \(axis.title)")
    }

    var canAlign: Bool { selection.count >= 2 }
    var canDistribute: Bool { selection.count >= 3 }

    private func selectedRects() -> [UUID: CGRect] {
        var rects: [UUID: CGRect] = [:]
        for id in selection { rects[id] = targetRect(id) }
        return rects
    }

    /// Moves nodes to new centres as one step, their branches coming along. In an automatic
    /// layout the moved nodes are pinned there (roots simply move, since they always keep
    /// their place).
    func place(_ centres: [UUID: CGPoint], actionName: String) {
        commitEditingIfNeeded()
        var deltas: [UUID: CGSize] = [:]
        for (id, centre) in centres {
            guard let from = targets[id] ?? placement(id)?.data.position else { continue }
            deltas[id] = CGSize(width: centre.x - from.x, height: centre.y - from.y)
        }
        guard deltas.values.contains(where: { abs($0.width) > 0.01 || abs($0.height) > 0.01 }) else { return }

        let free = style == .free
        var positions: [UUID: CGPoint] = [:]
        var inherited: [UUID: CGSize] = [:]
        for id in tree.allIDs {
            guard let delta = deltas[id] ?? tree.parent[id].flatMap({ inherited[$0] }) else { continue }
            inherited[id] = delta
            if let centre = centres[id] {
                positions[id] = centre
            } else if free || tree.pinned.contains(id), let stored = placement(id)?.data.position {
                // Automatic layouts place the rest of the branch themselves.
                positions[id] = CGPoint(x: stored.x + delta.width, y: stored.y + delta.height)
            }
        }
        let pinning = free ? [] : Set(centres.keys.filter { tree.parent[$0] != nil })
        workspace.setPositions(positions, in: mapID, pinning: pinning, actionName: actionName)
    }

    // MARK: Frames

    /// ⌥⌘G: draws a frame around the selected branches and starts naming it. Naming it
    /// joins the same undo step.
    func groupSelection() {
        commitEditingIfNeeded()
        let members = selectedBranchRoots
        let key = "group-\(UUID().uuidString)"
        let mapID = self.mapID
        guard !members.isEmpty,
              let frame = workspace.perform("Group", coalesce: key, { _ in workspace.createFrame(on: mapID, around: members) })
        else {
            NSSound.beep()
            return
        }
        beginFrameEditing(frame.id, coalesceKey: key)
    }

    /// ⇧⌥⌘G: removes the selected frame, or the frames around the selected nodes.
    func ungroup() {
        commitEditingIfNeeded()
        if let id = selectedFrameID {
            workspace.deleteFrames([id])
            return
        }
        let ids = Set(mapFrames.filter { $0.nodeIDs.contains(where: selection.contains) }.map(\.id))
        guard !ids.isEmpty else {
            NSSound.beep()
            return
        }
        workspace.deleteFrames(ids)
    }

    var canGroup: Bool { !selection.isEmpty }
    var canUngroup: Bool {
        selectedFrameID != nil || mapFrames.contains { $0.nodeIDs.contains(where: selection.contains) }
    }

    static let framePadding: CGFloat = 18
    static let frameTitleHeight: CGFloat = 24

    /// A frame's rectangle as drawn: around its visible members and their visible branches,
    /// with room above for the title. Nil when none of its members is visible.
    func frameRect(_ frame: MapFrame) -> CGRect? {
        var rects: [CGRect] = []
        for id in frame.nodeIDs where visibleSet.contains(id) {
            if let rect = worldRect(id) { rects.append(rect) }
            for child in tree.descendants(of: id) where visibleSet.contains(child) {
                if let rect = worldRect(child) { rects.append(rect) }
            }
        }
        guard let bounds = Geometry.union(rects) else { return nil }
        let pad = Self.framePadding
        return CGRect(x: bounds.minX - pad, y: bounds.minY - pad - Self.frameTitleHeight,
                      width: bounds.width + pad * 2, height: bounds.height + pad * 2 + Self.frameTitleHeight)
    }

    /// Where a frame's title tab sits, in map coordinates (its leading centre).
    func frameTitleAnchor(_ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + 10, y: rect.minY + Self.frameTitleHeight / 2 + 4)
    }

    func beginFrameEditing(_ id: UUID, coalesceKey: String? = nil) {
        guard mapFrames.contains(where: { $0.id == id }) else { return }
        selectFrame(id)
        editingFrameID = id
        frameTitleKey = coalesceKey ?? "frame-title-\(id.uuidString)"
    }

    /// Typing in a frame's title field; the whole edit is one undo step.
    func renameFrame(_ text: String) {
        guard let id = editingFrameID, let frame = workspace.frames[id], frame.title != text else { return }
        workspace.perform("Rename Group", coalesce: frameTitleKey, coalesceWindow: .infinity) { tx in
            tx.update(frame) { $0.title = text }
        }
    }

    func endFrameEditing() {
        guard editingFrameID != nil else { return }
        editingFrameID = nil
        frameTitleKey = nil
        workspace.history.breakCoalescing()
        focusCanvasSoon()
    }

    func setFrameColor(_ color: NodeColor) {
        guard let id = selectedFrameID, let frame = workspace.frames[id] else { return }
        workspace.updateFrame(frame, "Change Colour") { $0.color = color }
    }

    /// Selects a frame's members.
    func selectMembers(of frameID: UUID) {
        guard let frame = workspace.frames[frameID] else { return }
        let members = frame.nodeIDs.filter(visibleSet.contains)
        setSelection(Set(members), primary: members.first)
        focusCanvas()
    }

    // MARK: Pins

    /// Selected nodes that can be pinned (roots always keep their place).
    private var pinnableSelection: [UUID] { selection.filter { tree.parent[$0] != nil } }

    var selectionIsPinned: Bool {
        let ids = pinnableSelection
        return !ids.isEmpty && ids.allSatisfy(tree.pinned.contains)
    }

    var canPin: Bool { style != .free && !pinnableSelection.isEmpty }

    /// Pins the selected nodes where the layout has them now, or unpins them if they all are.
    func togglePin() {
        let ids = pinnableSelection
        guard !ids.isEmpty else {
            NSSound.beep()
            return
        }
        if ids.allSatisfy(tree.pinned.contains) {
            workspace.setPinned(false, nodeIDs: ids, in: mapID)
        } else {
            var positions: [UUID: CGPoint] = [:]
            for id in ids { positions[id] = targets[id] ?? placement(id)?.data.position }
            workspace.setPositions(positions, in: mapID, pinning: Set(ids), actionName: "Pin")
        }
    }

    func unpinAll() {
        workspace.unpinAll(in: mapID)
    }

    // MARK: Reordering and indenting

    /// ⌥⌘↑ and ⌥⌘↓: moves the selected node before or after its neighbour on screen. In free
    /// placement the two branches also swap places.
    func moveSelection(by step: Int) {
        commitEditingIfNeeded()
        guard let id = primarySelection, let parent = tree.parent[id] else {
            NSSound.beep()
            return
        }
        let siblings = visualSiblings(of: id)
        guard let index = siblings.firstIndex(of: id), siblings.indices.contains(index + step) else {
            NSSound.beep()
            return
        }
        let other = siblings[index + step]
        var positions: [UUID: CGPoint] = [:]
        if style == .free, let a = placement(id)?.data.position, let b = placement(other)?.data.position {
            positions = shiftedBranches([id], by: CGSize(width: b.x - a.x, height: b.y - a.y))
            positions.merge(shiftedBranches([other], by: CGSize(width: a.x - b.x, height: a.y - b.y))) { first, _ in first }
        }
        workspace.moveBranches([id], to: parent, at: step < 0 ? .before(other) : .after(other), in: mapID,
                               positions: positions, actionName: step < 0 ? "Move Up" : "Move Down")
    }

    /// ⌘] or Tab-like indent: each selected branch becomes the last child of the sibling above it.
    func indentSelection() {
        commitEditingIfNeeded()
        let ids = selectedBranchRoots
        guard !ids.isEmpty else { return }
        let mapID = self.mapID
        let done = workspace.perform("Indent") { _ in
            ids.reduce(false) { workspace.indent($1, in: mapID) || $0 }
        }
        if !done { NSSound.beep() }
    }

    /// ⌘[ or ⇧Tab: each selected branch moves up a level, after its parent.
    func outdentSelection() {
        commitEditingIfNeeded()
        let ids = selectedBranchRoots
        guard !ids.isEmpty else { return }
        let mapID = self.mapID
        // Last first, so branches that share a parent keep their order.
        let done = workspace.perform("Outdent") { _ in
            ids.reversed().reduce(false) { workspace.outdent($1, in: mapID) || $0 }
        }
        if !done { NSSound.beep() }
    }

    // MARK: Focus mode

    func toggleFocusMode() {
        isFocusMode.toggle()
    }

    /// Recomputes which nodes stay bright: those within `focusHops` of the selection,
    /// following tree links and connections. Nothing is dimmed without a selection.
    func refreshFocus() {
        guard isFocusMode, !selection.isEmpty else {
            if focusedIDs != nil { focusedIDs = nil }
            return
        }
        var reach = Set<UUID>()
        for id in selection {
            reach.formUnion(workspace.hopDistances(from: id, in: mapID, maxHops: focusHops).keys)
        }
        if focusedIDs != reach { focusedIDs = reach }
    }

    func isDimmed(_ id: UUID) -> Bool {
        focusedIDs.map { !$0.contains(id) } ?? false
    }

    // MARK: Hover

    /// The pointer entered or left a node (or its connection handles). Leaving is delayed
    /// a moment so the pointer can travel from the node to a handle.
    func hoverChanged(_ id: UUID, inside: Bool) {
        if inside {
            hoverClearTask?.cancel()
            hoverClearTask = nil
            if hoveredNodeID != id { hoveredNodeID = id }
        } else if hoveredNodeID == id {
            hoverClearTask?.cancel()
            hoverClearTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled, let self, self.hoveredNodeID == id, self.connectDrag == nil else { return }
                self.hoveredNodeID = nil
            }
        }
    }
}
