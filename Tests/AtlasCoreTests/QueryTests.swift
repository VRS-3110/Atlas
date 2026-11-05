import Foundation
import Testing
@testable import AtlasCore

@MainActor
@Suite("Queries")
struct QueryTests {
    @Test func backlinksGatherEveryKindOfReference() throws {
        let f = Fixture()
        let other = f.workspace.createMap(named: "Other", rootTitle: nil)
        f.workspace.placeNode(f.b, on: other.id, at: .zero)
        let source = f.loose("Origin of Species", kind: .source)
        let supporting = try #require(f.workspace.connect(f.a, to: f.b, relation: .supports))
        let leading = try #require(f.workspace.connect(f.b, to: f.a1, relation: .leadsTo))
        f.workspace.updateNode(try #require(f.node(f.b)), "Cite") {
            $0.citations = [Citation(sourceID: source.id, page: "490")]
        }
        let mentioning = f.workspace.createNode(NodeData(title: "Note", body: "See [[b]] for more."))

        let links = f.workspace.backlinks(of: f.b)
        #expect(links.maps.map(\.id) == [f.map.id, other.id])
        #expect(links.incoming.map { $0.edge.id } == [supporting.id])
        #expect(links.incoming.map { $0.node.id } == [f.a])
        #expect(links.outgoing.map { $0.edge.id } == [leading.id])
        #expect(links.cites.map { $0.source.id } == [source.id])
        #expect(links.cites.first?.citation.page == "490")
        #expect(links.mentionedBy.map(\.id) == [mentioning.id])
        #expect(links.citedBy.isEmpty)

        let sourceLinks = f.workspace.backlinks(of: source.id)
        #expect(sourceLinks.citedBy.map(\.id) == [f.b])
        #expect(f.workspace.backlinks(of: UUID()).isEmpty)
    }

    @Test func hopDistancesFollowTreeLinksAndRelations() throws {
        let f = Fixture()
        let b1 = f.workspace.addChild(to: f.b, in: f.map.id)
        var hops = f.workspace.hopDistances(from: f.a1, in: f.map.id, maxHops: 2)
        #expect(hops == [f.a1: 0, f.a: 1, f.root: 2])

        // A relation edge is a shortcut.
        f.workspace.connect(f.a1, to: b1.id)
        hops = f.workspace.hopDistances(from: f.a1, in: f.map.id, maxHops: 2)
        #expect(hops[b1.id] == 1)
        #expect(hops[f.b] == 2)

        // Edges to nodes on other maps do not count.
        let elsewhere = f.workspace.createMap(named: "Elsewhere")
        let far = try #require(f.workspace.tree(of: elsewhere.id).roots.first)
        f.workspace.connect(f.a1, to: far)
        #expect(f.workspace.hopDistances(from: f.a1, in: f.map.id, maxHops: 5)[far] == nil)
        #expect(f.workspace.hopDistances(from: far, in: f.map.id, maxHops: 5).isEmpty)
    }

    @Test func tagCountsMergeCaseAndSkipArchivedNodes() throws {
        let f = Fixture()
        f.workspace.updateNode(try #require(f.node(f.a)), "Tag") { $0.tags = ["Biology", "draft"] }
        f.workspace.updateNode(try #require(f.node(f.b)), "Tag") { $0.tags = ["biology"] }
        f.workspace.createNode(NodeData(title: "Old", tags: ["archived-only"], inbox: .archived))

        let counts = f.workspace.tagCounts()
        #expect(counts.map { $0.tag.lowercased() } == ["biology", "draft"])
        #expect(counts.map { $0.count } == [2, 1])
        #expect(Set(f.workspace.nodes(taggedWith: "BIOLOGY").map(\.id)) == [f.a, f.b])
    }

    @Test func searchNeedsEveryWordAndRanksTitlesFirst() throws {
        let f = Fixture()
        let exact = f.workspace.createNode(NodeData(title: "Natural selection"))
        let inTitle = f.workspace.createNode(NodeData(title: "Notes on natural selection in finches"))
        let inBody = f.workspace.createNode(NodeData(title: "Darwin", body: "natural selection"))
        f.workspace.createNode(NodeData(title: "Natural history"))
        f.workspace.createNode(NodeData(title: "Natural selection, archived", inbox: .archived))

        let results = f.workspace.searchNodes("natural selection")
        #expect(results.map(\.id) == [exact.id, inTitle.id, inBody.id])
        #expect(f.workspace.searchNodes("   ").isEmpty)
        #expect(f.workspace.searchNodes("natural", limit: 2).count == 2)
    }

    @Test func sourceDetailsAreSearchable() {
        let f = Fixture()
        let book = f.workspace.createNode(NodeData(title: "On the Origin of Species", kind: .source,
                                                   source: SourceInfo(authors: ["Darwin, Charles"],
                                                                      citationKey: "darwin1859")))
        #expect(f.workspace.searchNodes("darwin").map(\.id) == [book.id])
        #expect(f.workspace.searchNodes("darwin1859").map(\.id) == [book.id])
    }

    @Test func collectionsListTheRightNodes() {
        let f = Fixture()
        f.clock.advance(1)
        let older = f.workspace.createNode(NodeData(title: "Older", createdAt: f.clock.now, inbox: .inbox))
        f.clock.advance(1)
        let newer = f.workspace.createNode(NodeData(title: "Newer", createdAt: f.clock.now, inbox: .inbox))
        let zebra = f.loose("Zebra book", kind: .source)
        let apple = f.loose("Apple book", kind: .source)
        let task = f.loose("Write chapter", kind: .task)

        #expect(f.workspace.inboxNodes.map(\.id) == [newer.id, older.id])
        #expect(f.workspace.sourceNodes.map(\.id) == [apple.id, zebra.id])
        #expect(f.workspace.taskNodes.map(\.id) == [task.id])
    }

    @Test func mapEdgesNeedBothEndsOnTheMap() throws {
        let f = Fixture()
        let inside = try #require(f.workspace.connect(f.a, to: f.b))
        let loose = f.loose("Loose")
        f.workspace.connect(f.a, to: loose.id)
        #expect(f.workspace.edges(in: f.map.id).map(\.id) == [inside.id])
        #expect(f.workspace.edges(touching: f.a).count == 2)
    }
}
