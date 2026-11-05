import CoreGraphics
import Foundation
import Testing
@testable import AtlasLayout

/// A small tree with ids as strings:
///
///     root ─┬─ a ─┬─ a1
///           │     └─ a2 (tall)
///           ├─ b
///           └─ c ── c1
private struct Sample {
    var roots = ["root"]
    var children: [String: [String]] = [
        "root": ["a", "b", "c"],
        "a": ["a1", "a2"],
        "c": ["c1"],
    ]
    var sizes: [String: CGSize] = [
        "root": CGSize(width: 140, height: 44),
        "a": CGSize(width: 90, height: 32), "a1": CGSize(width: 120, height: 32),
        "a2": CGSize(width: 100, height: 70), "b": CGSize(width: 60, height: 32),
        "c": CGSize(width: 110, height: 32), "c1": CGSize(width: 80, height: 32),
    ]
    var anchors: [String: CGPoint] = ["root": CGPoint(x: 100, y: 50)]
    var leftSide: Set<String> = []

    var input: TreeLayout.Input<String> {
        TreeLayout.Input(roots: roots, children: children, sizes: sizes, anchors: anchors, leftSide: leftSide)
    }

    func rects(_ positions: [String: CGPoint]) -> [String: CGRect] {
        positions.reduce(into: [:]) { result, entry in
            result[entry.key] = Geometry.rect(center: entry.value, size: sizes[entry.key]!)
        }
    }
}

private func overlaps(_ rects: [String: CGRect]) -> [String] {
    let entries = rects.sorted { $0.key < $1.key }
    var found: [String] = []
    for (i, a) in entries.enumerated() {
        for b in entries[(i + 1)...] where a.value.insetBy(dx: 0.5, dy: 0.5).intersects(b.value) {
            found.append("\(a.key)/\(b.key)")
        }
    }
    return found
}

@Suite("Automatic layouts")
struct TreeLayoutTests {
    let spacing = TreeLayout.Spacing()

    @Test(arguments: [LayoutStyle.mindMap, .treeRight, .orgChart, .radial])
    func everyNodeIsPlacedWithoutOverlaps(style: LayoutStyle) {
        var sample = Sample()
        sample.leftSide = ["b"]
        let positions = TreeLayout.positions(for: sample.input, style: style)
        #expect(Set(positions.keys) == Set(sample.sizes.keys))
        #expect(positions["root"] == CGPoint(x: 100, y: 50), "the root keeps its anchor")
        #expect(overlaps(sample.rects(positions)).isEmpty)
    }

    @Test func treeRightStacksChildrenInAColumnCentredOnTheParent() throws {
        let sample = Sample()
        let p = TreeLayout.positions(for: sample.input, style: .treeRight)
        let r = sample.rects(p)
        let root = try #require(r["root"])
        // Every child of the root starts one gap to the right of it.
        for id in ["a", "b", "c"] {
            #expect(abs(r[id]!.minX - (root.maxX + spacing.level)) < 0.001)
        }
        #expect(p["a"]!.y < p["b"]!.y && p["b"]!.y < p["c"]!.y, "siblings keep their order top to bottom")
        // A parent sits halfway along its children's column.
        #expect(abs(p["a"]!.y - (r["a1"]!.minY + r["a2"]!.maxY) / 2) < 0.001)
        // The root sits halfway along the whole column.
        let column = r["a1"]!.minY ... r["c1"]!.maxY
        #expect(abs(p["root"]!.y - (column.lowerBound + column.upperBound) / 2) < 0.001)
        // Neighbouring branches are one sibling gap apart.
        #expect(abs(r["b"]!.minY - (r["a2"]!.maxY + spacing.sibling)) < 0.001)
    }

    @Test func mindMapPutsChosenBranchesOnTheLeft() {
        var sample = Sample()
        sample.leftSide = ["a"]
        let p = TreeLayout.positions(for: sample.input, style: .mindMap)
        let r = sample.rects(p)
        #expect(r["a"]!.maxX == r["root"]!.minX - spacing.level)
        #expect(p["a1"]!.x < p["a"]!.x, "a branch on the left keeps growing left")
        #expect(r["b"]!.minX == r["root"]!.maxX + spacing.level)
        #expect(p["c1"]!.x > p["c"]!.x)
    }

    @Test func orgChartRowsShareACentreLine() {
        let sample = Sample()
        let p = TreeLayout.positions(for: sample.input, style: .orgChart)
        #expect(p["a"]!.y == p["b"]!.y && p["b"]!.y == p["c"]!.y)
        #expect(p["a1"]!.y == p["a2"]!.y && p["a2"]!.y == p["c1"]!.y)
        #expect(p["a"]!.y > p["root"]!.y && p["a1"]!.y > p["a"]!.y)
        #expect(p["a"]!.x < p["b"]!.x && p["b"]!.x < p["c"]!.x, "siblings keep their order left to right")
        // A parent is centred over the row its children take up.
        let r = sample.rects(p)
        #expect(abs(p["a"]!.x - (r["a1"]!.minX + r["a2"]!.maxX) / 2) < 0.001)
        // The tallest card in a row sets the gap to the next row.
        let rowGap = (p["a1"]!.y - 70 / 2) - (p["a"]!.y + 32 / 2)
        #expect(abs(rowGap - spacing.row) < 0.001)
    }

    @Test func radialPutsEachDepthOnOneRing() {
        let sample = Sample()
        let p = TreeLayout.positions(for: sample.input, style: .radial)
        let centre = p["root"]!
        func distance(_ id: String) -> CGFloat { hypot(p[id]!.x - centre.x, p[id]!.y - centre.y) }
        #expect(abs(distance("a") - distance("b")) < 0.001 && abs(distance("b") - distance("c")) < 0.001)
        #expect(abs(distance("a1") - distance("c1")) < 0.001)
        #expect(distance("a1") > distance("a"))
        // The first branch is at twelve o'clock.
        let firstAngle = atan2(p["a"]!.y - centre.y, p["a"]!.x - centre.x)
        #expect(abs(firstAngle + .pi / 2) < 0.001)
        // a has two leaves out of four, so it gets half the circle and b comes next, clockwise.
        let secondAngle = atan2(p["b"]!.y - centre.y, p["b"]!.x - centre.x)
        #expect(abs(secondAngle - .pi / 4) < 0.001)
    }

    @Test func manyRadialNeighboursPushTheRingOutwards() {
        var children: [String: [String]] = ["root": []]
        var sizes: [String: CGSize] = ["root": CGSize(width: 120, height: 44)]
        for i in 0..<24 {
            children["root"]!.append("n\(i)")
            sizes["n\(i)"] = CGSize(width: 150, height: 32)
        }
        let input = TreeLayout.Input(roots: ["root"], children: children, sizes: sizes,
                                     anchors: ["root": .zero])
        let p = TreeLayout.positions(for: input, style: .radial)
        let rects = p.reduce(into: [String: CGRect]()) { $0[$1.key] = Geometry.rect(center: $1.value, size: sizes[$1.key]!) }
        #expect(overlaps(rects).isEmpty)
    }

    @Test func pinnedNodesKeepTheirPlaceAndTakeNoRoom() {
        var sample = Sample()
        let unpinned = TreeLayout.positions(for: sample.input, style: .treeRight)
        sample.anchors["a"] = CGPoint(x: 600, y: -300)
        let p = TreeLayout.positions(for: sample.input, style: .treeRight)
        #expect(p["a"] == CGPoint(x: 600, y: -300))
        // Its branch is laid out around it.
        #expect(abs(p["a1"]!.x - (600 + 90 / 2 + spacing.level + 120 / 2)) < 0.001)
        let r = sample.rects(p)
        #expect(abs(p["a"]!.y - (r["a1"]!.minY + r["a2"]!.maxY) / 2) < 0.001, "its children's column is centred on it")
        // b and c close up the space a used to take.
        #expect(p["b"]!.y < unpinned["b"]!.y)
        #expect(abs(r["c"]!.minY - (r["b"]!.maxY + spacing.sibling)) < 0.001)
    }

    @Test func pinnedMindMapBranchesGrowAwayFromTheirParent() {
        var sample = Sample()
        sample.anchors["c"] = CGPoint(x: -400, y: 0)
        let p = TreeLayout.positions(for: sample.input, style: .mindMap)
        #expect(p["c"] == CGPoint(x: -400, y: 0))
        #expect(p["c1"]!.x < p["c"]!.x)
    }

    @Test func everyRootKeepsItsAnchor() {
        var sample = Sample()
        sample.roots = ["root", "loose"]
        sample.sizes["loose"] = CGSize(width: 80, height: 32)
        sample.anchors["loose"] = CGPoint(x: 900, y: 900)
        for style in LayoutStyle.allCases {
            let p = TreeLayout.positions(for: sample.input, style: style)
            #expect(p["root"] == CGPoint(x: 100, y: 50))
            #expect(p["loose"] == CGPoint(x: 900, y: 900))
        }
    }

    @Test func layoutsAreDeterministic() {
        let sample = Sample()
        for style in LayoutStyle.allCases {
            #expect(TreeLayout.positions(for: sample.input, style: style)
                    == TreeLayout.positions(for: sample.input, style: style))
        }
    }

    @Test func freePlacementOnlyReturnsAnchors() {
        let sample = Sample()
        #expect(TreeLayout.positions(for: sample.input, style: .free) == ["root": CGPoint(x: 100, y: 50)])
    }

    @Test func largeTreesLayOutQuickly() {
        // 1,000 nodes in a bushy tree: the layout is linear, so this takes milliseconds.
        var children: [Int: [Int]] = [:]
        var sizes: [Int: CGSize] = [0: CGSize(width: 120, height: 44)]
        for id in 1..<1000 {
            children[(id - 1) / 6, default: []].append(id)
            sizes[id] = CGSize(width: 100 + CGFloat(id % 5) * 10, height: 32)
        }
        let input = TreeLayout.Input(roots: [0], children: children, sizes: sizes, anchors: [0: .zero])
        let start = Date()
        for style in [LayoutStyle.mindMap, .treeRight, .orgChart, .radial] {
            #expect(TreeLayout.positions(for: input, style: style).count == 1000)
        }
        #expect(Date().timeIntervalSince(start) < 1)
    }
}
