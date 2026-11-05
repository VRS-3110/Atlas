import CoreGraphics
import Testing
@testable import AtlasLayout

@Suite("Arrow-key navigation")
struct SpatialNavigationTests {
    let origin = CGPoint(x: 0, y: 0)

    @Test func picksTheNearestNodeInTheDirection() {
        let candidates: [(id: String, center: CGPoint)] = [
            ("near", CGPoint(x: 100, y: 0)), ("far", CGPoint(x: 300, y: 0)),
            ("behind", CGPoint(x: -50, y: 0)), ("below", CGPoint(x: 0, y: 80)),
        ]
        #expect(SpatialNavigation.nearest(from: origin, direction: .right, candidates: candidates) == "near")
        #expect(SpatialNavigation.nearest(from: origin, direction: .left, candidates: candidates) == "behind")
        // Canvas y grows downwards.
        #expect(SpatialNavigation.nearest(from: origin, direction: .down, candidates: candidates) == "below")
        #expect(SpatialNavigation.nearest(from: origin, direction: .up, candidates: candidates) == nil)
    }

    @Test func prefersNodesInLineOverSlightlyNearerOnesOffToTheSide() {
        let candidates: [(id: String, center: CGPoint)] = [
            ("diagonal", CGPoint(x: 100, y: 90)), ("inLine", CGPoint(x: 160, y: 5)),
        ]
        #expect(SpatialNavigation.nearest(from: origin, direction: .right, candidates: candidates) == "inLine")
    }

    @Test func ignoresNodesOutsideTheCone() {
        let steep: [(id: String, center: CGPoint)] = [("steep", CGPoint(x: 10, y: 200))]
        #expect(SpatialNavigation.nearest(from: origin, direction: .right, candidates: steep) == nil)
        let itself: [(id: String, center: CGPoint)] = [("self", origin)]
        #expect(SpatialNavigation.nearest(from: origin, direction: .right, candidates: itself) == nil)
        let none: [(id: String, center: CGPoint)] = []
        #expect(SpatialNavigation.nearest(from: origin, direction: .right, candidates: none) == nil)
    }
}
