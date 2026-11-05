import Foundation

/// Encodes records as JSON. The default date encoding keeps full precision, so a record
/// read back compares equal to the one written.
public enum RecordCodec {
    public static func encode(_ value: any EntityData) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode(kind: EntityKind, from data: Data) throws -> any EntityData {
        let decoder = JSONDecoder()
        switch kind {
        case .node: return try decoder.decode(NodeData.self, from: data)
        case .edge: return try decoder.decode(EdgeData.self, from: data)
        case .map: return try decoder.decode(MapData.self, from: data)
        case .placement: return try decoder.decode(PlacementData.self, from: data)
        case .frame: return try decoder.decode(FrameData.self, from: data)
        case .dayLog: return try decoder.decode(DayLogData.self, from: data)
        }
    }
}

/// Saves changed records shortly after each edit (at most `saveDelay` seconds of work can
/// be pending), and immediately when asked (app quit, window close).
@MainActor
public final class PersistenceController {
    let database: SQLiteDatabase
    weak var workspace: Workspace?
    private var dirty = Set<RecordKey>()
    private var pendingSave: Task<Void, Never>?

    public var saveDelay: TimeInterval = 0.4
    public private(set) var lastError: Error?
    public private(set) var lastSaveDate: Date?

    public var databaseURL: URL { database.url }
    public var hasUnsavedChanges: Bool { !dirty.isEmpty }

    init(database: SQLiteDatabase, workspace: Workspace) {
        self.database = database
        self.workspace = workspace
    }

    func markDirty(_ keys: [RecordKey]) {
        dirty.formUnion(keys)
        scheduleSave()
    }

    private func scheduleSave(after delay: TimeInterval? = nil) {
        guard pendingSave == nil else { return }
        let seconds = delay ?? saveDelay
        pendingSave = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.pendingSave = nil
            self.saveNow()
        }
    }

    /// Writes every pending change now. Returns false (and keeps the changes pending, with a
    /// retry scheduled) if the write fails.
    @discardableResult
    public func saveNow() -> Bool {
        pendingSave?.cancel()
        pendingSave = nil
        guard let workspace, !dirty.isEmpty else { return true }
        let keys = dirty
        do {
            var upserts: [(kind: String, id: String, data: Data)] = []
            var deletes: [(kind: String, id: String)] = []
            for key in keys {
                if let value = workspace.currentRecord(key) {
                    upserts.append((key.kind.rawValue, key.id.uuidString, try RecordCodec.encode(value)))
                } else {
                    deletes.append((key.kind.rawValue, key.id.uuidString))
                }
            }
            try database.write(upserts: upserts, deletes: deletes)
            dirty.subtract(keys)
            lastSaveDate = Date()
            lastError = nil
            return true
        } catch {
            lastError = error
            scheduleSave(after: 5)
            return false
        }
    }

    /// Rewrites the whole database from the workspace (used after restoring a backup).
    func saveEverything() throws {
        guard let workspace else { return }
        let rows = try workspace.allRecords().map {
            (kind: $0.key.kind.rawValue, id: $0.key.id.uuidString, data: try RecordCodec.encode($0.value))
        }
        try database.write(upserts: rows, deletes: [], replacingEverything: true)
        dirty.removeAll()
        lastSaveDate = Date()
    }

    /// Keeps a dated copy of the database in `Backups/`, at most one per day, and prunes
    /// all but the newest `keep` copies.
    public func makeDailyBackupIfNeeded(keep: Int = 7) {
        let folder = database.url.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let name = "Atlas-\(formatter.string(from: Date())).sqlite"
        let destination = folder.appendingPathComponent(name)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { return }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            saveNow()
            try database.backup(to: destination)
            let existing = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("Atlas-") && $0.pathExtension == "sqlite" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for old in existing.dropFirst(keep) { try? fm.removeItem(at: old) }
        } catch {
            lastError = error
        }
    }
}

extension Workspace {
    /// What happened while opening a workspace file.
    public struct LoadReport: Sendable {
        public var loadedRecords = 0
        /// Rows that could not be decoded. They stay in the file untouched.
        public var unreadableRecords = 0
    }

    /// `~/Library/Application Support/Atlas/Atlas.sqlite`, or `ATLAS_STORE_PATH` if set.
    public static var defaultStoreURL: URL {
        if let override = ProcessInfo.processInfo.environment["ATLAS_STORE_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Atlas", isDirectory: true).appendingPathComponent("Atlas.sqlite")
    }

    /// Folder for attached files, next to the database.
    public var attachmentsFolder: URL? {
        persistence?.databaseURL.deletingLastPathComponent().appendingPathComponent("Attachments", isDirectory: true)
    }

    /// Opens (or creates) the workspace stored at `url` and starts autosaving to it.
    public static func open(at url: URL) throws -> (workspace: Workspace, report: LoadReport) {
        let database = try SQLiteDatabase(url: url)
        let workspace = Workspace()
        var report = LoadReport()
        var records: [(key: RecordKey, value: any EntityData)] = []
        for row in try database.loadAll() {
            guard let kind = EntityKind(rawValue: row.kind), let id = UUID(uuidString: row.id),
                  let value = try? RecordCodec.decode(kind: kind, from: row.data) else {
                report.unreadableRecords += 1
                continue
            }
            records.append((RecordKey(kind: kind, id: id), value))
        }
        workspace.loadRecords(records)
        report.loadedRecords = records.count
        workspace.persistence = PersistenceController(database: database, workspace: workspace)
        return (workspace, report)
    }

    /// Maps saved before automatic layouts existed (build phase 1) hold hand-placed
    /// positions, some under a mind map style. Switching them to free placement keeps them
    /// looking as they did; choosing a layout then tidies them. Runs once per workspace
    /// file, before anything else is added to it, and is not an undo step.
    public func migrateLayoutsIfNeeded() {
        guard let database = persistence?.database, (try? database.metaValue("layoutVersion")) == nil else { return }
        let older = maps.values.filter { $0.layoutStyle != .free }
        if !older.isEmpty {
            perform("Free Placement") { tx in
                for map in older { tx.update(map) { $0.layoutStyle = .free } }
            }
            history.removeAll()
        }
        try? database.setMetaValue("layoutVersion", "2")
    }

    /// Saves pending changes immediately. Call before quitting.
    @discardableResult
    public func saveNow() -> Bool {
        persistence?.saveNow() ?? true
    }

    /// Replaces the workspace with `records` and rewrites the file. Not undoable.
    public func restore(from records: [(key: RecordKey, value: any EntityData)]) throws {
        replaceContents(with: records)
        try persistence?.saveEverything()
    }
}
