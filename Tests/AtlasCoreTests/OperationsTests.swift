import Foundation
import Testing
@testable import AtlasCore

@MainActor
@Suite("Editing operations")
struct OperationsTests {
    @Test func newMapsGetARootAndGoLast() throws {
        let f = Fixture()
        let second = f.workspace.createMap(named: "Second")
        #expect(f.workspace.sortedMaps.map(\.name) == ["Test", "Second"])
        let tree = f.workspace.tree(of: second.id)
        let root = try #require(tree.roots.first)
        #expect(tree.roots.count == 1)
        #expect(f.title(root) == "Central Topic")
        #expect(f.workspace.placement(of: root, in: second.id)?.position == .zero)

        f.workspace.undo()
        #expect(f.workspace.maps[second.id] == nil)
        #expect(f.workspace.nodes[root] == nil)
    }

    @Test func childrenAndSiblingsKeepTheirOrder() throws {
        let f = Fixture()
        #expect(f.tree.children(of: f.root) == [f.a, f.b])

        let between = f.workspace.addSibling(of: f.a, in: f.map.id, data: NodeData(title: "Between"))
        #expect(f.tree.children(of: f.root) == [f.a, between.id, f.b])
        #expect(f.workspace.history.undoActionName == "Add Sibling")

        let last = f.workspace.addSibling(of: f.b, in: f.map.id)
        #expect(f.tree.children(of: f.root) == [f.a, between.id, f.b, last.id])
    }

    @Test func aSiblingOfTheRootIsAChild() {
        let f = Fixture()
        let added = f.workspace.addSibling(of: f.root, in: f.map.id)
        #expect(f.tree.parent[added.id] == f.root)
        #expect(f.tree.roots == [f.root])
    }

    @Test func removingFromAMapTakesTheBranchAndDeletesOrphans() throws {
        let f = Fixture()
        let other = f.workspace.createMap(named: "Other", rootTitle: nil)
        f.workspace.placeNode(f.a1, on: other.id, at: .zero)
        let edge = try #require(f.workspace.connect(f.a, to: f.b))

        f.workspace.removeFromMap([f.a], mapID: f.map.id)
        #expect(f.workspace.placement(of: f.a, in: f.map.id) == nil)
        #expect(f.workspace.placement(of: f.a1, in: f.map.id) == nil)
        // A was on no other map, so it is gone, with its edge. A1 lives on elsewhere.
        #expect(f.workspace.nodes[f.a] == nil)
        #expect(f.workspace.edges[edge.id] == nil)
        #expect(f.workspace.nodes[f.a1] != nil)
        #expect(f.workspace.maps(containing: f.a1).map(\.id) == [other.id])
        #expect(f.workspace.history.undoActionName == "Delete")
        f.workspace.undo()
        #expect(f.tree.children(of: f.a) == [f.a1])
        #expect(f.workspace.edges[edge.id] != nil)
    }

    @Test func sourcesTasksAndInboxItemsSurviveRemoval() throws {
        let f = Fixture()
        let source = f.workspace.addChild(to: f.b, in: f.map.id, data: NodeData(title: "Book", kind: .source))
        let task = f.workspace.addChild(to: f.b, in: f.map.id, data: NodeData(title: "Read", kind: .task))
        let captured = f.workspace.addChild(to: f.b, in: f.map.id, data: NodeData(title: "Later", inbox: .inbox))
        let plain = f.workspace.addChild(to: f.b, in: f.map.id, data: NodeData(title: "Plain"))

        f.workspace.removeFromMap([f.b], mapID: f.map.id)
        #expect(f.workspace.nodes[source.id] != nil)
        #expect(f.workspace.nodes[task.id] != nil)
        #expect(f.workspace.nodes[captured.id] != nil)
        #expect(f.workspace.nodes[plain.id] == nil)
        #expect(f.workspace.nodes[f.b] == nil)
    }

    @Test func deletingNodesPromotesTheirChildren() throws {
        let f = Fixture()
        let a2 = f.workspace.addChild(to: f.a, in: f.map.id, data: NodeData(title: "A2"))
        let edge = try #require(f.workspace.connect(f.a, to: f.b))

        f.workspace.deleteNodes([f.a])
        #expect(f.workspace.nodes[f.a] == nil)
        #expect(f.workspace.edges[edge.id] == nil)
        #expect(f.tree.parent[f.a1] == f.root)
        #expect(f.tree.parent[a2.id] == f.root)

        f.workspace.undo()
        #expect(f.tree.children(of: f.a) == [f.a1, a2.id])
        #expect(f.workspace.edges[edge.id] != nil)
    }

    @Test func deletingASourceRemovesCitationsOfIt() throws {
        let f = Fixture()
        let source = f.loose("Book", kind: .source)
        let quote = f.workspace.createNode(NodeData(title: "Quote", kind: .quote,
                                                    citations: [Citation(sourceID: source.id, page: "12")]))
        f.workspace.deleteNodes([source.id])
        #expect(quote.citations.isEmpty)
        f.workspace.undo()
        #expect(quote.citations == [Citation(sourceID: source.id, page: "12")])
    }

    @Test func deletingAMapKeepsNodesUsedElsewhere() throws {
        let f = Fixture()
        let other = f.workspace.createMap(named: "Other", rootTitle: nil)
        f.workspace.placeNode(f.b, on: other.id, at: .zero)
        let frame = f.workspace.perform("Frame") { tx in
            tx.insert(FrameData(mapID: f.map.id, title: "Group", nodeIDs: [f.a, f.b]))
        }

        f.workspace.deleteMap(f.map)
        #expect(f.workspace.maps[f.map.id] == nil)
        #expect(f.workspace.frames[frame.id] == nil)
        #expect(f.workspace.placements(in: f.map.id).isEmpty)
        #expect(f.workspace.nodes[f.root] == nil)
        #expect(f.workspace.nodes[f.a] == nil)
        #expect(f.workspace.nodes[f.b] != nil)

        f.workspace.undo()
        #expect(f.workspace.maps[f.map.id] != nil)
        #expect(f.tree.children(of: f.root) == [f.a, f.b])
        #expect(f.workspace.frames[frame.id] != nil)
    }

    @Test func reparentingRefusesCycles() throws {
        let f = Fixture()
        #expect(!f.workspace.reparent(f.a, to: f.a1, in: f.map.id))
        #expect(!f.workspace.reparent(f.a, to: f.a, in: f.map.id))
        #expect(f.tree.parent[f.a] == f.root)

        #expect(f.workspace.reparent(f.a1, to: f.root, after: f.a, in: f.map.id))
        #expect(f.tree.children(of: f.root) == [f.a, f.a1, f.b])
        #expect(f.workspace.reparent(f.b, to: nil, in: f.map.id))
        #expect(f.tree.roots.contains(f.b))
    }

    @Test func connectionsNeedTwoDifferentNodes() throws {
        let f = Fixture()
        #expect(f.workspace.connect(f.a, to: f.a) == nil)
        let edge = try #require(f.workspace.connect(f.a1, to: f.b, relation: .contradicts))
        #expect(edge.lineStyle == .dashed)
        #expect(edge.hasArrow)
        #expect(edge.data.displayLabel == "contradicts")
        #expect(f.workspace.edge(between: f.b, and: f.a1)?.id == edge.id)

        f.workspace.deleteEdges([edge.id])
        #expect(f.workspace.edges.isEmpty)
    }

    @Test func mapsCanBeReorderedAndRenamed() {
        let f = Fixture()
        let second = f.workspace.createMap(named: "Second")
        let third = f.workspace.createMap(named: "Third")
        f.workspace.moveMap(third, toIndex: 0)
        #expect(f.workspace.sortedMaps.map(\.id) == [third.id, f.map.id, second.id])

        f.workspace.renameMap(second, to: "   ")
        #expect(second.name == "Second")
        f.workspace.renameMap(second, to: "  Renamed  ")
        #expect(second.name == "Renamed")
    }

    @Test func collapsingHidesTheBranch() {
        let f = Fixture()
        f.workspace.setCollapsed(true, nodeIDs: [f.a], in: f.map.id)
        #expect(f.tree.visibleIDs == [f.root, f.a, f.b])
        #expect(f.tree.hiddenCount(under: f.a) == 1)
        f.workspace.undo()
        #expect(f.tree.visibleIDs == [f.root, f.a, f.a1, f.b])
    }

    @Test func placingAnInboxItemFilesIt() throws {
        let f = Fixture()
        let captured = f.workspace.createNode(NodeData(title: "Idea", inbox: .inbox))
        f.workspace.placeNode(captured.id, on: f.map.id, at: CGPoint(x: 40, y: 50), parent: f.b)
        #expect(captured.inbox == .none)
        #expect(f.tree.parent[captured.id] == f.b)

        // Placing it again moves it rather than adding a second copy.
        f.workspace.placeNode(captured.id, on: f.map.id, at: CGPoint(x: 90, y: 10))
        #expect(f.workspace.placement(of: captured.id, in: f.map.id)?.position == CGPoint(x: 90, y: 10))
        #expect(f.workspace.placementIDsByNode[captured.id]?.count == 1)
    }

    @Test func movingNodesIsOneStep() throws {
        let f = Fixture()
        let before = try #require(f.workspace.placement(of: f.a, in: f.map.id)?.position)
        f.workspace.moveNodes([f.a, f.a1], by: CGSize(width: 10, height: -5), in: f.map.id)
        #expect(f.workspace.placement(of: f.a, in: f.map.id)?.position == CGPoint(x: before.x + 10, y: before.y - 5))
        #expect(f.workspace.history.undoStack.count == 1)
    }

    @Test func updatingSeveralNodesIsOneStep() {
        let f = Fixture()
        f.workspace.updateNodes([f.a, f.b], "Tag") { $0.addTags(["draft"]) }
        #expect(f.node(f.a)?.tags == ["draft"])
        #expect(f.node(f.b)?.tags == ["draft"])
        #expect(f.workspace.history.undoStack.count == 1)
    }
}
