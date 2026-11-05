import CoreGraphics
import Testing
@testable import AtlasLayout

@Suite("Geometry")
struct GeometryTests {
    @Test func borderPointLeavesRectOnFacingSide() {
        let rect = CGRect(x: -50, y: -20, width: 100, height: 40)
        let right = Geometry.borderPoint(of: rect, toward: CGPoint(x: 500, y: 0))
        #expect(right == CGPoint(x: 50, y: 0))
        let below = Geometry.borderPoint(of: rect, toward: CGPoint(x: 0, y: 300))
        #expect(below == CGPoint(x: 0, y: 20))
        let centre = Geometry.borderPoint(of: rect, toward: CGPoint(x: 0, y: 0))
        #expect(centre == CGPoint(x: 0, y: 0))
        // A diagonal ray leaves through whichever side it reaches first.
        let diagonal = Geometry.borderPoint(of: rect, toward: CGPoint(x: 100, y: 100))
        #expect(diagonal == CGPoint(x: 20, y: 20))
    }

    @Test func rectIsCentred() {
        #expect(Geometry.rect(center: CGPoint(x: 10, y: 20), size: CGSize(width: 40, height: 10))
                == CGRect(x: -10, y: 15, width: 40, height: 10))
    }

    @Test func treeConnectorsJoinFacingSides() {
        let parent = CGRect(x: 0, y: 0, width: 100, height: 40)
        let rightChild = CGRect(x: 200, y: 100, width: 80, height: 30)
        let toRight = Geometry.treeConnector(from: parent, to: rightChild)
        #expect(toRight.axis == .horizontal)
        #expect(toRight.start == CGPoint(x: 100, y: 20))
        #expect(toRight.end == CGPoint(x: 200, y: 115))
        #expect(toRight.point(at: 0) == toRight.start)
        #expect(toRight.point(at: 1) == toRight.end)

        let leftChild = CGRect(x: -200, y: 0, width: 80, height: 30)
        let toLeft = Geometry.treeConnector(from: parent, to: leftChild)
        #expect(toLeft.start == CGPoint(x: 0, y: 20))
        #expect(toLeft.end == CGPoint(x: -120, y: 15))

        // An org chart forces vertical connectors even for side-by-side boxes.
        let below = Geometry.treeConnector(from: parent, to: rightChild, axis: .vertical)
        #expect(below.axis == .vertical)
        #expect(below.start == CGPoint(x: 50, y: 40))
        #expect(below.end == CGPoint(x: 240, y: 100))
    }

    @Test func overlappingColumnsPreferVerticalConnectors() {
        let parent = CGRect(x: 0, y: 0, width: 100, height: 40)
        let underneath = CGRect(x: 20, y: 120, width: 100, height: 40)
        #expect(Geometry.preferredAxis(from: parent, to: underneath) == .vertical)
        let beside = CGRect(x: 150, y: 120, width: 100, height: 40)
        #expect(Geometry.preferredAxis(from: parent, to: beside) == .horizontal)
    }

    @Test func relationEndpointsSitOnBorders() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 40)
        let b = CGRect(x: 300, y: 0, width: 100, height: 40)
        let ends = Geometry.relationEndpoints(from: a, to: b)
        #expect(ends.start == CGPoint(x: 100, y: 20))
        #expect(ends.end == CGPoint(x: 300, y: 20))
    }

    @Test func relationLabelSitsOnTheCurveWhenThereIsRoom() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 30)
        let b = CGRect(x: 300, y: 0, width: 100, height: 30)
        let curve = Geometry.relationCurve(from: a, to: b)
        #expect(Geometry.labelCenter(on: curve, size: CGSize(width: 60, height: 16), avoiding: [a, b]) == curve.midpoint)
    }

    @Test func relationLabelMovesBesideACurveTooShortForIt() {
        // A 30-point gap is too narrow for a 60-point label.
        let a = CGRect(x: 0, y: 0, width: 100, height: 30)
        let b = CGRect(x: 130, y: 0, width: 100, height: 30)
        let size = CGSize(width: 60, height: 16)
        let curve = Geometry.relationCurve(from: a, to: b)
        let centre = Geometry.labelCenter(on: curve, size: size, avoiding: [a, b])
        let box = Geometry.rect(center: centre, size: size)
        #expect(!box.intersects(a.insetBy(dx: -3, dy: -3)) && !box.intersects(b.insetBy(dx: -3, dy: -3)))
        // It stays over the gap, below the line (the way a left-to-right curve bows), and close.
        #expect(abs(centre.x - 115) < 0.01)
        #expect(centre.y > curve.midpoint.y && box.minY < 40)
        // Going right to left, the curve bows the other way and so does the label.
        let back = Geometry.labelCenter(on: Geometry.relationCurve(from: b, to: a), size: size, avoiding: [a, b])
        #expect(back.y < 0)
    }

    @Test func distanceToSegment() {
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 10, y: 0)
        #expect(Geometry.distance(from: CGPoint(x: 5, y: 3), toSegment: a, b) == 3)
        #expect(Geometry.distance(from: CGPoint(x: 14, y: 3), toSegment: a, b) == 5)
        #expect(Geometry.distance(from: CGPoint(x: 3, y: 4), toSegment: a, a) == 5)
    }

    @Test func unionCoversEveryRect() {
        #expect(Geometry.union([]) == nil)
        let rects = [CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: -5, y: 20, width: 5, height: 5)]
        #expect(Geometry.union(rects) == CGRect(x: -5, y: 0, width: 15, height: 25))
    }
}
