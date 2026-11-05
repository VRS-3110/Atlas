import Foundation

/// What the weekly review shows.
public struct WeeklyReview {
    /// A first-level branch of a map that nothing in has changed for a while.
    public struct StaleBranch: Identifiable {
        public var id: UUID { nodeID }
        public let mapID: UUID
        public let nodeID: UUID
        public let lastTouched: Date
        public let size: Int
    }

    public var interval: DateInterval
    public var completed: [Node] = []
    public var newSources: [Node] = []
    public var openQuestions: [Node] = []
    public var staleBranches: [StaleBranch] = []
    /// Focus time logged on tasks completed in the period, in seconds.
    public var focusSeconds: Double = 0
}

extension Workspace {
    /// The tag that marks a question as answered.
    public static let answeredTag = "answered"

    /// The review of the `days` days ending at `now`. A branch is stale when no node in it
    /// has changed for `staleDays` days.
    public func weeklyReview(now: Date, days: Int = 7, staleDays: Int = 14, calendar: Calendar = .current) -> WeeklyReview {
        let end = calendar.startOfDay(for: now).addingTimeInterval(86_400)
        let start = calendar.date(byAdding: .day, value: -days, to: end) ?? end
        let interval = DateInterval(start: start, end: end)
        var review = WeeklyReview(interval: interval)

        review.completed = taskNodes.filter { node in
            guard let task = node.task, task.status == .done, let done = task.completedAt else { return false }
            return interval.contains(done)
        }
        .sorted { ($0.task?.completedAt ?? .distantPast) > ($1.task?.completedAt ?? .distantPast) }
        review.focusSeconds = review.completed.reduce(0) { $0 + ($1.task?.focusSeconds ?? 0) }

        review.newSources = sourceNodes.filter { interval.contains($0.createdAt) && $0.inbox != .archived }
            .sorted { $0.createdAt > $1.createdAt }

        review.openQuestions = nodes.values.filter { $0.kind == .question && $0.inbox != .archived && !isAnswered($0) }
            .sorted { $0.createdAt < $1.createdAt }

        let staleBefore = calendar.date(byAdding: .day, value: -staleDays, to: now) ?? now
        let logged = lastLoggedDates(calendar: calendar)
        for map in sortedMaps {
            let tree = tree(of: map.id)
            for root in tree.roots {
                for branch in tree.children(of: root) {
                    let ids = [branch] + tree.descendants(of: branch)
                    let latest = max(ids.compactMap { nodes[$0]?.updatedAt }.max() ?? .distantPast,
                                     logged[branch] ?? .distantPast)
                    if latest < staleBefore {
                        review.staleBranches.append(.init(mapID: map.id, nodeID: branch, lastTouched: latest, size: ids.count))
                    }
                }
            }
        }
        review.staleBranches.sort { $0.lastTouched < $1.lastTouched }
        return review
    }

    /// A question is answered when tagged "answered", or when a claim or evidence node is
    /// linked to it (as a child on a map or by a relation).
    public func isAnswered(_ question: Node) -> Bool {
        if question.data.hasTag(Self.answeredTag) { return true }
        let answerKinds: Set<NodeKind> = [.claim, .evidence]
        for edge in edges(touching: question.id) {
            let other = edge.fromID == question.id ? edge.toID : edge.fromID
            if let kind = nodes[other]?.kind, answerKinds.contains(kind) { return true }
        }
        for map in maps(containing: question.id) {
            let tree = tree(of: map.id)
            if tree.children(of: question.id).contains(where: { nodes[$0].map { answerKinds.contains($0.kind) } == true }) {
                return true
            }
        }
        return false
    }

    public func markAnswered(_ questionID: UUID, _ answered: Bool = true) {
        guard let node = nodes[questionID] else { return }
        updateNode(node, answered ? "Mark Answered" : "Mark Unanswered") { data in
            if answered { data.addTags([Self.answeredTag]) } else { data.removeTag(Self.answeredTag) }
        }
    }

    /// Marks a stale branch as reviewed: today's log records that its top node was looked
    /// at, which takes the branch off the stale list without changing it.
    public func markReviewed(_ nodeID: UUID) {
        guard nodes[nodeID] != nil else { return }
        let key = PlannerCalendar.dayKey(clock())
        perform("Mark Reviewed") { tx in
            if let log = dayLogs.values.first(where: { $0.day == key }) {
                if !log.touchedNodeIDs.contains(nodeID) { tx.update(log) { $0.touchedNodeIDs.append(nodeID) } }
            } else {
                tx.insert(DayLogData(day: key, touchedNodeIDs: [nodeID], createdAt: clock()))
            }
        }
    }

    /// The last day each node appears in a day log.
    func lastLoggedDates(calendar: Calendar) -> [UUID: Date] {
        var result: [UUID: Date] = [:]
        for log in dayLogs.values {
            guard let date = PlannerCalendar.date(fromDayKey: log.day, calendar: calendar) else { continue }
            let end = date.addingTimeInterval(86_399)
            for id in log.touchedNodeIDs where (result[id] ?? .distantPast) < end { result[id] = end }
        }
        return result
    }
}
