import Foundation
import Testing
@testable import AtlasCore

@MainActor
@Suite("Transactions and undo")
struct UndoTests {
    @Test func undoAndRedoRestoreAnEdit() throws {
        let f = Fixture()
        let node = try #require(f.node(f.a))
        f.workspace.updateNode(node, "Rename") { $0.title = "Alpha" }
        #expect(f.workspace.history.undoActionName == "Rename")

        f.workspace.undo()
        #expect(f.title(f.a) == "A")
        #expect(f.workspace.history.redoActionName == "Rename")
        // The same object is updated in place, so views holding it see the change.
        #expect(f.node(f.a) === node)

        f.workspace.redo()
        #expect(f.title(f.a) == "Alpha")
        #expect(!f.workspace.history.canRedo)
        #expect(f.workspace.history.undoActionName == "Rename")
    }

    @Test func aNewEditClearsRedo() throws {
        let f = Fixture()
        let node = try #require(f.node(f.a))
        f.workspace.updateNode(node, "Rename") { $0.title = "Alpha" }
        f.workspace.undo()
        #expect(f.workspace.history.canRedo)
        f.workspace.updateNode(node, "Rename") { $0.title = "Beta" }
        #expect(!f.workspace.history.canRedo)
    }

    @Test func editsThatChangeNothingRecordNothing() throws {
        let f = Fixture()
        let node = try #require(f.node(f.a))
        let revision = f.workspace.revision
        f.workspace.updateNode(node, "Rename") { $0.title = "A" }
        #expect(!f.workspace.history.canUndo)
        #expect(f.workspace.revision == revision)
    }

    @Test func editsWithTheSameKeyCoalesceWithinTheWindow() throws {
        let f = Fixture()
        let node = try #require(f.node(f.a))
        for title in ["T", "Ty", "Typ"] {
            f.workspace.updateNode(node, "Typing", coalesce: "title") { $0.title = title }
            f.clock.advance(1)
        }
        #expect(f.workspace.history.undoStack.count == 1)

        // A pause longer than the window starts a new step.
        f.clock.advance(10)
        f.workspace.updateNode(node, "Typing", coalesce: "title") { $0.title = "Typed" }
        #expect(f.workspace.history.undoStack.count == 2)

        f.workspace.undo()
        #expect(f.title(f.a) == "Typ")
        f.workspace.undo()
        #expect(f.title(f.a) == "A")
    }

    @Test func anEndlessWindowMergesUntilCoalescingIsBroken() throws {
        let f = Fixture()
        let node = try #require(f.node(f.a))
        f.workspace.updateNode(node, "Typing", coalesce: "title", coalesceWindow: .infinity) { $0.title = "X" }
        f.clock.advance(3600)
        f.workspace.updateNode(node, "Typing", coalesce: "title", coalesceWindow: .infinity) { $0.title = "XY" }
        #expect(f.workspace.history.undoStack.count == 1)

        f.workspace.history.breakCoalescing()
        f.workspace.updateNode(node, "Typing", coalesce: "title", coalesceWindow: .infinity) { $0.title = "XYZ" }
        #expect(f.workspace.history.undoStack.count == 2)
    }

    @Test func editsThatCancelOutLeaveNoStep() throws {
        let f = Fixture()
        let node = try #require(f.node(f.a))
        f.workspace.updateNode(node, "Typing", coalesce: "title") { $0.title = "AB" }
        f.workspace.updateNode(node, "Typing", coalesce: "title") { $0.title = "A" }
        #expect(!f.workspace.history.canUndo)
    }

    @Test func nestedPerformJoinsTheOuterStep() {
        let f = Fixture()
        f.workspace.perform("Outer") { _ in
            f.workspace.renameMap(f.map, to: "Renamed")
            f.workspace.addChild(to: f.b, in: f.map.id, data: NodeData(title: "B1"))
        }
        #expect(f.workspace.history.undoStack.count == 1)
        #expect(f.workspace.history.undoActionName == "Outer")

        f.workspace.undo()
        #expect(f.map.name == "Test")
        #expect(f.tree.children(of: f.b).isEmpty)
    }

    @Test func aThrowingPerformRollsBackEverything() {
        struct Failure: Error {}
        let f = Fixture()
        let nodeCount = f.workspace.nodes.count
        #expect(throws: Failure.self) {
            try f.workspace.perform("Broken") { tx in
                tx.update(f.map) { $0.name = "Half done" }
                f.workspace.addChild(to: f.b, in: f.map.id)
                throw Failure()
            }
        }
        #expect(f.map.name == "Test")
        #expect(f.workspace.nodes.count == nodeCount)
        #expect(f.tree.children(of: f.b).isEmpty)
        #expect(!f.workspace.history.canUndo)
        #expect(!f.workspace.isInTransaction)
    }

    @Test func gestureTransactionsBecomeOneStep() throws {
        let f = Fixture()
        let placement = try #require(f.workspace.placement(of: f.b, in: f.map.id))
        let start = placement.position
        let tx = f.workspace.beginTransaction("Move")
        for step in 1...5 {
            tx.update(placement) { $0.x = start.x + CGFloat(step * 10) }
            // Every intermediate position is visible straight away.
            #expect(placement.position.x == start.x + CGFloat(step * 10))
        }
        #expect(!f.workspace.history.canUndo)
        f.workspace.commitTransaction(tx)
        #expect(f.workspace.history.undoStack.count == 1)

        f.workspace.undo()
        #expect(placement.position == start)
    }

    @Test func cancellingATransactionRestoresTheStart() throws {
        let f = Fixture()
        let placement = try #require(f.workspace.placement(of: f.b, in: f.map.id))
        let start = placement.position
        let tx = f.workspace.beginTransaction("Move")
        tx.update(placement) { $0.y += 300 }
        f.workspace.cancelTransaction(tx)
        #expect(placement.position == start)
        #expect(!f.workspace.history.canUndo)
        #expect(!f.workspace.isInTransaction)
    }

    @Test func undoWaitsForAnOpenTransaction() throws {
        let f = Fixture()
        let node = try #require(f.node(f.a))
        f.workspace.updateNode(node, "Rename") { $0.title = "Alpha" }
        let tx = f.workspace.beginTransaction("Drag")
        #expect(f.workspace.undo() == nil)
        f.workspace.cancelTransaction(tx)
        #expect(f.workspace.undo() != nil)
    }

    @Test func discardingTheLastStepLeavesNothingToRedo() throws {
        let f = Fixture()
        let node = f.workspace.addNode(NodeData(), to: f.map.id, at: .zero, parent: f.b,
                                       actionName: "Add Child", coalesce: "add-1")
        #expect(!f.workspace.discardLastStep(ifCoalesceKey: "something-else"))
        #expect(f.workspace.nodes[node.id] != nil)

        #expect(f.workspace.discardLastStep(ifCoalesceKey: "add-1"))
        #expect(f.workspace.nodes[node.id] == nil)
        #expect(f.workspace.placement(of: node.id, in: f.map.id) == nil)
        #expect(!f.workspace.history.canUndo)
        #expect(!f.workspace.history.canRedo)
    }

    @Test func undoReturnsTheChangesAsApplied() throws {
        let f = Fixture()
        let added = f.workspace.addChild(to: f.b, in: f.map.id)
        let undone = try #require(f.workspace.undo())
        let nodeChange = try #require(undone.changes.first { $0.key == added.key })
        #expect(nodeChange.isDelete)

        let redone = try #require(f.workspace.redo())
        #expect(redone.changes.first { $0.key == added.key }?.isInsert == true)
    }

    @Test func undoingADeleteRestoresRecordsAndIndices() throws {
        let f = Fixture()
        let edge = try #require(f.workspace.connect(f.a1, to: f.b, relation: .supports))
        f.workspace.removeFromMap([f.a], mapID: f.map.id)
        #expect(f.workspace.nodes[f.a] == nil)
        #expect(f.workspace.nodes[f.a1] == nil)
        #expect(f.workspace.edges[edge.id] == nil)
        #expect(f.workspace.edgeIDsByNode[f.b, default: []].isEmpty)

        f.workspace.undo()
        #expect(f.title(f.a) == "A")
        #expect(f.tree.children(of: f.a) == [f.a1])
        #expect(f.workspace.edges[edge.id] != nil)
        #expect(f.workspace.edgeIDsByNode[f.b] == [edge.id])
        #expect(f.workspace.placementIDsByNode[f.a1]?.count == 1)
        #expect(f.workspace.edges(in: f.map.id).map(\.id) == [edge.id])
    }

    @Test func undoingADeleteBringsBackTheSameObjects() throws {
        let f = Fixture()
        let node = try #require(f.node(f.b))
        f.workspace.deleteMap(f.map)
        #expect(f.workspace.maps[f.map.id] == nil)

        f.workspace.undo()
        // Windows and views that held on to these keep working after the undo.
        #expect(f.workspace.maps[f.map.id] === f.map)
        #expect(f.node(f.b) === node)
        f.workspace.renameMap(f.map, to: "Still live")
        #expect(f.workspace.maps[f.map.id]?.name == "Still live")
    }

    @Test func theHistoryKeepsAtMostItsLimit() throws {
        let f = Fixture()
        f.workspace.history.limit = 3
        let node = try #require(f.node(f.b))
        for i in 1...5 { f.workspace.updateNode(node, "Rename") { $0.title = "B\(i)" } }
        #expect(f.workspace.history.undoStack.count == 3)
        while f.workspace.history.canUndo { f.workspace.undo() }
        #expect(f.title(f.b) == "B2")
    }

    @Test func observersHearEditsUndoAndRedo() throws {
        final class Owner {}
        let f = Fixture()
        var owner: Owner? = Owner()
        var origins: [ChangeOrigin] = []
        f.workspace.addChangeObserver(owner!) { _, origin in origins.append(origin) }
        let revision = f.workspace.revision

        let node = try #require(f.node(f.a))
        f.workspace.updateNode(node, "Rename") { $0.title = "Alpha" }
        f.workspace.undo()
        f.workspace.redo()
        #expect(origins == [.edit, .undo, .redo])
        #expect(f.workspace.revision == revision + 3)

        // Observers go away with their owner.
        owner = nil
        f.workspace.undo()
        #expect(origins.count == 3)
    }

    @Test func editsStampTheModificationDate() throws {
        let f = Fixture()
        let node = try #require(f.node(f.a))
        f.clock.advance(60)
        f.workspace.updateNode(node, "Rename") { $0.title = "Alpha" }
        #expect(node.updatedAt == f.clock.now)
    }
}
