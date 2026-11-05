import CoreGraphics
import Foundation
import Testing
@testable import AtlasCore

@Suite("Map tree")
struct MapTreeTests {
    let mapID = UUID()

    private func placement(_ node: UUID, parent: UUID? = nil, order: Double = 0,
                           collapsed: Bool = false) -> Placement {
        Placement(data: PlacementData(mapID: mapID, nodeID: node, position: .zero, parentID: parent,
                                      order: order, isCollapsed: collapsed))
    }

    @Test func childrenFollowTheirOrder() {
        let (root, x, y, z) = (UUID(), UUID(), UUID(), UUID())
        let tree = MapTree(mapID: mapID, placements: [
            placement(z, parent: root, order: 2), placement(root),
            placement(x, parent: root, order: 0), placement(y, parent: root, order: 1),
        ])
        #expect(tree.roots == [root])
        #expect(tree.children(of: root) == [x, y, z])
        #expect(tree.siblings(of: y) == [x, y, z])
        #expect(tree.depth(of: y) == 1)
        #expect(tree.root(of: z) == root)
    }

    @Test func placementsWithAMissingParentBecomeRoots() {
        let (orphan, gone) = (UUID(), UUID())
        let tree = MapTree(mapID: mapID, placements: [placement(orphan, parent: gone)])
        #expect(tree.roots == [orphan])
        #expect(tree.parent[orphan] == nil)
    }

    @Test func cyclesAreBroken() {
        // x → y → z → x: bad data from a sync conflict, say. Every node must still be
        // reachable exactly once.
        let (x, y, z) = (UUID(), UUID(), UUID())
        let tree = MapTree(mapID: mapID, placements: [
            placement(x, parent: z), placement(y, parent: x), placement(z, parent: y),
        ])
        #expect(tree.roots.count == 1)
        #expect(Set(tree.allIDs) == [x, y, z])
        #expect(tree.allIDs.count == 3)
        let selfParent = UUID()
        let single = MapTree(mapID: mapID, placements: [placement(selfParent, parent: selfParent)])
        #expect(single.roots == [selfParent])
    }

    @Test func collapsedBranchesAreHidden() {
        let (root, a, a1, a11, b) = (UUID(), UUID(), UUID(), UUID(), UUID())
        let tree = MapTree(mapID: mapID, placements: [
            placement(root), placement(a, parent: root, order: 0, collapsed: true),
            placement(a1, parent: a), placement(a11, parent: a1), placement(b, parent: root, order: 1),
        ])
        #expect(tree.visibleIDs == [root, a, b])
        #expect(tree.allIDs == [root, a, a1, a11, b])
        #expect(!tree.isVisible(a11))
        #expect(tree.isVisible(a))
        #expect(tree.hiddenCount(under: a) == 2)
        #expect(tree.hiddenCount(under: root) == 0)
        #expect(tree.descendants(of: a) == [a1, a11])
        #expect(tree.isDescendant(a11, of: a))
        #expect(!tree.isDescendant(b, of: a))
        #expect(tree.ancestors(of: a11) == [a1, a, root])
    }
}
