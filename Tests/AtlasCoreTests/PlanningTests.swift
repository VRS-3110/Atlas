import Foundation
import Testing
@testable import AtlasCore

@MainActor
@Suite("Planning")
struct PlanningTests {
    /// A fixed calendar so tests do not depend on the machine's time zone.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2 // Monday
        return c
    }()

    static func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
    }

    @Test func calendarHelpers() {
        let wednesday = Self.date(4, 15)
        let week = PlannerCalendar.weekDays(containing: wednesday, calendar: Self.calendar)
        #expect(week.count == 7 && week.first == Self.date(2) && week.last == Self.date(8))
        #expect(PlannerCalendar.snap(Self.date(4, 9, 8), calendar: Self.calendar) == Self.date(4, 9, 15))
        #expect(PlannerCalendar.snap(Self.date(4, 9, 7), calendar: Self.calendar) == Self.date(4, 9, 0))
        #expect(PlannerCalendar.dayKey(Self.date(4, 23, 59), calendar: Self.calendar) == "2026-03-04")
        #expect(PlannerCalendar.date(fromDayKey: "2026-03-04", calendar: Self.calendar) == Self.date(4))
    }

    @Test func schedulingMakesTasksAndLeavesTheInbox() {
        let f = Fixture()
        let w = f.workspace
        let item = w.capture("Call the archive")!
        w.schedule(item.id, at: Self.date(4, 10), minutes: 45)
        #expect(item.task?.scheduledStart == Self.date(4, 10) && item.task?.durationMinutes == 45 && item.inbox == .none)
        #expect(w.history.undoActionName == "Schedule")
        let day = PlannerCalendar.dayInterval(Self.date(4), calendar: Self.calendar)
        #expect(w.tasks(scheduledIn: day).map(\.id) == [item.id])
        w.schedule(item.id, at: Self.date(5, 9))
        #expect(w.history.undoActionName == "Reschedule" && item.task?.durationMinutes == 45)
        #expect(w.tasks(scheduledIn: day).isEmpty)
        w.setDuration(3, of: item.id)
        #expect(item.task?.durationMinutes == 5)
        w.unschedule(item.id)
        #expect(item.task?.scheduledStart == nil && w.unscheduledTasks.map(\.id) == [item.id])
    }

    @Test func statusStampsCompletion() {
        let f = Fixture()
        let w = f.workspace
        let task = w.createTask("Write intro")
        f.clock.advance(60)
        w.setTaskStatus(.done, of: [task.id])
        #expect(task.task?.completedAt == f.clock.now)
        f.clock.advance(60)
        w.setTaskStatus(.done, of: [task.id]) // stays at the first completion
        #expect(task.task?.completedAt == f.clock.now.addingTimeInterval(-60))
        w.setTaskStatus(.todo, of: [task.id])
        #expect(task.task?.completedAt == nil)
        w.addFocusTime(1500.4, to: task.id)
        w.addFocusTime(0.5, to: task.id) // under a second is ignored
        #expect(task.task?.focusSeconds == 1500)
    }

    @Test func overdueAndUnscheduledLists() {
        let f = Fixture()
        let w = f.workspace
        let now = Self.date(10, 12)
        let late = w.createTask("Late", due: Self.date(8))
        let missed = w.createTask("Missed block", scheduledAt: Self.date(9, 9))
        let future = w.createTask("Future", due: Self.date(20))
        let urgent = w.createTask("Urgent")
        w.updateNode(urgent, "Edit") { $0.task?.priority = .high }
        let done = w.createTask("Done", due: Self.date(1))
        w.setTaskStatus(.done, of: [done.id])
        #expect(Set(w.overdueTasks(now: now, calendar: Self.calendar).map(\.id)) == [late.id, missed.id])
        // Unscheduled: by due date, then priority.
        #expect(w.unscheduledTasks.map(\.id) == [late.id, future.id, urgent.id])
        #expect(w.unscheduledTasks(dueOn: Self.date(20, 18), calendar: Self.calendar).map(\.id) == [future.id])
    }

    @Test func dailyLogRecordsTouchedNodesWithinTheStep() {
        let f = Fixture()
        let w = f.workspace
        w.tracksDailyLog = true
        f.clock.now = Self.date(4, 9)
        w.updateNode(f.node(f.a)!, "Rename") { $0.title = "A2" }
        w.moveNodes([f.b], by: CGSize(width: 10, height: 0), in: f.map.id)
        w.updateNode(f.node(f.a)!, "Rename") { $0.title = "A3" }
        let log = w.dayLog(for: Self.date(4), calendar: Self.calendar)
        #expect(log?.touchedNodeIDs == [f.a, f.b])
        #expect(w.history.undoStack.count == 3)
        // Undoing the step that created the log removes it again.
        w.undo(); w.undo(); w.undo()
        #expect(w.dayLog(for: Self.date(4), calendar: Self.calendar) == nil)
        w.setDayLogBody("Notes", for: Self.date(4), calendar: Self.calendar)
        w.setDayLogBody("Notes more", for: Self.date(4), calendar: Self.calendar)
        #expect(w.dayLog(for: Self.date(4), calendar: Self.calendar)?.body == "Notes more")
        #expect(w.history.undoActionName == "Edit Daily Log")
        // Editing the log touches no node, so nothing is listed.
        #expect(w.touchedNodes(on: Self.date(4), calendar: Self.calendar).isEmpty)
    }

    @Test func weeklyReviewSummarisesThePeriod() {
        let f = Fixture()
        let w = f.workspace
        f.clock.now = Self.date(1)
        let oldSource = w.addSource(title: "Old")
        let stale = w.addChild(to: f.root, in: f.map.id, data: NodeData(title: "Quiet branch", createdAt: f.clock.now))
        f.clock.now = Self.date(9, 10)
        let newSource = w.addSource(title: "New")
        let task = w.createTask("Done this week")
        w.setTaskStatus(.done, of: [task.id])
        w.addFocusTime(600, to: task.id)
        let open = w.addChild(to: f.a, in: f.map.id, data: NodeData(title: "Why?", kind: .question))
        let answered = w.addChild(to: f.a, in: f.map.id, data: NodeData(title: "How?", kind: .question))
        w.addChild(to: answered.id, in: f.map.id, data: NodeData(title: "Because", kind: .evidence))
        let tagged = w.createNode(NodeData(title: "Tagged?", kind: .question))
        w.markAnswered(tagged.id)
        // Touch A's and B's branches; the new branch stays quiet since day 1.
        w.updateNode(f.node(f.a1)!, "Edit") { $0.title = "A1!" }
        w.updateNode(f.node(f.b)!, "Edit") { $0.title = "B!" }

        let review = w.weeklyReview(now: Self.date(9, 12), staleDays: 7, calendar: Self.calendar)
        #expect(review.completed.map(\.id) == [task.id])
        #expect(review.focusSeconds == 600)
        #expect(review.newSources.map(\.id) == [newSource.id])
        #expect(!review.newSources.contains { $0.id == oldSource.id })
        #expect(review.openQuestions.map(\.id) == [open.id])
        #expect(review.staleBranches.map(\.nodeID) == [stale.id])
        #expect(review.staleBranches.first?.mapID == f.map.id)

        w.markReviewed(stale.id)
        #expect(w.weeklyReview(now: Self.date(9, 12), staleDays: 7, calendar: Self.calendar).staleBranches.isEmpty)
        #expect(w.history.undoActionName == "Mark Reviewed")
    }
}
