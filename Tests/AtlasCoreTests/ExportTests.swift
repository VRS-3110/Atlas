import Foundation
import Testing
@testable import AtlasCore

@MainActor
@Suite("Export")
struct ExportTests {
    /// The fixture map with notes, a tag, a task, a quote citing a source and a relation.
    private func richFixture() -> (Fixture, quote: UUID) {
        let f = Fixture()
        let w = f.workspace
        w.updateNode(f.node(f.a)!, "Edit") { $0.body = "First line\nSecond line"; $0.tags = ["key"]; $0.kind = .question }
        w.updateNode(f.node(f.b)!, "Edit") { $0.task = TaskInfo(status: .done) }
        let source = w.addSource(title: "On the Origin of Species")
        w.updateNode(source, "Edit") { $0.source?.authors = ["Darwin, Charles"]; $0.source?.year = 1859 }
        let quote = w.addChild(to: f.a1, in: f.map.id, data: NodeData(title: "Endless forms", kind: .quote))
        w.addCitation(from: quote.id, to: source.id, page: "490")
        w.connect(f.a1, to: f.b, relation: .supports)
        return (f, quote.id)
    }

    @Test func markdownOutline() {
        let (f, _) = richFixture()
        let md = f.workspace.markdown(for: f.map.id)
        #expect(md == """
        # Test

        - Root
          - *Question:* A #key
            > First line
            > Second line
            - A1
              - *Quote:* “Endless forms” (Darwin, 1859, p. 490)
          - [x] B

        ## Connections

        - A1 → *supports* → B

        """)
    }

    @Test func markdownReadsBackAsTheSameTree() {
        let (f, _) = richFixture()
        let md = f.workspace.markdown(for: f.map.id)
        let (title, items) = OPML.items(fromFile: Data(md.utf8))
        #expect(title == "Test")
        #expect(items.count == 1 && items[0].title == "Root")
        let a = items[0].children[0]
        #expect(a.title == "A #key" && a.note == "First line\nSecond line")
        #expect(a.children[0].title == "A1")
        #expect(items[0].children[1].title == "B")
    }

    @Test func opmlRoundTrip() throws {
        let (f, _) = richFixture()
        let date = Date(timeIntervalSince1970: 0)
        let xml = f.workspace.opml(for: f.map.id, date: date)
        #expect(xml.contains("<dateCreated>Thu, 01 Jan 1970 00:00:00 GMT</dateCreated>"))
        #expect(xml.contains(#"<outline text="A" _note="First line&#10;Second line" atlasKind="question" category="key">"#))
        #expect(xml.contains(#"<outline text="B" _status="checked"/>"#))
        let parsed = try #require(OPML.parse(Data(xml.utf8)))
        #expect(parsed.title == "Test")
        let root = try #require(parsed.items.first)
        #expect(root.title == "Root" && root.children.map(\.title) == ["A", "B"])
        #expect(root.children[0].note == "First line\nSecond line")
        #expect(root.children[0].children[0].children[0].title == "Endless forms")
    }

    @Test func opmlEscapesAndRejectsOtherXML() {
        #expect(OPML.escape("a & <b> \"c\"\u{1}") == "a &amp; &lt;b&gt; &quot;c&quot;")
        #expect(OPML.parse(Data("<html><body/></html>".utf8)) == nil)
        #expect(OPML.parse(Data("not xml".utf8)) == nil)
    }

    @Test func importOutlineMakesAMapWithNotes() throws {
        let f = Fixture()
        let w = f.workspace
        let items = [OPML.Item("Topic", note: "About it", children: [OPML.Item("One"), OPML.Item("Two")])]
        let map = try #require(w.importOutline(items, named: "Imported"))
        let tree = w.tree(of: map.id)
        #expect(map.name == "Imported" && tree.roots.count == 1)
        let root = tree.roots[0]
        #expect(w.nodes[root]?.title == "Topic" && w.nodes[root]?.body == "About it")
        #expect(tree.children(of: root).compactMap { w.nodes[$0]?.title } == ["One", "Two"])
        #expect(w.history.undoActionName == "Import Outline")
        w.undo()
        #expect(w.maps[map.id] == nil)
        #expect(w.importOutline([], named: "Empty") == nil)
    }

    @Test func plainTextOutlineFile() {
        let (title, items) = OPML.items(fromFile: Data("Plan\n\tStep one\n\tStep two\nOther".utf8))
        #expect(title.isEmpty)
        #expect(items.map(\.title) == ["Plan", "Other"] && items[0].children.count == 2)
    }
}

@MainActor
@Suite("Workspace backup")
struct BackupTests {
    @Test func backupRoundTripsRecordsAndAttachments() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let (workspace, _) = try Workspace.open(at: folder.storeURL)
        workspace.populateWelcomeContent()
        let source = workspace.addSource(title: "Paper")
        let file = folder.url.appendingPathComponent("paper.pdf")
        try Data("%PDF-1.4 test".utf8).write(to: file)
        let attachment = try #require(try workspace.attachFile(at: file, to: source.id))
        workspace.setDayLogBody("Notes", for: Date())
        workspace.saveNow()
        let before = workspace.allRecords()

        let data = try workspace.backupData(createdAt: Date(timeIntervalSince1970: 1_000_000))
        let contents = try WorkspaceBackup.decode(data)
        #expect(contents.createdAt == Date(timeIntervalSince1970: 1_000_000))
        #expect(contents.records.count == before.count && contents.skippedRecords == 0)
        #expect(contents.attachments[attachment.storedName] == Data("%PDF-1.4 test".utf8))

        // Restore into a different, non-empty workspace.
        let other = try TemporaryFolder()
        defer { other.cleanUp() }
        let (target, _) = try Workspace.open(at: other.storeURL)
        target.createMap(named: "Will be replaced")
        target.saveNow()
        let report = try target.restoreBackup(contents)
        #expect(report.records == before.count && report.attachments == 1)
        let safety = try #require(report.safetyCopy)
        #expect(FileManager.default.fileExists(atPath: safety.path))
        #expect(!target.sortedMaps.contains { $0.name == "Will be replaced" })
        #expect(!target.history.canUndo)
        let restored = Dictionary(uniqueKeysWithValues: target.allRecords().map { ($0.key, $0.value) })
        for record in before {
            #expect(recordsEqual(record.value, restored[record.key]))
        }
        let restoredFile = try #require(target.document(of: source.id))
        #expect(try Data(contentsOf: restoredFile) == Data("%PDF-1.4 test".utf8))

        // The restore was saved: reopening shows the same records.
        let (reopened, _) = try Workspace.open(at: other.storeURL)
        #expect(reopened.allRecords().count == before.count)
    }

    @Test func badFilesAreRefused() throws {
        #expect(throws: WorkspaceBackup.BackupError.self) { try WorkspaceBackup.decode(Data("{}".utf8)) }
        #expect(throws: WorkspaceBackup.BackupError.self) { try WorkspaceBackup.decode(Data("nope".utf8)) }
        let newer = #"{"format":"atlas-workspace","version":99,"records":[]}"#
        #expect(throws: WorkspaceBackup.BackupError.self) { try WorkspaceBackup.decode(Data(newer.utf8)) }
        // Unknown kinds and unsafe attachment names are skipped, not fatal.
        let odd = #"""
        {"format":"atlas-workspace","version":1,
         "records":[{"kind":"widget","id":"00000000-0000-0000-0000-000000000001","data":{}}],
         "attachments":[{"name":"../evil","data":"AA=="},{"name":"ok.txt","data":"AA=="}]}
        """#
        let contents = try WorkspaceBackup.decode(Data(odd.utf8))
        #expect(contents.skippedRecords == 1 && contents.records.isEmpty)
        #expect(Array(contents.attachments.keys) == ["ok.txt"])
    }
}
