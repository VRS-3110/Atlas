import Foundation

/// What a node represents. Each kind has its own shape, icon and colour on the canvas.
public enum NodeKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case idea
    case question
    case hypothesis
    case claim
    case evidence
    case source
    case quote
    case task
    case note

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .idea: "Idea"
        case .question: "Question"
        case .hypothesis: "Hypothesis"
        case .claim: "Claim"
        case .evidence: "Evidence"
        case .source: "Source"
        case .quote: "Quote"
        case .task: "Task"
        case .note: "Note"
        }
    }

    public var pluralTitle: String {
        switch self {
        case .hypothesis: "Hypotheses"
        case .evidence: "Evidence"
        default: title + "s"
        }
    }
}

/// A small semantic palette; the app maps these to system colours so they adapt to
/// light and dark mode.
public enum NodeColor: String, Codable, CaseIterable, Sendable, Identifiable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

/// Where a node sits in the capture workflow.
public enum InboxState: String, Codable, Sendable {
    /// A normal node (on maps, in the sources library or the planner).
    case none
    /// Captured but not yet triaged.
    case inbox
    /// Triaged away without being used.
    case archived
}

/// A link from a node to a source node, optionally pinned to a page.
public struct Citation: Codable, Equatable, Hashable, Sendable {
    public var sourceID: UUID
    public var page: String

    public init(sourceID: UUID, page: String = "") {
        self.sourceID = sourceID
        self.page = page
    }

    enum CodingKeys: String, CodingKey { case sourceID, page }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try c.decode(UUID.self, forKey: .sourceID)
        page = c.lenient(.page, "")
    }
}

/// A file copied into the workspace's attachment folder.
public struct Attachment: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// File name inside the attachments folder (unique, derived from `id`).
    public var storedName: String
    /// The name the file had when it was added.
    public var originalName: String
    /// Uniform type identifier, e.g. `com.adobe.pdf`.
    public var contentType: String
    public var byteCount: Int64
    public var addedAt: Date

    public init(id: UUID = UUID(), storedName: String, originalName: String,
                contentType: String, byteCount: Int64, addedAt: Date = .now) {
        self.id = id
        self.storedName = storedName
        self.originalName = originalName
        self.contentType = contentType
        self.byteCount = byteCount
        self.addedAt = addedAt
    }
}

/// Bibliographic metadata carried by a node of kind `.source`. The title is the node title
/// and the notes are the node body, so renaming a source anywhere renames it everywhere.
public struct SourceInfo: Codable, Equatable, Sendable {
    /// BibTeX entry type (`article`, `book`, `inproceedings`, `misc`, ...).
    public var entryType: String
    /// Authors as written, preferably "Last, First".
    public var authors: [String]
    public var year: Int?
    public var publisher: String
    /// Journal, proceedings or other container title.
    public var container: String
    public var volume: String
    public var issue: String
    public var pages: String
    public var url: String
    public var doi: String
    public var isbn: String
    public var citationKey: String
    /// The attachment (PDF or other file) that holds the source itself.
    public var attachmentID: UUID?
    /// BibTeX fields Atlas does not model, kept so import/export round-trips.
    public var extraFields: [String: String]

    public init(entryType: String = "misc", authors: [String] = [], year: Int? = nil,
                publisher: String = "", container: String = "", volume: String = "",
                issue: String = "", pages: String = "", url: String = "", doi: String = "",
                isbn: String = "", citationKey: String = "", attachmentID: UUID? = nil,
                extraFields: [String: String] = [:]) {
        self.entryType = entryType
        self.authors = authors
        self.year = year
        self.publisher = publisher
        self.container = container
        self.volume = volume
        self.issue = issue
        self.pages = pages
        self.url = url
        self.doi = doi
        self.isbn = isbn
        self.citationKey = citationKey
        self.attachmentID = attachmentID
        self.extraFields = extraFields
    }

    enum CodingKeys: String, CodingKey {
        case entryType, authors, year, publisher, container, volume, issue, pages, url, doi, isbn,
             citationKey, attachmentID, extraFields
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entryType = c.lenient(.entryType, "misc")
        authors = c.lenient(.authors, [])
        year = c.optional(.year)
        publisher = c.lenient(.publisher, "")
        container = c.lenient(.container, "")
        volume = c.lenient(.volume, "")
        issue = c.lenient(.issue, "")
        pages = c.lenient(.pages, "")
        url = c.lenient(.url, "")
        doi = c.lenient(.doi, "")
        isbn = c.lenient(.isbn, "")
        citationKey = c.lenient(.citationKey, "")
        attachmentID = c.optional(.attachmentID)
        extraFields = c.lenient(.extraFields, [:])
    }
}

public enum TaskStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case todo
    case doing
    case done
    case cancelled

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .todo: "To Do"
        case .doing: "In Progress"
        case .done: "Done"
        case .cancelled: "Cancelled"
        }
    }

    public var isOpen: Bool { self == .todo || self == .doing }
}

public enum TaskPriority: String, Codable, CaseIterable, Sendable, Identifiable, Comparable {
    case none
    case low
    case medium
    case high

    public var id: String { rawValue }
    public var title: String { self == .none ? "None" : rawValue.capitalized }

    public var rank: Int {
        switch self {
        case .none: 0
        case .low: 1
        case .medium: 2
        case .high: 3
        }
    }

    public static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool { lhs.rank < rhs.rank }
}

/// Planning state for a node that has been turned into a task.
public struct TaskInfo: Codable, Equatable, Sendable {
    public var status: TaskStatus
    public var priority: TaskPriority
    public var due: Date?
    /// Start of the scheduled time block, if the task is on the timeline.
    public var scheduledStart: Date?
    /// Length of the scheduled time block in minutes.
    public var durationMinutes: Int
    public var completedAt: Date?
    /// Focus time logged with the deep-work timer, in seconds.
    public var focusSeconds: Double

    public init(status: TaskStatus = .todo, priority: TaskPriority = .none, due: Date? = nil,
                scheduledStart: Date? = nil, durationMinutes: Int = 30,
                completedAt: Date? = nil, focusSeconds: Double = 0) {
        self.status = status
        self.priority = priority
        self.due = due
        self.scheduledStart = scheduledStart
        self.durationMinutes = durationMinutes
        self.completedAt = completedAt
        self.focusSeconds = focusSeconds
    }

    enum CodingKeys: String, CodingKey {
        case status, priority, due, scheduledStart, durationMinutes, completedAt, focusSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.lenient(.status, .todo)
        priority = c.lenient(.priority, .none)
        due = c.optional(.due)
        scheduledStart = c.optional(.scheduledStart)
        durationMinutes = c.lenient(.durationMinutes, 30)
        completedAt = c.optional(.completedAt)
        focusSeconds = c.lenient(.focusSeconds, 0)
    }

    public var scheduledEnd: Date? {
        scheduledStart.map { $0.addingTimeInterval(Double(durationMinutes) * 60) }
    }
}

/// The single record type behind everything on a map, in the inbox, in the sources
/// library and in the planner.
public struct NodeData: EntityData {
    public static let entityKind = EntityKind.node

    public var title: String
    /// Markdown.
    public var body: String
    public var kind: NodeKind
    public var tags: [String]
    /// Overrides the kind's default colour when set.
    public var color: NodeColor?
    public var createdAt: Date
    public var updatedAt: Date
    public var inbox: InboxState
    /// Sources this node cites (a quote cites exactly one source, with a page).
    public var citations: [Citation]
    /// Present on source nodes.
    public var source: SourceInfo?
    /// Present once the node has been turned into a task.
    public var task: TaskInfo?
    public var attachments: [Attachment]
    /// A web address captured with the node (for links that are not full sources).
    public var link: String?

    public init(title: String = "", body: String = "", kind: NodeKind = .idea,
                tags: [String] = [], color: NodeColor? = nil, createdAt: Date = .now,
                inbox: InboxState = .none, citations: [Citation] = [],
                source: SourceInfo? = nil, task: TaskInfo? = nil,
                attachments: [Attachment] = [], link: String? = nil) {
        self.title = title
        self.body = body
        self.kind = kind
        self.tags = tags
        self.color = color
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.inbox = inbox
        self.citations = citations
        self.source = source ?? (kind == .source ? SourceInfo() : nil)
        self.task = task ?? (kind == .task ? TaskInfo() : nil)
        self.attachments = attachments
        self.link = link
    }

    public mutating func didModify(at date: Date) { updatedAt = date }

    public func hasSameContent(as other: NodeData) -> Bool {
        var other = other
        other.updatedAt = updatedAt
        return self == other
    }

    enum CodingKeys: String, CodingKey {
        case title, body, kind, tags, color, createdAt, updatedAt, inbox, citations, source, task,
             attachments, link
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.lenient(.title, "")
        body = c.lenient(.body, "")
        kind = c.lenient(.kind, .idea)
        tags = c.lenient(.tags, [])
        color = c.optional(.color)
        createdAt = c.lenient(.createdAt, Date(timeIntervalSinceReferenceDate: 0))
        updatedAt = c.lenient(.updatedAt, createdAt)
        inbox = c.lenient(.inbox, .none)
        citations = c.lenient(.citations, [])
        source = c.optional(.source)
        task = c.optional(.task)
        attachments = c.lenient(.attachments, [])
        link = c.optional(.link)
    }

    /// Changes the kind and creates the facet that kind relies on.
    public mutating func setKind(_ newKind: NodeKind) {
        kind = newKind
        if newKind == .source, source == nil { source = SourceInfo() }
        if newKind == .task, task == nil { task = TaskInfo() }
    }

    /// Whether a tag is present, ignoring case.
    public func hasTag(_ tag: String) -> Bool {
        tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    /// Adds tags, normalising them and skipping duplicates (case-insensitive).
    public mutating func addTags(_ newTags: [String]) {
        for raw in newTags {
            let tag = Tags.normalize(raw)
            guard !tag.isEmpty, !hasTag(tag) else { continue }
            tags.append(tag)
        }
    }

    public mutating func removeTag(_ tag: String) {
        tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    /// Text used for searching: title, body, tags and source metadata.
    public var searchableText: String {
        var parts = [title, body, tags.joined(separator: " ")]
        if let s = source {
            parts += s.authors + [s.container, s.publisher, s.citationKey, s.doi]
        }
        return parts.joined(separator: " ")
    }
}

public enum Tags {
    /// Trims whitespace and a leading `#`, and collapses inner whitespace to single dashes.
    public static func normalize(_ raw: String) -> String {
        var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while tag.hasPrefix("#") { tag.removeFirst() }
        let words = tag.split(whereSeparator: { $0.isWhitespace })
        return words.joined(separator: "-")
    }

    /// Splits a comma- or newline-separated list typed by the user into tags.
    public static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
    }
}
