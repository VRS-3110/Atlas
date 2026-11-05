import Foundation
import Testing
@testable import AtlasCore

@Suite("Model")
struct ModelTests {
    @Test func tagsAreNormalised() {
        #expect(Tags.normalize("  #machine   learning ") == "machine-learning")
        #expect(Tags.normalize("##") == "")
        #expect(Tags.parse("biology, #evolution\n field notes ,,") == ["biology", "evolution", "field-notes"])
    }

    @Test func addingTagsSkipsDuplicatesIgnoringCase() {
        var data = NodeData(title: "Finches", tags: ["Biology"])
        data.addTags(["biology", "#Field work", " "])
        #expect(data.tags == ["Biology", "Field-work"])
        #expect(data.hasTag("FIELD-WORK"))
        data.removeTag("BIOLOGY")
        #expect(data.tags == ["Field-work"])
    }

    @Test func kindsCreateTheFacetsTheyNeed() {
        #expect(NodeData(kind: .source).source != nil)
        #expect(NodeData(kind: .task).task != nil)
        #expect(NodeData(kind: .idea).source == nil)

        var data = NodeData(title: "Read Darwin")
        data.setKind(.task)
        #expect(data.task?.status == .todo)
        // Changing the kind back keeps the planning data rather than losing it.
        data.setKind(.note)
        #expect(data.task != nil)
    }

    @Test func taskDetails() {
        #expect(TaskStatus.todo.isOpen && TaskStatus.doing.isOpen)
        #expect(!TaskStatus.done.isOpen && !TaskStatus.cancelled.isOpen)
        #expect(TaskPriority.allCases.sorted() == [.none, .low, .medium, .high])
        let start = Date(timeIntervalSinceReferenceDate: 0)
        #expect(TaskInfo(scheduledStart: start, durationMinutes: 45).scheduledEnd == start.addingTimeInterval(2700))
        #expect(TaskInfo().scheduledEnd == nil)
    }

    @Test func relationsHaveSensibleDefaults() {
        let a = UUID(), b = UUID()
        let related = EdgeData(from: a, to: b)
        #expect(!related.hasArrow)
        #expect(related.displayLabel == "")
        #expect(related.connects(b, a))
        let partOf = EdgeData(from: a, to: b, relation: .partOf)
        #expect(partOf.lineStyle == .dotted)
        #expect(partOf.displayLabel == "part of")
        #expect(EdgeData(from: a, to: b, relation: .supports, label: "strongly").displayLabel == "strongly")
    }

    @Test func everyRecordKindSurvivesARoundTrip() throws {
        let date = Date(timeIntervalSinceReferenceDate: 812_345_678.123_456)
        let node = NodeData(title: "Quote", body: "**bold**", kind: .quote, tags: ["a", "b"], color: .teal,
                            createdAt: date, inbox: .inbox, citations: [Citation(sourceID: UUID(), page: "3")],
                            source: SourceInfo(entryType: "book", authors: ["Doe, Jane"], year: 2001,
                                               doi: "10.1000/xyz", extraFields: ["note": "first edition"]),
                            task: TaskInfo(status: .doing, priority: .high, due: date, focusSeconds: 90),
                            link: "https://example.org")
        let records: [any EntityData] = [
            node,
            EdgeData(from: UUID(), to: UUID(), relation: .custom, label: "cites", createdAt: date),
            MapData(name: "Map", layoutStyle: .orgChart, sortIndex: 3, createdAt: date),
            PlacementData(mapID: UUID(), nodeID: UUID(), position: CGPoint(x: 1.5, y: -2.25), parentID: UUID(),
                          order: 0.5, isCollapsed: true, isPinned: true),
            FrameData(mapID: UUID(), title: "Group", color: .purple, nodeIDs: [UUID(), UUID()], createdAt: date),
            DayLogData(day: "2026-11-03", body: "Wrote tests", touchedNodeIDs: [UUID()], createdAt: date),
        ]
        for record in records {
            let data = try RecordCodec.encode(record)
            let decoded = try RecordCodec.decode(kind: type(of: record).entityKind, from: data)
            #expect(recordsEqual(record, decoded), "\(type(of: record)) changed in a round trip")
        }
    }

    @Test func decodingToleratesMissingUnknownAndBrokenFields() throws {
        let json = """
        {"title": "From the future", "kind": "hologram", "tags": "not-a-list",
         "someNewField": {"nested": true}, "task": {"status": "done", "priority": 7}}
        """
        let decoded = try RecordCodec.decode(kind: .node, from: Data(json.utf8))
        let node = try #require(decoded as? NodeData)
        #expect(node.title == "From the future")
        #expect(node.kind == .idea)
        #expect(node.tags.isEmpty)
        #expect(node.body.isEmpty)
        #expect(node.task?.status == .done)
        #expect(node.task?.priority == TaskPriority.none)

        let ids = #"{"mapID": "\#(UUID().uuidString)", "nodeID": "\#(UUID().uuidString)", "x": 4, "order": "first"}"#
        let placement = try #require(try RecordCodec.decode(kind: .placement, from: Data(ids.utf8)) as? PlacementData)
        #expect(placement.x == 4)
        #expect(placement.order == 0)
        #expect(placement.parentID == nil)

        // Without the ids a placement means nothing, so it is reported as unreadable instead.
        #expect(throws: (any Error).self) {
            try RecordCodec.decode(kind: .placement, from: Data(#"{"x": 4}"#.utf8))
        }
    }
}
