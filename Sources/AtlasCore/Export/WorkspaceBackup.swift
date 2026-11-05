import Foundation

/// A whole workspace in one portable JSON file: every record, plus the attached files
/// (base64), so a backup restores on another Mac with its PDFs.
///
/// ```json
/// { "format": "atlas-workspace", "version": 1, "createdAt": "2026-11-05T09:00:00Z",
///   "records": [ { "kind": "node", "id": "…", "data": { … } } ],
///   "attachments": [ { "name": "….pdf", "data": "JVBERi0…" } ] }
/// ```
///
/// Record `data` is the same JSON the database stores, so a backup reads back exactly.
public enum WorkspaceBackup {
    public static let format = "atlas-workspace"
    public static let version = 1
    public static let fileExtension = "atlasbackup"

    public enum BackupError: LocalizedError {
        case notABackup
        case newerVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .notABackup: "This file is not an Atlas workspace backup."
            case .newerVersion(let v): "This backup was made by a newer version of Atlas (format \(v))."
            }
        }
    }

    /// What a backup holds, read without changing anything.
    public struct Contents {
        public var createdAt: Date?
        public var records: [(key: RecordKey, value: any EntityData)]
        /// Stored file name → bytes.
        public var attachments: [String: Data]
        /// Records whose kind or fields this version cannot read; they are left out.
        public var skippedRecords: Int

        public var mapCount: Int { records.filter { $0.key.kind == .map }.count }
        public var nodeCount: Int { records.filter { $0.key.kind == .node }.count }
    }

    public struct RestoreReport: Sendable {
        public var records = 0
        public var attachments = 0
        public var skippedRecords = 0
        /// Where the workspace was copied before it was replaced.
        public var safetyCopy: URL?
    }

    static func iso8601() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    /// Encodes records and attachments. Attachments that cannot be read are skipped.
    public static func encode(records: [(key: RecordKey, value: any EntityData)],
                              attachments: [String: Data], createdAt: Date = Date()) throws -> Data {
        let order: [EntityKind] = [.map, .node, .placement, .edge, .frame, .dayLog]
        let sorted = records.sorted {
            let a = order.firstIndex(of: $0.key.kind) ?? 0, b = order.firstIndex(of: $1.key.kind) ?? 0
            return a != b ? a < b : $0.key.id.uuidString < $1.key.id.uuidString
        }
        var recordObjects: [[String: Any]] = []
        recordObjects.reserveCapacity(sorted.count)
        for record in sorted {
            let json = try JSONSerialization.jsonObject(with: RecordCodec.encode(record.value), options: [.fragmentsAllowed])
            recordObjects.append(["kind": record.key.kind.rawValue, "id": record.key.id.uuidString, "data": json])
        }
        let files = attachments.keys.sorted().map { ["name": $0, "data": attachments[$0]!.base64EncodedString()] }
        let root: [String: Any] = [
            "format": format,
            "version": version,
            "createdAt": iso8601().string(from: createdAt),
            "records": recordObjects,
            "attachments": files,
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    public static func decode(_ data: Data) throws -> Contents {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["format"] as? String == format else { throw BackupError.notABackup }
        let fileVersion = root["version"] as? Int ?? 1
        guard fileVersion <= version else { throw BackupError.newerVersion(fileVersion) }
        var contents = Contents(createdAt: (root["createdAt"] as? String).flatMap { iso8601().date(from: $0) },
                                records: [], attachments: [:], skippedRecords: 0)
        var seen = Set<RecordKey>()
        for object in root["records"] as? [[String: Any]] ?? [] {
            guard let kind = (object["kind"] as? String).flatMap(EntityKind.init(rawValue:)),
                  let id = (object["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let json = object["data"],
                  let bytes = try? JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed]),
                  let value = try? RecordCodec.decode(kind: kind, from: bytes) else {
                contents.skippedRecords += 1
                continue
            }
            let key = RecordKey(kind: kind, id: id)
            guard seen.insert(key).inserted else { continue }
            contents.records.append((key, value))
        }
        for file in root["attachments"] as? [[String: Any]] ?? [] {
            guard let name = file["name"] as? String, isSafeFileName(name),
                  let encoded = file["data"] as? String, let bytes = Data(base64Encoded: encoded) else { continue }
            contents.attachments[name] = bytes
        }
        return contents
    }

    /// Attachment names are plain file names; anything that could leave the folder is refused.
    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\") && name != "." && name != ".."
            && !name.hasPrefix(".")
    }
}

extension Workspace {
    /// The workspace as a portable backup, with its attached files.
    public func backupData(createdAt: Date = Date()) throws -> Data {
        var files: [String: Data] = [:]
        for node in nodes.values {
            for attachment in node.attachments where files[attachment.storedName] == nil {
                if let url = url(of: attachment), let bytes = try? Data(contentsOf: url) {
                    files[attachment.storedName] = bytes
                }
            }
        }
        return try WorkspaceBackup.encode(records: allRecords(), attachments: files, createdAt: createdAt)
    }

    /// Replaces the whole workspace with a backup's contents. The current workspace is first
    /// copied to `Backups/` so a mistaken restore can be undone by hand; the restore itself
    /// clears undo history. Attached files are written into the Attachments folder (files
    /// already there are kept).
    @discardableResult
    public func restoreBackup(_ contents: WorkspaceBackup.Contents) throws -> WorkspaceBackup.RestoreReport {
        var report = WorkspaceBackup.RestoreReport()
        report.safetyCopy = try persistence?.makeSafetyCopy()
        if let folder = attachmentsFolder, !contents.attachments.isEmpty {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, bytes) in contents.attachments {
                try bytes.write(to: folder.appendingPathComponent(name), options: .atomic)
                report.attachments += 1
            }
        }
        try restore(from: contents.records)
        report.records = contents.records.count
        report.skippedRecords = contents.skippedRecords
        return report
    }
}

extension PersistenceController {
    /// Copies the database to `Backups/Before-Restore-<time>.sqlite (outside the daily pruning)`.
    func makeSafetyCopy() throws -> URL {
        let folder = database.url.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let destination = folder.appendingPathComponent("Before-Restore-\(formatter.string(from: Date())).sqlite")
        saveNow()
        try database.backup(to: destination)
        return destination
    }
}
