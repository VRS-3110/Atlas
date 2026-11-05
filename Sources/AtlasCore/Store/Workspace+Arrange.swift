import CoreGraphics
import Foundation
import AtlasLayout

/// Where moved or pasted branches go among their new siblings.
public enum SiblingPosition: Equatable, Sendable {
    case first
    case last
    case before(UUID)
    case after(UUID)
}

/// Layout styles, pinning, branch moves and frames. Each public method is one undo step.
extension Workspace {

    // MARK: Layout

    /// Switches a map's layout style. `positions` are stored in the same step; the app passes
    /// the laid-out positions when switching to free placement, so nothing jumps.
    public func setLayoutStyle(_ style: LayoutStyle, of map: MindMap, positions: [UUID: CGPoint] = [:]) {
        perform(style == .free ? "Free Placement" : "\(style.title) Layout") { tx in
            tx.update(map) { $0.layoutStyle = style }
            for (nodeID, point) in positions {
                if let p = placement(of: nodeID, in: map.id) { tx.update(p) { $0.position = point } }
            }
        }
    }

    public func unpinAll(in mapID: UUID) {
        perform("Unpin All") { tx in
            for p in placements(in: mapID).values where p.isPinned {
                tx.update(p) { $0.isPinned = false }
            }
        }
    }

    // MARK: Moving branches

    /// Moves branches under a new parent (nil makes them roots), keeping their order, at
    /// `position` among the new siblings. `positions` are stored in the same step and
    /// `pinned`, when given, sets or clears the moved nodes' pins.
    ///
    /// Refuses, returning false, when a branch would end up inside itself.
    @discardableResult
    public func moveBranches(_ nodeIDs: [UUID], to parentID: UUID?, at position: SiblingPosition = .last,
                             in mapID: UUID, positions: [UUID: CGPoint] = [:], pinned: Bool? = nil,
                             actionName: String = "Move Branch") -> Bool {
        let moving = nodeIDs.filter { placement(of: $0, in: mapID) != nil }
        guard !moving.isEmpty else { return false }
        let tree = tree(of: mapID)
        if let parentID {
            guard placement(of: parentID, in: mapID) != nil else { return false }
            for id in moving where id == parentID || tree.isDescendant(parentID, of: id) { return false }
        }

        let movingSet = Set(moving)
        let siblings = (parentID.map { tree.children(of: $0) } ?? tree.roots).filter { !movingSet.contains($0) }
        let index: Int = switch position {
        case .first: 0
        case .last: siblings.count
        case .before(let id): siblings.firstIndex(of: id) ?? siblings.count
        case .after(let id): siblings.firstIndex(of: id).map { $0 + 1 } ?? siblings.count
        }
        let ordered = Array(siblings[..<index]) + moving + Array(siblings[index...])

        perform(actionName) { tx in
            for (i, id) in ordered.enumerated() {
                guard let p = placement(of: id, in: mapID) else { continue }
                let isMoving = movingSet.contains(id)
                tx.update(p) {
                    $0.order = Double(i)
                    if isMoving {
                        $0.parentID = parentID
                        if let pinned { $0.isPinned = pinned }
                    }
                }
            }
            for (id, point) in positions {
                if let p = placement(of: id, in: mapID) { tx.update(p) { $0.position = point } }
            }
        }
        return true
    }

    /// Makes a node the last child of the sibling above it, expanding that sibling if needed.
    @discardableResult
    public func indent(_ nodeID: UUID, in mapID: UUID) -> Bool {
        let tree = tree(of: mapID)
        let siblings = tree.siblings(of: nodeID)
        guard let index = siblings.firstIndex(of: nodeID), index > 0, tree.parent[nodeID] != nil else { return false }
        let newParent = siblings[index - 1]
        return perform("Indent") { tx in
            guard moveBranches([nodeID], to: newParent, at: .last, in: mapID, actionName: "Indent") else { return false }
            if let p = placement(of: newParent, in: mapID), p.isCollapsed { tx.update(p) { $0.isCollapsed = false } }
            return true
        }
    }

    /// Makes a node the sibling after its parent. Branches of a root stay where they are,
    /// since outdenting them would detach them from the map's tree.
    @discardableResult
    public func outdent(_ nodeID: UUID, in mapID: UUID) -> Bool {
        let tree = tree(of: mapID)
        guard let parent = tree.parent[nodeID], let grandparent = tree.parent[parent] else { return false }
        return moveBranches([nodeID], to: grandparent, at: .after(parent), in: mapID, actionName: "Outdent")
    }

    // MARK: Frames

    /// Frames on a map, oldest first (so newer frames draw on top).
    public func frames(in mapID: UUID) -> [MapFrame] {
        (frameIDsByMap[mapID] ?? []).compactMap { frames[$0] }.sorted {
            $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Draws a labelled frame around nodes (and, on the canvas, their branches).
    @discardableResult
    public func createFrame(on mapID: UUID, around nodeIDs: [UUID], title: String = "Group",
                            color: NodeColor = .blue) -> MapFrame? {
        let members = nodeIDs.filter { placement(of: $0, in: mapID) != nil }
        guard !members.isEmpty else { return nil }
        return perform("Group") { tx in
            tx.insert(FrameData(mapID: mapID, title: title, color: color, nodeIDs: members, createdAt: clock()))
        }
    }

    public func updateFrame(_ frame: MapFrame, _ actionName: String, coalesce: String? = nil,
                            _ mutate: (inout FrameData) -> Void) {
        perform(actionName, coalesce: coalesce) { tx in tx.update(frame, mutate) }
    }

    /// Removes frames; their nodes stay where they are.
    public func deleteFrames(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        perform("Ungroup") { tx in
            for id in ids { if let frame = frames[id] { tx.delete(frame) } }
        }
    }
}
