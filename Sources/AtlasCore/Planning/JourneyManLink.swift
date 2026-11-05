import Foundation

/// The link with JourneyMan, the time tracker (github.com/VRS-3110/JourneyMan).
///
/// The two apps share one folder, ~/Documents/JourneyMan/atlas. Atlas writes `tasks.json`
/// there and reads `journeyman.json`; JourneyMan does the opposite. JOURNEYMAN.md describes
/// both files.
///
/// - Names, dates, priority and map go from Atlas to JourneyMan.
/// - Done goes both ways: whichever app changed it last wins.
/// - Time goes both ways without being counted twice: focus time logged here becomes
///   deep-work time in JourneyMan, and the time tracked in JourneyMan comes back as its own
///   total (`TaskInfo.journeyManMinutes`).
///
/// Nothing here touches files, so it can be tested. The app's `JourneyManSync` reads and
/// writes the folder.
public enum JourneyManLink {
    public static let format = 1
    public static let tasksFileName = "tasks.json"
    public static let journeyManFileName = "journeyman.json"
    public static let urlScheme = "atlas"

    /// ~/Documents/JourneyMan/atlas, beside the activity folder of JourneyMan's Mac helper.
    public static var defaultFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)
        return documents
            .appendingPathComponent("JourneyMan", isDirectory: true)
            .appendingPathComponent("atlas", isDirectory: true)
    }

    // MARK: - Links between the apps

    /// atlas://node/<id>: opens Atlas and reveals the node.
    public static func nodeURL(_ id: UUID) -> URL {
        URL(string: "\(urlScheme)://node/\(id.uuidString)")!
    }

    /// The node an atlas://node/<id> link points at.
    public static func nodeID(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == urlScheme, url.host?.lowercased() == "node" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    /// The JourneyMan page for the task made from a node, given the address JourneyMan runs
    /// at (it reports this in journeyman.json). Only web addresses are accepted.
    public static func journeyManURL(for nodeID: UUID, appURL: String) -> URL? {
        let trimmed = appURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !base.isEmpty, let url = URL(string: "\(base)#task/atlas:\(nodeID.uuidString)"),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// 80 → "1h 20m".
    public static func durationText(minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let h = total / 60, m = total % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    // MARK: - Dates

    /// ISO 8601 with milliseconds, the way JavaScript writes dates.
    static func makeFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    static func stamp(_ date: Date) -> String {
        makeFormatter().string(from: date)
    }

    /// Reads ISO 8601, with or without fractional seconds.
    static func date(from string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let f = makeFormatter()
        if let date = f.date(from: string) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }

    // MARK: - Atlas → JourneyMan: tasks.json

    public struct TaskFile: Codable, Equatable, Sendable {
        public var app: String
        public var format: Int
        public var exportedAt: String
        public var tasks: [TaskEntry]
    }

    public struct TaskEntry: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        /// todo, doing, done or cancelled.
        public var status: String
        /// When the status last changed (see `TaskInfo.lastStatusChange`).
        public var statusChangedAt: String?
        /// none, low, medium or high.
        public var priority: String
        public var due: String?
        public var scheduledStart: String?
        public var durationMinutes: Int
        public var completedAt: String?
        /// Focus time logged with the deep-work timer, to a tenth of a minute.
        public var focusMinutes: Double
        /// The first map the task is on, in the sidebar's order. Nil for planner-only tasks.
        public var map: MapRef?
        public var tags: [String]
        /// none, or inbox for a capture not yet triaged.
        public var inbox: String
        public var createdAt: String
        public var updatedAt: String
        /// atlas://node/<id>
        public var url: String
    }

    public struct MapRef: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
    }

    /// Every task except captures archived from the Inbox, oldest first (ties by id, so the
    /// file only changes when a task does).
    @MainActor
    public static func taskFile(from workspace: Workspace, exportedAt: Date) -> TaskFile {
        let formatter = makeFormatter()
        func text(_ date: Date?) -> String? { date.map { formatter.string(from: $0) } }
        let nodes = workspace.taskNodes.sorted {
            $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id.uuidString < $1.id.uuidString
        }
        var entries: [TaskEntry] = []
        for node in nodes where node.inbox != .archived {
            guard let task = node.task else { continue }
            let map = workspace.maps(containing: node.id).first
            entries.append(TaskEntry(
                id: node.id.uuidString,
                title: node.title,
                status: task.status.rawValue,
                statusChangedAt: text(task.lastStatusChange),
                priority: task.priority.rawValue,
                due: text(task.due),
                scheduledStart: text(task.scheduledStart),
                durationMinutes: task.durationMinutes,
                completedAt: text(task.completedAt),
                focusMinutes: (task.focusSeconds / 6).rounded() / 10,
                map: map.map { MapRef(id: $0.id.uuidString, name: $0.name) },
                tags: node.tags,
                inbox: node.inbox.rawValue,
                createdAt: formatter.string(from: node.createdAt),
                updatedAt: formatter.string(from: node.updatedAt),
                url: nodeURL(node.id).absoluteString
            ))
        }
        return TaskFile(app: "Atlas", format: Self.format, exportedAt: formatter.string(from: exportedAt), tasks: entries)
    }

    /// tasks.json as written: indented, with sorted keys.
    public static func encode(_ file: TaskFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(file)
    }

    // MARK: - JourneyMan → Atlas: journeyman.json

    public struct JourneyManFile: Codable, Equatable, Sendable {
        public var app: String
        public var format: Int?
        public var exportedAt: String?
        /// Where JourneyMan runs, for Open in JourneyMan.
        public var appUrl: String?
        public var tasks: [TaskUpdate]
    }

    public struct TaskUpdate: Codable, Equatable, Sendable {
        public var atlasId: String
        public var done: Bool
        /// When the task was last ticked or unticked in JourneyMan.
        public var doneChangedAt: String?
        /// Minutes tracked in JourneyMan itself (not counting focus time sent from Atlas).
        public var trackedMinutes: Double?
    }

    public enum LinkError: LocalizedError, Equatable {
        case notJourneyMan
        case newerFormat(Int)

        public var errorDescription: String? {
            switch self {
            case .notJourneyMan: "journeyman.json is not a file JourneyMan wrote."
            case .newerFormat(let v): "journeyman.json comes from a newer JourneyMan (format \(v)). Update Atlas to read it."
            }
        }
    }

    public static func decodeJourneyMan(_ data: Data) throws -> JourneyManFile {
        guard let file = try? JSONDecoder().decode(JourneyManFile.self, from: data), file.app == "JourneyMan" else {
            throw LinkError.notJourneyMan
        }
        if let version = file.format, version > Self.format { throw LinkError.newerFormat(version) }
        return file
    }

    public struct ApplyReport: Equatable, Sendable {
        public var completed = 0
        public var reopened = 0
        public var timeUpdated = 0

        public init() {}

        public var isEmpty: Bool { completed == 0 && reopened == 0 && timeUpdated == 0 }

        public var summary: String {
            var parts: [String] = []
            if completed > 0 { parts.append("\(completed) completed") }
            if reopened > 0 { parts.append("\(reopened) reopened") }
            if timeUpdated > 0 { parts.append("time updated on \(timeUpdated)") }
            return parts.isEmpty ? "no changes" : parts.joined(separator: ", ")
        }
    }

    /// Applies what JourneyMan did as one undoable step, “Update from JourneyMan”: done or not
    /// done where JourneyMan changed it after Atlas last did, and the time tracked there.
    /// Cancelled tasks and nodes that are gone or no longer tasks are left alone.
    @MainActor
    @discardableResult
    public static func apply(_ file: JourneyManFile, to workspace: Workspace) -> ApplyReport {
        var changes: [(node: Node, status: TaskStatus?, minutes: Double?)] = []
        for update in file.tasks {
            guard let id = UUID(uuidString: update.atlasId), let node = workspace.nodes[id],
                  let task = node.task, task.status != .cancelled else { continue }
            var status: TaskStatus?
            if update.done != (task.status == .done) {
                let theirs = date(from: update.doneChangedAt) ?? .distantPast
                let ours = task.lastStatusChange ?? node.createdAt
                if theirs > ours { status = update.done ? .done : .todo }
            }
            var minutes: Double?
            let tracked = max(0, update.trackedMinutes ?? 0)
            if abs(tracked - task.journeyManMinutes) >= 0.5 { minutes = tracked }
            if status != nil || minutes != nil {
                changes.append((node: node, status: status, minutes: minutes))
            }
        }
        var report = ApplyReport()
        guard !changes.isEmpty else { return report }
        let now = workspace.clock()
        workspace.perform("Update from JourneyMan") { tx in
            for change in changes {
                tx.update(change.node) { data in
                    guard var task = data.task else { return }
                    if let status = change.status { task.setStatus(status, at: now) }
                    if let minutes = change.minutes { task.journeyManMinutes = minutes }
                    data.task = task
                }
            }
        }
        for change in changes {
            if change.status == .done { report.completed += 1 }
            if change.status == .todo { report.reopened += 1 }
            if change.minutes != nil { report.timeUpdated += 1 }
        }
        return report
    }
}
