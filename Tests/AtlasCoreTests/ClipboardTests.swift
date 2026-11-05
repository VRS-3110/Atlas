import CoreGraphics
import Foundation
import Testing
@testable import AtlasCore

@MainActor
@Suite("Copy, paste and outlines")
struct ClipboardTests {
    func position(_ f: Fixture) -> (UUID) -> CGPoint? {
        { f.workspace.placement(of: $0, in: f.map.id)?.data.position }
    }

    @Test func copyTakesWholeBranchesAndTheirEdges() throws {
        let f = Fixture()
        _ = try #require(f.workspace.connect(f.a1, to: f.a, relation: .supports))
        _ = try #require(f.workspace.connect(f.a, to: f.b))
        let clip = f.workspace.copyBranches([f.a, f.a1], in: f.map.id, position: position(f))
        #expect(clip.items.map(\.data.title) == ["A", "A1"])
        #expect(clip.items[1].parent == f.a)
        #expect(clip.items[0].parent == nil, "the root was not copied")
        // Only the edge inside the copy comes along.
        #expect(clip.edges.count == 1 && clip.edges[0].relation == .supports)
        #expect(OutlineText.render(clip.outline) == "A\n\tA1")
    }

    @Test func pasteMakesNewNodesWithTheSameShape() throws {
        let f = Fixture()
        _ = try #require(f.workspace.connect(f.a1, to: f.a, relation: .supports))
        let clip = f.workspace.copyBranches([f.a], in: f.map.id, position: position(f))
        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(MapClipboard.self, from: data)
        #expect(decoded == clip)

        let tops = f.workspace.paste(decoded, into: f.map.id, under: f.b, origin: CGPoint(x: 500, y: 500))
        let copy = try #require(tops.first)
        #expect(tops.count == 1)
        #expect(copy != f.a)
        #expect(f.title(copy) == "A")
        #expect(f.tree.parent[copy] == f.b)
        let copiedChild = try #require(f.tree.children(of: copy).first)
        #expect(f.title(copiedChild) == "A1" && copiedChild != f.a1)
        #expect(f.workspace.placement(of: copy, in: f.map.id)?.position == CGPoint(x: 500, y: 500))
        // The relation was copied between the copies.
        let edge = try #require(f.workspace.edge(between: copiedChild, and: copy))
        #expect(edge.fromID == copiedChild && edge.relation == .supports)
        // One undo step removes everything that was pasted.
        #expect(f.workspace.history.undoActionName == "Paste")
        f.workspace.undo()
        #expect(f.workspace.nodes[copy] == nil && f.workspace.nodes[copiedChild] == nil)
        #expect(f.tree.children(of: f.b).isEmpty)
    }

    @Test func pasteSlotsInAmongSiblings() {
        let f = Fixture()
        let clip = f.workspace.copyBranches([f.b], in: f.map.id, position: position(f))
        let tops = f.workspace.paste(clip, into: f.map.id, under: f.root, at: .after(f.a), origin: .zero,
                                     actionName: "Duplicate")
        #expect(f.tree.children(of: f.root) == [f.a] + tops + [f.b])
        #expect(f.workspace.history.undoActionName == "Duplicate")
    }

    @Test func outlinesBecomeClipsLaidOutToTheRight() {
        let clip = MapClipboard(outline: OutlineText.parse("Plan\n\tRead\n\tWrite\nShip"))
        #expect(clip.items.map(\.data.title) == ["Plan", "Read", "Write", "Ship"])
        #expect(clip.items[0].offsetX == 0 && clip.items[0].offsetY == 0)
        #expect(clip.items[1].offsetX > 0, "children sit to the right of their parent")
        #expect(clip.items[3].offsetY > clip.items[0].offsetY, "the next top-level item sits below")
        #expect(clip.outline == OutlineText.parse("Plan\n\tRead\n\tWrite\nShip"))
    }

    @Test func parsesIndentationListsAndHeadings() {
        let text = """
        # Literature
        - Theme one
          - Smith 2020
          - [ ] Jones 2021
        - Theme two

        ## Method
        1. Interviews
        2) Survey
        \t\tDeep
        """
        let items = OutlineText.parse(text)
        #expect(items == [
            .init("Literature", children: [
                .init("Theme one", children: [.init("Smith 2020"), .init("Jones 2021")]),
                .init("Theme two"),
                .init("Method", children: [.init("Interviews"), .init("Survey", children: [.init("Deep")])]),
            ]),
        ])
        #expect(items[0].count == 9)
    }

    @Test func outlinesRoundTrip() {
        let items: [OutlineText.Item] = [
            .init("A", children: [.init("A1", children: [.init("A1a")]), .init("A2")]),
            .init("B"),
        ]
        #expect(OutlineText.parse(OutlineText.render(items)) == items)
        #expect(OutlineText.parse("\r\n  \n").isEmpty)
        #expect(OutlineText.parse("  - only one") == [.init("only one")])
    }
}

@Suite("Fuzzy matching")
struct FuzzyMatchTests {
    @Test func matchesCharactersInOrder() {
        #expect(FuzzyMatch.score("lr", "Literature Review") != nil)
        #expect(FuzzyMatch.score("rev", "Literature Review") != nil)
        #expect(FuzzyMatch.score("rl", "Literature Review") == nil, "order matters")
        #expect(FuzzyMatch.score("xyz", "Literature Review") == nil)
        #expect(FuzzyMatch.score("", "Anything") == 0)
        #expect(FuzzyMatch.score("café", "Cafe culture") != nil, "accents are ignored")
        #expect(FuzzyMatch.score("CAFE", "café") != nil, "case is ignored")
    }

    @Test func ranksWordStartsAndPrefixesHigher() throws {
        let acronym = try #require(FuzzyMatch.score("lr", "Literature Review"))
        let scattered = try #require(FuzzyMatch.score("lr", "Plural forms"))
        #expect(acronym > scattered)

        let prefix = try #require(FuzzyMatch.score("hyp", "Hypothesis"))
        let inside = try #require(FuzzyMatch.score("hyp", "A new hypothesis"))
        #expect(prefix > inside)

        let exact = try #require(FuzzyMatch.score("sources", "Sources"))
        let longer = try #require(FuzzyMatch.score("sources", "Sources library view"))
        #expect(exact > longer)

        let run = try #require(FuzzyMatch.score("map", "New Map"))
        let spread = try #require(FuzzyMatch.score("map", "Make a plan"))
        #expect(run > spread)
    }

    @Test func multiWordQueriesMatchAcrossWords() throws {
        let score = try #require(FuzzyMatch.score("zoom fit", "Zoom to Fit"))
        #expect(score > 0)
    }
}
