import CoreGraphics
import Testing
@testable import AtlasLayout

@Suite("Snapping, align and distribute")
struct ArrangeTests {
    let other = CGRect(x: 100, y: 100, width: 80, height: 40)

    @Test func snapsTheNearestEdgeWithinTheThreshold() {
        // Left edge 3 points right of the other's left edge; tops far apart.
        let moving = CGRect(x: 103, y: 300, width: 60, height: 30)
        let result = SnapGuides.snap(moving, to: [other], threshold: 6)
        #expect(result.offset == CGSize(width: -3, height: 0))
        #expect(result.guides == [SnapGuides.Guide(isVertical: true, position: 100, from: 100, to: 330)])
    }

    @Test func snapsCentresAndBothAxesIndependently() {
        // Centre x 142 vs 140; middle y 118 vs 120.
        let moving = CGRect(x: 122, y: 108, width: 40, height: 20)
        let result = SnapGuides.snap(moving, to: [other], threshold: 6)
        #expect(result.offset == CGSize(width: -2, height: 2))
        #expect(result.guides.contains { $0.isVertical && $0.position == 140 })
        #expect(result.guides.contains { !$0.isVertical && $0.position == 120 })
    }

    @Test func leavesFarRectsAlone() {
        let moving = CGRect(x: 130, y: 400, width: 33, height: 30)
        let result = SnapGuides.snap(moving, to: [other], threshold: 2)
        #expect(result.offset == .zero)
        #expect(result.guides.isEmpty)
    }

    @Test func alignsToTheSelectionBounds() {
        let rects: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 100, height: 40),
            "b": CGRect(x: 50, y: 100, width: 60, height: 20),
        ]
        let left = Arrange.align(rects, to: .left)
        #expect(left["a"] == CGPoint(x: 50, y: 20))
        #expect(left["b"] == CGPoint(x: 30, y: 110))
        let right = Arrange.align(rects, to: .right)
        #expect(right["a"]!.x + 50 == 110 && right["b"]!.x + 30 == 110)
        let centre = Arrange.align(rects, to: .centre)
        #expect(centre["a"]!.x == 55 && centre["b"]!.x == 55)
        let bottom = Arrange.align(rects, to: .bottom)
        #expect(bottom["a"] == CGPoint(x: 50, y: 100) && bottom["b"] == CGPoint(x: 80, y: 110))
        let middle = Arrange.align(rects, to: .middle)
        #expect(middle["a"]!.y == 60 && middle["b"]!.y == 60)
    }

    @Test func distributesGapsEvenly() {
        let rects: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 20, height: 20),
            "c": CGRect(x: 200, y: 0, width: 40, height: 20),
            "b": CGRect(x: 30, y: 0, width: 60, height: 20),
        ]
        let result = Arrange.distribute(rects, along: .horizontal)
        // Span 240, occupied 120: two gaps of 60. The ends stay put.
        #expect(result["a"] == CGPoint(x: 10, y: 10))
        #expect(result["b"] == CGPoint(x: 110, y: 10))
        #expect(result["c"] == CGPoint(x: 220, y: 10))
        #expect(Arrange.distribute(["a": rects["a"]!, "b": rects["b"]!], along: .vertical).isEmpty)
    }

    @Test func relationCurvesBowAndCanBeHit() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 40)
        let b = CGRect(x: 300, y: 0, width: 100, height: 40)
        let curve = Geometry.relationCurve(from: a, to: b)
        #expect(curve.start == CGPoint(x: 100, y: 20))
        #expect(curve.end == CGPoint(x: 300, y: 20))
        // Running left to right, the curve bows downwards (canvas y grows down).
        #expect(curve.midpoint.y > 20)
        #expect(curve.distance(to: curve.midpoint) < 0.5)
        #expect(curve.distance(to: CGPoint(x: 200, y: 200)) > 100)
        // The opposite direction bows the other way, so both edges stay visible.
        #expect(Geometry.relationCurve(from: b, to: a).midpoint.y < 20)
    }
}
