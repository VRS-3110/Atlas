import Foundation
@testable import AtlasCore

/// A clock the tests move forward by hand, so undo coalescing does not depend on timing.
@MainActor
final class TestClock {
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
}

/// A workspace with one map shaped like this, and an empty undo history:
///
///     Root ─┬─ A ── A1
///           └─ B
@MainActor
struct Fixture {
    let clock = TestClock()
    let workspace = Workspace()
    let map: MindMap
    let root: UUID
    let a: UUID
    let a1: UUID
    let b: UUID

    init() {
        let clock = clock
        workspace.clock = { clock.now }
        map = workspace.createMap(named: "Test", rootTitle: "Root")
        root = workspace.tree(of: map.id).roots[0]
        a = workspace.addChild(to: root, in: map.id, data: NodeData(title: "A")).id
        a1 = workspace.addChild(to: a, in: map.id, data: NodeData(title: "A1")).id
        b = workspace.addChild(to: root, in: map.id, data: NodeData(title: "B")).id
        workspace.history.removeAll()
    }

    func title(_ id: UUID) -> String? { workspace.nodes[id]?.title }
    func node(_ id: UUID) -> Node? { workspace.nodes[id] }
    var tree: MapTree { workspace.tree(of: map.id) }

    /// Adds a node that is on no map.
    @discardableResult
    func loose(_ title: String, kind: NodeKind = .idea) -> Node {
        workspace.createNode(NodeData(title: title, kind: kind, createdAt: clock.now))
    }
}

/// A fresh folder under the system temporary directory, removed by `cleanUp()`.
struct TemporaryFolder {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("AtlasTests-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var storeURL: URL { url.appendingPathComponent("Atlas.sqlite") }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }
}
