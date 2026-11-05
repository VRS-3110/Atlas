import Foundation

/// Calendar arithmetic for the planner. Everything uses the user's current calendar and
/// time zone unless a test passes its own.
public enum PlannerCalendar {
    /// The days of the week containing `date`, starting on the calendar's first weekday.
    public static func weekDays(containing date: Date, calendar: Calendar = .current) -> [Date] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else { return [calendar.startOfDay(for: date)] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week.start) }
    }

    /// `date` rounded to the nearest `minutes` (15 by default), for dropping blocks on a timeline.
    public static func snap(_ date: Date, toMinutes minutes: Int = 15, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        let offset = date.timeIntervalSince(start) / 60
        let snapped = (offset / Double(minutes)).rounded() * Double(minutes)
        return start.addingTimeInterval(snapped * 60)
    }

    public static func dayInterval(_ date: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .day, for: date) ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86_400)
    }

    /// `yyyy-MM-dd` in the calendar's time zone: the key of a day log.
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func date(fromDayKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

extension Workspace {

    // MARK: Task queries

    /// Open and finished tasks whose time block starts within `interval`, by start time.
    public func tasks(scheduledIn interval: DateInterval) -> [Node] {
        taskNodes.filter { node in
            guard let start = node.task?.scheduledStart, node.task?.status != .cancelled else { return false }
            return interval.contains(start) && start < interval.end
        }
        .sorted { ($0.task?.scheduledStart ?? .distantPast) < ($1.task?.scheduledStart ?? .distantPast) }
    }

    /// Open tasks due on the day of `date` that have no time block.
    public func unscheduledTasks(dueOn date: Date, calendar: Calendar = .current) -> [Node] {
        let day = PlannerCalendar.dayInterval(date, calendar: calendar)
        return taskNodes.filter { node in
            guard let task = node.task, task.status.isOpen, task.scheduledStart == nil, let due = task.due else { return false }
            return day.contains(due) && due < day.end
        }
    }

    /// Open tasks with no time block, most urgent first: by due date, then priority.
    public var unscheduledTasks: [Node] {
        taskNodes.filter { $0.task?.status.isOpen == true && $0.task?.scheduledStart == nil && $0.inbox != .archived }
            .sorted(by: Self.urgency)
    }

    /// Open tasks that are late: due before today, or with a time block that ended before
    /// today began.
    public func overdueTasks(now: Date, calendar: Calendar = .current) -> [Node] {
        let today = calendar.startOfDay(for: now)
        return taskNodes.filter { node in
            guard let task = node.task, task.status.isOpen, node.inbox != .archived else { return false }
            if let due = task.due, due < today { return true }
            if let end = task.scheduledEnd, end <= today { return true }
            return false
        }
        .sorted(by: Self.urgency)
    }

    static func urgency(_ a: Node, _ b: Node) -> Bool {
        let da = a.task?.due ?? .distantFuture, db = b.task?.due ?? .distantFuture
        if da != db { return da < db }
        let pa = a.task?.priority ?? .none, pb = b.task?.priority ?? .none
        if pa != pb { return pa > pb }
        return a.createdAt < b.createdAt
    }

    // MARK: Scheduling

    /// Puts a node on the timeline: it becomes a task if it is not one, and leaves the Inbox.
    public func schedule(_ nodeID: UUID, at start: Date, minutes: Int? = nil) {
        guard let node = nodes[nodeID] else { return }
        updateNode(node, node.task?.scheduledStart == nil ? "Schedule" : "Reschedule") { data in
            var task = data.task ?? TaskInfo()
            task.scheduledStart = start
            if let minutes { task.durationMinutes = max(5, minutes) }
            data.task = task
            if data.inbox != .none { data.inbox = .none }
        }
    }

    public func unschedule(_ nodeID: UUID) {
        guard let node = nodes[nodeID], node.task?.scheduledStart != nil else { return }
        updateNode(node, "Unschedule") { $0.task?.scheduledStart = nil }
    }

    public func setDuration(_ minutes: Int, of nodeID: UUID, coalesce: String? = nil) {
        guard let node = nodes[nodeID], node.task != nil else { return }
        updateNode(node, "Change Duration", coalesce: coalesce) { $0.task?.durationMinutes = max(5, minutes) }
    }

    /// Sets a task's status, stamping when it was completed.
    public func setTaskStatus(_ status: TaskStatus, of nodeIDs: some Sequence<UUID>) {
        let now = clock()
        perform(status == .done ? "Complete Task" : "Change Status") { tx in
            for id in nodeIDs {
                guard let node = nodes[id], node.task != nil else { continue }
                tx.update(node) { data in
                    guard var task = data.task else { return }
                    task.status = status
                    task.completedAt = status == .done ? (task.completedAt ?? now) : nil
                    data.task = task
                }
            }
        }
    }

    /// Creates a task that lives in the planner (on no map).
    @discardableResult
    public func createTask(_ title: String, scheduledAt start: Date? = nil, minutes: Int = 30, due: Date? = nil) -> Node {
        var data = NodeData(title: title, kind: .task, createdAt: clock())
        data.task = TaskInfo(due: due, scheduledStart: start, durationMinutes: minutes)
        return createNode(data, actionName: "New Task")
    }

    /// Adds deep-work time to a task.
    public func addFocusTime(_ seconds: TimeInterval, to nodeID: UUID) {
        guard seconds >= 1, let node = nodes[nodeID], node.task != nil else { return }
        updateNode(node, "Log Focus Time") { $0.task?.focusSeconds += seconds.rounded() }
    }

    // MARK: Daily log

    public func dayLog(for date: Date, calendar: Calendar = .current) -> DayLog? {
        let key = PlannerCalendar.dayKey(date, calendar: calendar)
        return dayLogs.values.first { $0.day == key }
    }

    /// Edits the notes of a day's log, creating the log if needed. Typing coalesces.
    public func setDayLogBody(_ body: String, for date: Date, calendar: Calendar = .current) {
        let key = PlannerCalendar.dayKey(date, calendar: calendar)
        perform("Edit Daily Log", coalesce: "daylog-\(key)") { tx in
            if let log = dayLogs.values.first(where: { $0.day == key }) {
                tx.update(log) { $0.body = body }
            } else {
                tx.insert(DayLogData(day: key, body: body, createdAt: clock()))
            }
        }
    }

    /// The nodes a day's log links to, skipping ones deleted since.
    public func touchedNodes(on date: Date, calendar: Calendar = .current) -> [Node] {
        (dayLog(for: date, calendar: calendar)?.touchedNodeIDs ?? []).compactMap { nodes[$0] }
    }

    /// Called as each edit is committed: adds the nodes it touched (directly, or by moving
    /// them on a map) to today's log, within the same undo step.
    func recordTouches(in tx: Transaction) {
        var ids: [UUID] = []
        var seen = Set<UUID>()
        for key in tx.touchOrder {
            let id: UUID?
            switch key.kind {
            case .node: id = key.id
            case .placement: id = placements[key.id]?.data.nodeID
            default: id = nil
            }
            guard let id, nodes[id] != nil, seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        guard !ids.isEmpty else { return }
        let key = PlannerCalendar.dayKey(clock())
        if let log = dayLogs.values.first(where: { $0.day == key }) {
            let missing = ids.filter { !log.touchedNodeIDs.contains($0) }
            if !missing.isEmpty { tx.update(log) { $0.touchedNodeIDs += missing } }
        } else {
            tx.insert(DayLogData(day: key, touchedNodeIDs: ids, createdAt: clock()))
        }
    }
}
