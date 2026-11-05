import AppKit
import AtlasCore
import AtlasLayout
import Observation

/// Interaction state for one map in one window: viewport, selection, layout, inline editing
/// and drags. All model changes go through the shared `Workspace`.
///
/// The rest of the controller lives in extensions: `+Layout` (where nodes go and how they
/// animate there), `+Viewport`, `+Drag` (moving nodes, marquee), `+Connections`,
/// `+Arrange` (align, frames, pins, focus mode) and `+Clipboard`.
@MainActor
@Observable
final class MapController {
    let workspace: Workspace
    let map: MindMap
    var mapID: UUID { map.id }
    /// The map's layout style, observed through the map entity.
    var style: LayoutStyle { map.layoutStyle }

    // MARK: View state

    var viewport = Viewport() {
        didSet {
            if !autoFit { scheduleViewportSave() }
            updateCulling()
        }
    }
    var canvasSize: CGSize = .zero {
        didSet {
            // Until the user moves the view, keep the whole map in view while the window
            // (sidebar, inspector) settles into its final size.
            if autoFit, canvasSize != oldValue, canvasSize.width > 120, canvasSize.height > 120 {
                viewport = fittingViewport()
            }
            updateCulling()
        }
    }

    // MARK: Selection: nodes, or one connection, or one frame

    var selection: Set<UUID> = [] {
        didSet { if selection != oldValue { selectionDidChange() } }
    }
    var primarySelection: UUID?
    var selectedEdgeID: UUID?
    var selectedFrameID: UUID?

    // MARK: Inline editing

    private(set) var editingNodeID: UUID?
    private(set) var editingIsNew = false
    var editingFrameID: UUID?

    // MARK: Feedback drawn over the canvas while the pointer is busy

    var dragFeedback: DragFeedback?
    /// The node a dragged branch would become a child of (kept apart from `dragFeedback`
    /// so that only the node layer's highlight, not every node, follows the pointer).
    var dropHighlightID: UUID?
    var marquee: CGRect?
    var connectDrag: ConnectDrag?
    var relationPicker: RelationPicker?
    var hoveredNodeID: UUID?

    // MARK: Focus mode

    var isFocusMode = false {
        didSet { if isFocusMode != oldValue { refreshFocus() } }
    }
    /// How many hops from the selection stay bright in focus mode.
    var focusHops = MapController.savedFocusHops {
        didSet {
            UserDefaults.standard.set(focusHops, forKey: "atlas.focusHops")
            refreshFocus()
        }
    }
    /// Nodes within reach of the selection in focus mode; nil when nothing is dimmed.
    var focusedIDs: Set<UUID>?

    // MARK: Cached structure (refreshed when placements, edges or frames change)

    private(set) var tree: MapTree
    private(set) var visibleIDs: [UUID] = []
    private(set) var visibleSet: Set<UUID> = []
    /// The visible nodes drawn as views: on a large map only those in or near the part in
    /// view (see `updateCulling`).
    var renderedIDs: [UUID] = []
    private(set) var mapEdges: [GraphEdge] = []
    private(set) var mapFrames: [MapFrame] = []

    // MARK: Helpers (not observed)

    @ObservationIgnored let metrics = NodeMetrics()
    @ObservationIgnored weak var keyView: NSView?
    /// Where each visible node belongs: the layout's answer, or the stored position.
    @ObservationIgnored var targets: [UUID: CGPoint] = [:]
    /// Where each visible node is drawn right now (it differs from `targets` mid-animation
    /// and mid-drag). One observable object per node, so moving one redraws only that one.
    @ObservationIgnored var displays: [UUID: NodeDisplay] = [:]
    @ObservationIgnored let layoutAnimator = LayoutAnimator()
    @ObservationIgnored let viewportAnimator = ViewportAnimator()
    /// True until the user pans, zooms or the app scrolls to a node.
    @ObservationIgnored var autoFit = true
    @ObservationIgnored var viewportSaveTask: Task<Void, Never>?
    @ObservationIgnored private var editingOrigin: UUID?
    @ObservationIgnored var nodeDrag: NodeDrag?
    @ObservationIgnored var backgroundDrag: BackgroundDrag?
    @ObservationIgnored var isSpaceHeld = false
    @ObservationIgnored var spaceDidPan = false
    @ObservationIgnored var hoverClearTask: Task<Void, Never>?
    /// True while something covers the canvas (the command palette), so scrolling there
    /// does not pan the map.
    @ObservationIgnored var isObscured = false
    /// The undo step a frame's title edit joins (the "Group" step, for a new frame).
    @ObservationIgnored var frameTitleKey: String?
    /// Where the layout puts the visible nodes (the minimap's extent), refreshed with the layout.
    var contentBounds: CGRect?
    /// The map area `renderedIDs` covers; nil when every visible node is drawn.
    @ObservationIgnored var cullRect: CGRect?

    private static var savedFocusHops: Int {
        let saved = UserDefaults.standard.integer(forKey: "atlas.focusHops")
        return (1...6).contains(saved) ? saved : 2
    }

    init(map: MindMap, workspace: Workspace) {
        self.map = map
        self.workspace = workspace
        self.tree = workspace.tree(of: map.id)
        if let saved = ViewportStore.load(map.id) {
            autoFit = false
            viewport = saved
        }
        refreshStructure(animated: false)
        workspace.addChangeObserver(self) { [weak self] set, _ in
            self?.workspaceDidChange(set)
        }
    }

    // MARK: - Reacting to changes

    private func workspaceDidChange(_ set: ChangeSet) {
        var structural = false
        var relayout = false
        var edgesChanged = false
        var framesChanged = false
        var styleChanged = false
        for change in set.changes {
            switch change.key.kind {
            case .placement:
                let (before, after) = change.values(PlacementData.self)
                guard before?.mapID == mapID || after?.mapID == mapID else { continue }
                if let before, let after {
                    if before.parentID != after.parentID || before.isCollapsed != after.isCollapsed
                        || before.order != after.order || before.isPinned != after.isPinned {
                        structural = true
                    }
                    if before.position != after.position { relayout = true }
                } else {
                    structural = true
                }
            case .node:
                if change.isInsert || change.isDelete {
                    structural = true
                } else if visibleSet.contains(change.key.id), sizeChanged(change) {
                    relayout = true
                }
            case .edge:
                edgesChanged = true
            case .frame:
                let (before, after) = change.values(FrameData.self)
                if before?.mapID == mapID || after?.mapID == mapID { framesChanged = true }
            case .map:
                guard change.key.id == mapID else { continue }
                relayout = true
                let (before, after) = change.values(MapData.self)
                if before?.layoutStyle != after?.layoutStyle { styleChanged = true }
            case .dayLog:
                break
            }
        }
        let boundsBefore = styleChanged ? targetBounds : nil
        if structural {
            refreshStructure()
        } else {
            if edgesChanged {
                refreshEdges()
                refreshFocus()
            }
            if framesChanged { refreshFrames() }
            if relayout { refreshPositions(animated: true) }
        }
        // A new layout can grow out of view; bring it all back in. (Switching to free
        // placement leaves every node where it was, so the view stays where it is.)
        if styleChanged, targetBounds?.integral != boundsBefore?.integral { fitIfOutOfView() }
        if let editing = editingNodeID, workspace.nodes[editing] == nil || !visibleSet.contains(editing) {
            editingNodeID = nil
            editingIsNew = false
        }
        if let edge = selectedEdgeID, !mapEdges.contains(where: { $0.id == edge }) { selectedEdgeID = nil }
        if let frame = selectedFrameID, !mapFrames.contains(where: { $0.id == frame }) {
            selectedFrameID = nil
            editingFrameID = nil
        }
        if let picker = relationPicker, !picker.edgeIDs.contains(where: { workspace.edges[$0] != nil }) {
            relationPicker = nil
        }
    }

    /// Whether an edit to a node changed the size it is drawn at.
    private func sizeChanged(_ change: Change) -> Bool {
        let (before, after) = change.values(NodeData.self)
        guard let before, let after else { return false }
        let topic = isTopic(change.key.id)
        return metrics.size(for: before, isTopic: topic) != metrics.size(for: after, isTopic: topic)
    }

    /// After undo or redo in this window, selects what the step touched on this map so the
    /// keyboard can carry on from there: the nodes it added or changed, or else the
    /// parents of the nodes it removed, or else the connection or frame it touched.
    func selectAfterHistoryStep(_ set: ChangeSet) {
        guard editingNodeID == nil else { return }
        var touched: [UUID] = []
        var parentsOfRemoved: [UUID] = []
        var edge: UUID?
        var frame: UUID?
        for change in set.changes {
            switch change.key.kind {
            case .placement:
                let (before, after) = change.values(PlacementData.self)
                if let after, after.mapID == mapID {
                    touched.append(after.nodeID)
                } else if let before, before.mapID == mapID, let parent = before.parentID {
                    parentsOfRemoved.append(parent)
                }
            case .node where !change.isDelete:
                touched.append(change.key.id)
            case .edge where !change.isDelete:
                edge = change.key.id
            case .frame where !change.isDelete:
                frame = change.key.id
            default:
                break
            }
        }
        let candidates = (touched.isEmpty ? parentsOfRemoved : touched).filter(visibleSet.contains)
        if let primary = candidates.last {
            setSelection(Set(candidates), primary: primary)
        } else if let edge, mapEdges.contains(where: { $0.id == edge }) {
            selectEdge(edge)
        } else if let frame, mapFrames.contains(where: { $0.id == frame }) {
            selectFrame(frame)
        }
    }

    func refreshStructure(animated: Bool = true) {
        tree = workspace.tree(of: mapID)
        let ids = tree.visibleIDs.filter { workspace.nodes[$0] != nil }
        visibleIDs = ids
        visibleSet = Set(ids)
        let pruned = selection.intersection(visibleSet)
        if pruned != selection { selection = pruned }
        if let primary = primarySelection, !visibleSet.contains(primary) { primarySelection = selection.first }
        refreshEdges()
        refreshFrames()
        refreshPositions(animated: animated)
        refreshFocus()
    }

    private func refreshEdges() {
        mapEdges = workspace.edges(in: mapID).sorted { $0.createdAt < $1.createdAt }
    }

    private func refreshFrames() {
        mapFrames = workspace.frames(in: mapID)
    }

    // MARK: - Geometry

    func placement(_ id: UUID) -> Placement? { workspace.placement(of: id, in: mapID) }

    /// Roots with children are drawn as topics: larger and bolder.
    func isTopic(_ id: UUID) -> Bool { tree.parent[id] == nil && !tree.children(of: id).isEmpty }

    func nodeSize(_ id: UUID) -> CGSize {
        guard let node = workspace.nodes[id] else { return NodeMetrics.minimumSize }
        return metrics.size(for: node.data, isTopic: isTopic(id))
    }

    /// Where the node is drawn right now.
    func worldRect(_ id: UUID) -> CGRect? {
        guard let center = displayCenter(id) else { return nil }
        return Geometry.rect(center: center, size: nodeSize(id))
    }

    /// Where the node is headed (equal to `worldRect` once animations settle).
    func targetRect(_ id: UUID) -> CGRect? {
        guard let center = targets[id] ?? placement(id)?.data.position else { return nil }
        return Geometry.rect(center: center, size: nodeSize(id))
    }

    func viewRect(_ id: UUID) -> CGRect? { worldRect(id).map(viewport.viewRect) }

    func worldPoint(_ view: CGPoint) -> CGPoint { viewport.worldPoint(view) }

    var viewCenter: CGPoint { CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2) }

    /// The topmost visible node under a point in view coordinates.
    func node(atView point: CGPoint) -> UUID? {
        let world = worldPoint(point)
        return visibleIDs.last { worldRect($0)?.contains(world) == true }
    }

    // MARK: - Selection

    private func selectionDidChange() {
        if cullRect != nil { updateCulling(force: true) }
        if !selection.isEmpty {
            selectedEdgeID = nil
            selectedFrameID = nil
            relationPicker = nil
        }
        refreshFocus()
    }

    func select(_ id: UUID, extending: Bool = false) {
        if extending {
            if selection.contains(id) {
                selection.remove(id)
                if primarySelection == id { primarySelection = selection.first }
            } else {
                selection.insert(id)
                primarySelection = id
            }
        } else if selection != [id] || primarySelection != id {
            selection = [id]
            primarySelection = id
        }
    }

    func setSelection(_ ids: Set<UUID>, primary: UUID? = nil) {
        selection = ids.intersection(visibleSet)
        primarySelection = primary.flatMap { selection.contains($0) ? $0 : nil } ?? selection.first
    }

    func clearSelection() {
        if !selection.isEmpty { selection = [] }
        primarySelection = nil
        selectedEdgeID = nil
        selectedFrameID = nil
        relationPicker = nil
    }

    func selectAll() {
        selection = visibleSet
        primarySelection = primarySelection ?? visibleIDs.first
    }

    func selectEdge(_ id: UUID) {
        commitEditingIfNeeded()
        if !selection.isEmpty { selection = [] }
        primarySelection = nil
        selectedFrameID = nil
        selectedEdgeID = id
        focusCanvas()
    }

    func selectFrame(_ id: UUID) {
        commitEditingIfNeeded()
        if !selection.isEmpty { selection = [] }
        primarySelection = nil
        selectedEdgeID = nil
        relationPicker = nil
        selectedFrameID = id
        focusCanvas()
    }

    /// Single click on a node: ⇧ or ⌘ toggles it in the selection.
    func handleClick(on id: UUID) {
        if editingNodeID != nil, editingNodeID != id { commitEditing() }
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        select(id, extending: flags.contains(.shift) || flags.contains(.command))
        focusCanvas()
    }

    /// A click on empty canvas selects the connection under it, if any, else clears.
    func handleBackgroundClick(at point: CGPoint? = nil) {
        if editingNodeID != nil { commitEditing() }
        // In the zoomed-out overview nodes are drawn, not views, so clicks land here.
        if let point, isOverview, let id = node(atView: point) {
            select(id, extending: NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command))
        } else if let point, let edge = edge(atView: point) {
            selectEdge(edge)
        } else {
            clearSelection()
        }
        focusCanvas()
    }

    /// Double-click on empty canvas: edits the connection under the pointer, or adds a node.
    func handleBackgroundDoubleClick(at point: CGPoint) {
        if isOverview, let id = node(atView: point) {
            select(id)
            centre(on: id)
        } else if let edge = edge(atView: point) {
            selectEdge(edge)
            showRelationPicker(for: [edge])
        } else {
            addNode(atView: point)
        }
    }

    /// Selects and scrolls to a node (used by search, tags and backlinks).
    func reveal(_ id: UUID) {
        guard placement(id) != nil else { return }
        let hiddenUnder = tree.ancestors(of: id).filter { tree.collapsed.contains($0) }
        if !hiddenUnder.isEmpty { workspace.setCollapsed(false, nodeIDs: hiddenUnder, in: mapID) }
        select(id)
        centre(on: id)
    }

    /// The selected nodes that are not inside another selected node's branch, in map order.
    var selectedBranchRoots: [UUID] {
        visibleIDs.filter { selection.contains($0) && !tree.ancestors(of: $0).contains(where: selection.contains) }
    }

    // MARK: - Keyboard focus

    func focusCanvas() {
        guard let keyView, let window = keyView.window else { return }
        if window.firstResponder !== keyView { window.makeFirstResponder(keyView) }
    }

    // MARK: - Creating nodes

    func addChild() {
        commitEditingIfNeeded()
        guard let parentID = primarySelection ?? tree.roots.first else {
            addNode(atView: viewCenter)
            return
        }
        let id = UUID()
        let position = childPosition(for: parentID)
        let collapsed = tree.collapsed.contains(parentID)
        workspace.perform("Add Child", coalesce: newNodeKey(id)) { _ in
            if collapsed { workspace.setCollapsed(false, nodeIDs: [parentID], in: mapID) }
            workspace.addNode(NodeData(createdAt: workspace.clock()), id: id, to: mapID, at: position,
                              parent: parentID, actionName: "Add Child")
        }
        beginEditing(id, isNew: true, origin: parentID)
    }

    func addSibling() {
        commitEditingIfNeeded()
        guard let current = primarySelection, let placement = placement(current) else {
            addChild()
            return
        }
        guard let parentID = placement.parentID else {
            addChild()
            return
        }
        let id = UUID()
        let kind = siblingKind(of: current)
        let position = siblingPosition(after: current, parent: parentID)
        workspace.addNode(NodeData(kind: kind, createdAt: workspace.clock()), id: id, to: mapID, at: position,
                          parent: parentID, after: current, actionName: "Add Sibling", coalesce: newNodeKey(id))
        beginEditing(id, isNew: true, origin: current)
    }

    /// Creates a free-standing node (double-click on empty canvas).
    func addNode(atView point: CGPoint) {
        commitEditingIfNeeded()
        let id = UUID()
        workspace.addNode(NodeData(createdAt: workspace.clock()), id: id, to: mapID, at: worldPoint(point),
                          actionName: "Add Node", coalesce: newNodeKey(id))
        beginEditing(id, isNew: true, origin: primarySelection)
    }

    private func newNodeKey(_ id: UUID) -> String { "add-\(id.uuidString)" }

    /// New siblings keep the kind of the node they follow, except for kinds that carry
    /// data of their own (sources, quotes).
    private func siblingKind(of id: UUID) -> NodeKind {
        guard let kind = workspace.nodes[id]?.kind else { return .idea }
        return kind == .source || kind == .quote ? .idea : kind
    }

    /// Where a new child is stored: in the column of its siblings on the parent's outward
    /// side (for a root, the side with fewer children), below the lowest of them. Automatic
    /// layouts then move it into place; for a mind map, the side chosen here is kept.
    func childPosition(for parentID: UUID) -> CGPoint {
        guard let parentRect = targetRect(parentID) else { return worldPoint(viewCenter) }
        let newSize = NodeMetrics.minimumSize
        let childRects = tree.children(of: parentID).compactMap(targetRect)
        let direction: CGFloat = {
            if let grand = tree.parent[parentID], let grandRect = targetRect(grand) {
                return parentRect.midX >= grandRect.midX ? 1 : -1
            }
            let right = childRects.filter { $0.midX >= parentRect.midX }.count
            return right <= childRects.count - right ? 1 : -1
        }()
        let sameSide = childRects.filter { ($0.midX - parentRect.midX) * direction > 0 }
        if let lowest = sameSide.max(by: { $0.maxY < $1.maxY }) {
            return CGPoint(x: lowest.midX, y: lowest.maxY + 14 + newSize.height / 2)
        }
        // The title is still empty, so leave room for it to grow towards the parent.
        return CGPoint(x: parentRect.midX + direction * (parentRect.width / 2 + 70 + 80), y: parentRect.midY)
    }

    func siblingPosition(after id: UUID, parent: UUID) -> CGPoint {
        guard let rect = targetRect(id) else { return childPosition(for: parent) }
        let siblings = tree.children(of: parent).compactMap(targetRect)
            .filter { abs($0.midX - rect.midX) < max($0.width, rect.width) }
        let lowest = siblings.max(by: { $0.maxY < $1.maxY }) ?? rect
        return CGPoint(x: rect.midX, y: lowest.maxY + 14 + NodeMetrics.minimumSize.height / 2)
    }

    // MARK: - Inline title editing

    func beginEditing(_ id: UUID? = nil, isNew: Bool = false, origin: UUID? = nil, replacingWith text: String? = nil) {
        guard let id = id ?? primarySelection, let node = workspace.nodes[id], visibleSet.contains(id) else { return }
        if editingNodeID != nil, editingNodeID != id { commitEditing() }
        select(id)
        editingNodeID = id
        editingIsNew = isNew
        editingOrigin = origin
        if let text { updateEditingTitle(text, node: node) }
        ensureVisible(id)
    }

    func updateEditingTitle(_ text: String) {
        guard let id = editingNodeID, let node = workspace.nodes[id] else { return }
        updateEditingTitle(text, node: node)
    }

    private func updateEditingTitle(_ text: String, node: Node) {
        let key = editingIsNew ? newNodeKey(node.id) : "title-\(node.id.uuidString)"
        // An unlimited window keeps every keystroke of this edit in one undo step.
        workspace.updateNode(node, "Rename", coalesce: key, coalesceWindow: .infinity) { $0.title = text }
    }

    /// Finishes editing. A new node left empty is removed again without an undo step.
    func commitEditing() {
        guard let id = editingNodeID else { return }
        let wasNew = editingIsNew
        editingNodeID = nil
        editingIsNew = false
        let title = workspace.nodes[id]?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if wasNew, title.isEmpty, workspace.discardLastStep(ifCoalesceKey: newNodeKey(id)) {
            if let origin = editingOrigin, visibleSet.contains(origin) { select(origin) }
        } else {
            workspace.history.breakCoalescing()
        }
        editingOrigin = nil
        focusCanvasSoon()
    }

    /// Esc while editing: restores the old title, or removes the node if it was just created.
    func cancelEditing() {
        guard let id = editingNodeID else { return }
        let wasNew = editingIsNew
        editingNodeID = nil
        editingIsNew = false
        if wasNew {
            if workspace.discardLastStep(ifCoalesceKey: newNodeKey(id)),
               let origin = editingOrigin, visibleSet.contains(origin) {
                select(origin)
            }
        } else {
            workspace.discardLastStep(ifCoalesceKey: "title-\(id.uuidString)")
        }
        editingOrigin = nil
        focusCanvasSoon()
    }

    func commitEditingIfNeeded() {
        if editingNodeID != nil { commitEditing() }
        if editingFrameID != nil { endFrameEditing() }
    }

    func focusCanvasSoon() {
        DispatchQueue.main.async { [weak self] in self?.focusCanvas() }
    }

    // MARK: - Editing commands

    /// Deletes the selected connection or frame, or removes the selected nodes (with their
    /// branches) from this map.
    func deleteSelection(actionName: String? = nil) {
        commitEditingIfNeeded()
        if let edge = selectedEdgeID {
            workspace.deleteEdges([edge])
            selectedEdgeID = nil
            return
        }
        if let frame = selectedFrameID {
            workspace.deleteFrames([frame])
            selectedFrameID = nil
            return
        }
        guard !selection.isEmpty else { return }
        let primary = primarySelection
        // Select the previous sibling, else the next one, else the nearest surviving ancestor.
        let next: UUID? = primary.flatMap { id in
            let siblings = tree.siblings(of: id)
            if let index = siblings.firstIndex(of: id) {
                if let before = siblings[..<index].last(where: { !selection.contains($0) }) { return before }
                if let after = siblings[(index + 1)...].first(where: { !selection.contains($0) }) { return after }
            }
            return tree.ancestors(of: id).first { !selection.contains($0) }
        }
        workspace.removeFromMap(selection, mapID: mapID,
                                actionName: actionName ?? (selection.count == 1 ? "Delete Node" : "Delete Nodes"))
        if let next, visibleSet.contains(next) { select(next) } else { clearSelection() }
    }

    func toggleCollapse() {
        let targets = selection.filter { !tree.children(of: $0).isEmpty }
        guard !targets.isEmpty else { return }
        let collapse = !targets.allSatisfy { tree.collapsed.contains($0) }
        workspace.setCollapsed(collapse, nodeIDs: targets, in: mapID)
    }

    func setKind(_ kind: NodeKind) {
        guard !selection.isEmpty else { return }
        workspace.updateNodes(selection, "Change Type") { $0.setKind(kind) }
    }

    func setColor(_ color: NodeColor?) {
        guard !selection.isEmpty else { return }
        workspace.updateNodes(selection, "Change Colour") { $0.color = color }
    }

    func navigate(_ direction: SpatialNavigation.Direction, extending: Bool) {
        commitEditingIfNeeded()
        guard let current = primarySelection, let origin = targets[current] else {
            if let first = tree.roots.first(where: visibleSet.contains) ?? visibleIDs.first {
                select(first)
                ensureVisible(first)
            }
            return
        }
        let candidates = visibleIDs.compactMap { id -> (id: UUID, center: CGPoint)? in
            guard id != current, let center = targets[id] else { return nil }
            return (id, center)
        }
        guard let target = SpatialNavigation.nearest(from: origin, direction: direction, candidates: candidates) else { return }
        if extending {
            selection.insert(target)
            primarySelection = target
        } else {
            select(target)
        }
        ensureVisible(target)
    }
}
