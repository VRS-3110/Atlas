import CoreGraphics
import Foundation
import Testing
@testable import AtlasCore

@MainActor
@Suite("Layouts, branch moves and frames")
struct ArrangeOperationsTests {
    @Test func switchingLayoutStoresPositionsInOneStep() {
        let f = Fixture()
        let before = f.workspace.placement(of: f.a, in: f.map.id)?.position
        f.workspace.setLayoutStyle(.free, of: f.map, positions: [f.a: CGPoint(x: 400, y: 10)])
        #expect(f.map.layoutStyle == .free)
        #expect(f.workspace.placement(of: f.a, in: f.map.id)?.position == CGPoint(x: 400, y: 10))
        #expect(f.workspace.history.undoActionName == "Free Placement")
        f.workspace.undo()
        #expect(f.map.layoutStyle == .mindMap)
        #expect(f.workspace.placement(of: f.a, in: f.map.id)?.position == before)
    }

    @Test func positionsCanPinNodes() {
        let f = Fixture()
        f.workspace.setPositions([f.a: CGPoint(x: 1, y: 2), f.b: CGPoint(x: 3, y: 4)], in: f.map.id, pinning: [f.a])
        #expect(f.tree.pinned == [f.a])
        #expect(f.workspace.placement(of: f.b, in: f.map.id)?.position == CGPoint(x: 3, y: 4))
        f.workspace.unpinAll(in: f.map.id)
        #expect(f.tree.pinned.isEmpty)
        #expect(f.workspace.history.undoActionName == "Unpin All")
    }

    @Test func movingBranchesPlacesThemAmongNewSiblings() {
        let f = Fixture()
        let c = f.workspace.addChild(to: f.root, in: f.map.id, data: NodeData(title: "C")).id
        #expect(f.tree.children(of: f.root) == [f.a, f.b, c])

        #expect(f.workspace.moveBranches([c], to: f.root, at: .before(f.a), in: f.map.id))
        #expect(f.tree.children(of: f.root) == [c, f.a, f.b])
        #expect(f.workspace.moveBranches([c], to: f.root, at: .after(f.a), in: f.map.id))
        #expect(f.tree.children(of: f.root) == [f.a, c, f.b])

        // Two branches move together, in the order given, and take their branches along.
        #expect(f.workspace.moveBranches([f.b, f.a], to: c, at: .first, in: f.map.id, actionName: "Move Branches"))
        #expect(f.tree.children(of: c) == [f.b, f.a])
        #expect(f.tree.children(of: f.a) == [f.a1])
        #expect(f.workspace.history.undoActionName == "Move Branches")
        f.workspace.undo()
        #expect(f.tree.children(of: f.root) == [f.a, c, f.b])
    }

    @Test func movingABranchIntoItselfIsRefused() {
        let f = Fixture()
        let depth = f.workspace.history.undoStack.count
        #expect(!f.workspace.moveBranches([f.a], to: f.a1, in: f.map.id))
        #expect(!f.workspace.moveBranches([f.a], to: f.a, in: f.map.id))
        #expect(f.tree.parent[f.a] == f.root)
        #expect(f.workspace.history.undoStack.count == depth)
    }

    @Test func movingCanStorePositionsAndClearPins() {
        let f = Fixture()
        f.workspace.setPinned(true, nodeIDs: [f.b], in: f.map.id)
        f.workspace.moveBranches([f.b], to: f.a, in: f.map.id, positions: [f.b: CGPoint(x: 9, y: 9)], pinned: false)
        let placement = f.workspace.placement(of: f.b, in: f.map.id)
        #expect(placement?.parentID == f.a)
        #expect(placement?.isPinned == false)
        #expect(placement?.position == CGPoint(x: 9, y: 9))
    }

    @Test func indentAndOutdent() {
        let f = Fixture()
        // B goes under A, its sibling above, after A's own child.
        f.workspace.setCollapsed(true, nodeIDs: [f.a], in: f.map.id)
        #expect(f.workspace.indent(f.b, in: f.map.id))
        #expect(f.tree.children(of: f.a) == [f.a1, f.b])
        #expect(!f.tree.collapsed.contains(f.a), "indenting under a collapsed node opens it")
        #expect(f.workspace.history.undoActionName == "Indent")

        // A1 comes back out to sit right after A.
        #expect(f.workspace.outdent(f.a1, in: f.map.id))
        #expect(f.tree.children(of: f.root) == [f.a, f.a1])
        #expect(f.workspace.history.undoActionName == "Outdent")

        // The first child has nothing to indent under; a root's children cannot outdent.
        #expect(!f.workspace.indent(f.a, in: f.map.id))
        #expect(!f.workspace.outdent(f.a, in: f.map.id))
        #expect(!f.workspace.outdent(f.root, in: f.map.id))
    }

    @Test func framesGroupNodesAndUngroupWithoutLosingThem() throws {
        let f = Fixture()
        let frame = try #require(f.workspace.createFrame(on: f.map.id, around: [f.a, f.b], title: "Pair"))
        #expect(f.workspace.frames(in: f.map.id).map(\.id) == [frame.id])
        #expect(frame.nodeIDs == [f.a, f.b])
        #expect(f.workspace.history.undoActionName == "Group")

        f.workspace.updateFrame(frame, "Rename Group") { $0.title = "Renamed" }
        #expect(frame.title == "Renamed")

        f.workspace.deleteFrames([frame.id])
        #expect(f.workspace.frames(in: f.map.id).isEmpty)
        #expect(f.workspace.nodes[f.a] != nil && f.workspace.nodes[f.b] != nil)
        f.workspace.undo()
        #expect(f.workspace.frames(in: f.map.id).first === frame, "undo brings back the same frame")

        // Removing a member from the map shrinks the frame; removing all of them deletes it.
        f.workspace.removeFromMap([f.a], mapID: f.map.id)
        #expect(frame.nodeIDs == [f.b])
        f.workspace.removeFromMap([f.b], mapID: f.map.id)
        #expect(f.workspace.frames(in: f.map.id).isEmpty)
        #expect(f.workspace.createFrame(on: f.map.id, around: [UUID()]) == nil)
    }

    @Test func connectingAndPickingARelationIsOneStep() throws {
        let f = Fixture()
        let edge = try #require(f.workspace.connect(f.a, to: f.b, coalesce: "connect-1"))
        f.clock.advance(30)
        f.workspace.setRelation(.supports, of: [edge.id], coalesce: "connect-1")
        #expect(edge.relation == .supports)
        #expect(edge.hasArrow && edge.lineStyle == .solid)
        #expect(f.workspace.history.undoStack.count == 1)
        #expect(f.workspace.history.undoActionName == "Connect")
        f.workspace.undo()
        #expect(f.workspace.edges[edge.id] == nil)

        f.workspace.redo()
        f.workspace.setRelation(.custom, label: "cites", of: [edge.id])
        #expect(edge.displayLabel == "cites")
        f.workspace.reverseEdge(edge)
        #expect(edge.fromID == f.b && edge.toID == f.a)
        #expect(f.workspace.history.undoActionName == "Reverse Connection")
    }
}
