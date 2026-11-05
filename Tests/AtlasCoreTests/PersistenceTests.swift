import Foundation
import Testing
@testable import AtlasCore

@MainActor
@Suite("Saving and loading")
struct PersistenceTests {
    /// Every record in the workspace, keyed for comparison.
    private func snapshot(_ workspace: Workspace) -> [RecordKey: any EntityData] {
        Dictionary(uniqueKeysWithValues: workspace.allRecords().map { ($0.key, $0.value) })
    }

    private func expectSameRecords(_ a: Workspace, _ b: Workspace) {
        let left = snapshot(a), right = snapshot(b)
        #expect(Set(left.keys) == Set(right.keys))
        for (key, value) in left {
            #expect(recordsEqual(value, right[key]), "\(key.kind) \(key.id) differs after reloading")
        }
    }

    @Test func everythingSavedComesBack() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }

        let (workspace, report) = try Workspace.open(at: folder.storeURL)
        #expect(report.loadedRecords == 0)
        workspace.populateWelcomeContent()
        let map = try #require(workspace.sortedMaps.first)
        let root = try #require(workspace.tree(of: map.id).roots.first)
        workspace.addChild(to: root, in: map.id, data: NodeData(title: "Saved child"))
        #expect(workspace.persistence?.hasUnsavedChanges == true)
        #expect(workspace.saveNow())
        #expect(workspace.persistence?.hasUnsavedChanges == false)

        let (reopened, again) = try Workspace.open(at: folder.storeURL)
        #expect(again.unreadableRecords == 0)
        #expect(again.loadedRecords == workspace.allRecords().count)
        expectSameRecords(workspace, reopened)
        // Loading is not an edit: nothing to undo, nothing to save.
        #expect(!reopened.history.canUndo)
        #expect(reopened.persistence?.hasUnsavedChanges == false)
    }

    @Test func deletionsAndUndoneChangesAreSaved() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }

        let (workspace, _) = try Workspace.open(at: folder.storeURL)
        let keep = workspace.createMap(named: "Keep")
        let drop = workspace.createMap(named: "Drop")
        workspace.renameMap(keep, to: "Kept")
        workspace.saveNow()

        workspace.deleteMap(drop)
        workspace.undo() // the delete
        workspace.undo() // the rename
        workspace.deleteMap(drop)
        workspace.saveNow()

        let (reopened, _) = try Workspace.open(at: folder.storeURL)
        #expect(reopened.sortedMaps.map(\.name) == ["Keep"])
        #expect(reopened.nodes.count == 1)
        expectSameRecords(workspace, reopened)
    }

    @Test func editsAreSavedAutomatically() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }

        let (workspace, _) = try Workspace.open(at: folder.storeURL)
        workspace.persistence?.saveDelay = 0.05
        workspace.createMap(named: "Autosaved")
        #expect(workspace.persistence?.hasUnsavedChanges == true)

        for _ in 0..<40 where workspace.persistence?.hasUnsavedChanges == true {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(workspace.persistence?.hasUnsavedChanges == false)
        let (reopened, _) = try Workspace.open(at: folder.storeURL)
        #expect(reopened.sortedMaps.map(\.name) == ["Autosaved"])
    }

    @Test func unreadableRowsAreReportedAndLeftAlone() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }

        let brokenID = UUID().uuidString
        do {
            let database = try SQLiteDatabase(url: folder.storeURL)
            try database.write(upserts: [
                (kind: "node", id: brokenID, data: Data("not json".utf8)),
                (kind: "widget", id: UUID().uuidString, data: Data("{}".utf8)),
            ], deletes: [])
        }

        let (workspace, report) = try Workspace.open(at: folder.storeURL)
        #expect(report.unreadableRecords == 2)
        #expect(workspace.nodes.isEmpty)

        // Saving other changes must not touch them: a newer version of Atlas may read them.
        workspace.createMap(named: "New")
        workspace.saveNow()
        let rows = try SQLiteDatabase(url: folder.storeURL).loadAll()
        #expect(rows.contains { $0.id == brokenID && $0.data == Data("not json".utf8) })
        #expect(rows.contains { $0.kind == "widget" })
    }

    @Test func restoringReplacesEverything() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }

        let (workspace, _) = try Workspace.open(at: folder.storeURL)
        workspace.createMap(named: "Before")
        let saved = workspace.allRecords()
        workspace.createMap(named: "After")
        workspace.saveNow()

        try workspace.restore(from: saved)
        #expect(workspace.sortedMaps.map(\.name) == ["Before"])
        #expect(!workspace.history.canUndo)
        let (reopened, _) = try Workspace.open(at: folder.storeURL)
        #expect(reopened.sortedMaps.map(\.name) == ["Before"])
        expectSameRecords(workspace, reopened)
    }

    @Test func dailyBackupsArePrunedToTheNewest() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }

        let backups = folder.url.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        for day in 1...9 {
            let old = backups.appendingPathComponent(String(format: "Atlas-2020-01-%02d.sqlite", day))
            try Data().write(to: old)
        }

        let (workspace, _) = try Workspace.open(at: folder.storeURL)
        workspace.createMap(named: "Backed up")
        workspace.persistence?.makeDailyBackupIfNeeded(keep: 7)

        let names = try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()
        #expect(names.count == 7)
        #expect(names.first == "Atlas-2020-01-04.sqlite")
        let today = try #require(names.last)
        #expect(today.hasPrefix("Atlas-20") && !today.hasPrefix("Atlas-2020-01"))

        // The copy is a complete workspace, including the change saved just before it.
        let (copy, _) = try Workspace.open(at: backups.appendingPathComponent(today))
        #expect(copy.sortedMaps.map(\.name) == ["Backed up"])
    }

    @Test func theWelcomeMapIsSeededOnce() throws {
        let workspace = Workspace()
        workspace.populateWelcomeContent()
        #expect(workspace.maps.count == 1)
        #expect(workspace.nodes.count == 10)
        #expect(workspace.placements.count == 10)
        #expect(workspace.edges.count == 1)
        #expect(!workspace.history.canUndo)
        let quote = try #require(workspace.nodes.values.first { $0.kind == .quote })
        let source = try #require(workspace.nodes.values.first { $0.kind == .source })
        #expect(quote.citations.map(\.sourceID) == [source.id])

        workspace.populateWelcomeContent()
        #expect(workspace.maps.count == 1)
        #expect(workspace.nodes.count == 10)
    }

    @Test func mapsSavedBeforeLayoutsOpenInFreePlacementOnce() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }

        // A file written before automatic layouts: a mind map whose nodes were placed by hand.
        let (old, _) = try Workspace.open(at: folder.storeURL)
        let map = old.createMap(named: "Placed by hand", layout: .mindMap)
        old.saveNow()

        let (workspace, _) = try Workspace.open(at: folder.storeURL)
        workspace.migrateLayoutsIfNeeded()
        let migrated = try #require(workspace.maps[map.id])
        #expect(migrated.layoutStyle == .free)
        #expect(!workspace.history.canUndo, "the migration is not an edit")

        // It runs once: a layout chosen afterwards is kept.
        workspace.setLayoutStyle(.mindMap, of: migrated)
        workspace.saveNow()
        let (again, _) = try Workspace.open(at: folder.storeURL)
        again.migrateLayoutsIfNeeded()
        #expect(again.maps[map.id]?.layoutStyle == .mindMap)
    }

    @Test func newWorkspacesKeepTheirLayouts() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }

        let (workspace, _) = try Workspace.open(at: folder.storeURL)
        workspace.migrateLayoutsIfNeeded()
        workspace.populateWelcomeContent()
        workspace.saveNow()

        let (again, _) = try Workspace.open(at: folder.storeURL)
        again.migrateLayoutsIfNeeded()
        #expect(again.sortedMaps.first?.layoutStyle == .mindMap)
    }
}
