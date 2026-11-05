import Foundation
import Testing
@testable import AtlasCore

@MainActor
@Suite("JourneyMan link")
struct JourneyManLinkTests {
    /// journeyman.json as JourneyMan would write it.
    static func journeyMan(_ updates: [JourneyManLink.TaskUpdate]) -> JourneyManLink.JourneyManFile {
        JourneyManLink.JourneyManFile(app: "JourneyMan", format: 1, exportedAt: nil,
                                      appUrl: "http://localhost:8000/", tasks: updates)
    }

    @Test func statusChangesAreStamped() {
        let f = Fixture()
        let w = f.workspace
        let task = w.createTask("Write intro")
        #expect(task.task?.statusChangedAt == nil)
        f.clock.advance(60)
        w.setTaskStatus(.doing, of: [task.id])
        #expect(task.task?.statusChangedAt == f.clock.now)
        f.clock.advance(60)
        w.setTaskStatus(.doing, of: [task.id]) // the same status changes nothing
        #expect(task.task?.statusChangedAt == f.clock.now.addingTimeInterval(-60))
        w.setTaskStatus(.done, of: [task.id])
        #expect(task.task?.lastStatusChange == f.clock.now && task.task?.completedAt == f.clock.now)
    }

    @Test func olderTasksStillDecode() throws {
        let json = #"{"status":"done","priority":"low","durationMinutes":30,"focusSeconds":60,"completedAt":10}"#
        let task = try JSONDecoder().decode(TaskInfo.self, from: Data(json.utf8))
        #expect(task.statusChangedAt == nil && task.journeyManMinutes == 0)
        #expect(task.lastStatusChange == Date(timeIntervalSinceReferenceDate: 10))
    }

    @Test func exportsTasksWithTheirMap() throws {
        let f = Fixture()
        let w = f.workspace
        let a = try #require(f.node(f.a))
        w.updateNode(a, "Make Task") { $0.task = TaskInfo(priority: .high, focusSeconds: 1500) }
        let planner = w.createTask("Call the archive", scheduledAt: f.clock.now, minutes: 45)
        let archived = w.createTask("Old capture")
        w.updateNode(archived, "Archive") { $0.inbox = .archived }

        let file = JourneyManLink.taskFile(from: w, exportedAt: f.clock.now)
        #expect(file.app == "Atlas" && file.format == 1)
        #expect(file.tasks.count == 2)
        let onMap = try #require(file.tasks.first { $0.id == f.a.uuidString })
        #expect(onMap.title == "A" && onMap.status == "todo" && onMap.priority == "high")
        #expect(onMap.map == JourneyManLink.MapRef(id: f.map.id.uuidString, name: "Test"))
        #expect(onMap.focusMinutes == 25)
        #expect(onMap.url == "atlas://node/\(f.a.uuidString)")
        let loose = try #require(file.tasks.first { $0.id == planner.id.uuidString })
        #expect(loose.map == nil && loose.durationMinutes == 45)
        #expect(JourneyManLink.date(from: loose.scheduledStart) == f.clock.now)

        // What is written reads back the same.
        let back = try JSONDecoder().decode(JourneyManLink.TaskFile.self, from: JourneyManLink.encode(file))
        #expect(back == file)
    }

    @Test func appliesDoneAndTimeFromJourneyMan() {
        let f = Fixture()
        let w = f.workspace
        let task = w.createTask("Draft chapter")
        f.clock.advance(60)
        let ticked = JourneyManLink.stamp(f.clock.now)
        f.clock.advance(5)
        let file = Self.journeyMan([.init(atlasId: task.id.uuidString, done: true, doneChangedAt: ticked, trackedMinutes: 42)])
        let report = JourneyManLink.apply(file, to: w)
        #expect(report.completed == 1 && report.timeUpdated == 1)
        #expect(task.task?.status == .done && task.task?.journeyManMinutes == 42)
        #expect(task.task?.statusChangedAt == f.clock.now)
        #expect(w.history.undoActionName == "Update from JourneyMan")
        // The same file again changes nothing, and adds no undo step.
        #expect(JourneyManLink.apply(file, to: w).isEmpty)
        w.undo()
        #expect(task.task?.status == .todo && task.task?.journeyManMinutes == 0)
    }

    @Test func theLaterStatusChangeWins() {
        let f = Fixture()
        let w = f.workspace
        let task = w.createTask("Draft chapter")
        let earlier = JourneyManLink.stamp(f.clock.now.addingTimeInterval(10))
        f.clock.advance(60)
        w.setTaskStatus(.done, of: [task.id]) // here, after JourneyMan's change
        var report = JourneyManLink.apply(Self.journeyMan([.init(atlasId: task.id.uuidString, done: false, doneChangedAt: earlier, trackedMinutes: nil)]), to: w)
        #expect(report.isEmpty && task.task?.status == .done)

        let later = JourneyManLink.stamp(f.clock.now.addingTimeInterval(30))
        report = JourneyManLink.apply(Self.journeyMan([.init(atlasId: task.id.uuidString, done: false, doneChangedAt: later, trackedMinutes: nil)]), to: w)
        #expect(report.reopened == 1 && task.task?.status == .todo && task.task?.completedAt == nil)

        // Doing is not done, so "not done" in JourneyMan leaves it as it is.
        w.setTaskStatus(.doing, of: [task.id])
        let latest = JourneyManLink.stamp(f.clock.now.addingTimeInterval(90))
        report = JourneyManLink.apply(Self.journeyMan([.init(atlasId: task.id.uuidString, done: false, doneChangedAt: latest, trackedMinutes: nil)]), to: w)
        #expect(report.isEmpty && task.task?.status == .doing)
    }

    @Test func cancelledAndUnknownTasksAreLeftAlone() {
        let f = Fixture()
        let w = f.workspace
        let task = w.createTask("Dropped idea")
        w.setTaskStatus(.cancelled, of: [task.id])
        let later = JourneyManLink.stamp(f.clock.now.addingTimeInterval(600))
        let report = JourneyManLink.apply(Self.journeyMan([
            .init(atlasId: task.id.uuidString, done: true, doneChangedAt: later, trackedMinutes: 30),
            .init(atlasId: UUID().uuidString, done: true, doneChangedAt: later, trackedMinutes: 30),
            .init(atlasId: "not-a-uuid", done: true, doneChangedAt: later, trackedMinutes: 30),
            .init(atlasId: f.b.uuidString, done: true, doneChangedAt: later, trackedMinutes: 30), // not a task
        ]), to: w)
        #expect(report.isEmpty && task.task?.status == .cancelled)
    }

    @Test func readsJavaScriptDatesAndRejectsOtherFiles() throws {
        let json = #"""
        {"app":"JourneyMan","format":1,"exportedAt":"2026-11-05T09:30:00.000Z","appUrl":"http://localhost:8000/",
         "tasks":[{"atlasId":"6F1C2B9E-0A57-4D7B-9E1A-1B2C3D4E5F60","done":true,"doneChangedAt":"2026-11-05T09:30:00.250Z","trackedMinutes":30}]}
        """#
        let file = try JourneyManLink.decodeJourneyMan(Data(json.utf8))
        #expect(file.tasks.count == 1 && file.appUrl == "http://localhost:8000/" && file.tasks[0].trackedMinutes == 30)
        let withMillis = try #require(JourneyManLink.date(from: "2026-11-05T09:30:00.250Z"))
        let plain = try #require(JourneyManLink.date(from: "2026-11-05T09:30:00Z"))
        #expect(abs(withMillis.timeIntervalSince(plain) - 0.25) < 0.001)
        #expect(JourneyManLink.date(from: "yesterday") == nil)
        #expect(throws: JourneyManLink.LinkError.notJourneyMan) {
            try JourneyManLink.decodeJourneyMan(Data(#"{"app":"Other","tasks":[]}"#.utf8))
        }
        #expect(throws: JourneyManLink.LinkError.newerFormat(9)) {
            try JourneyManLink.decodeJourneyMan(Data(#"{"app":"JourneyMan","format":9,"tasks":[]}"#.utf8))
        }
    }

    @Test func linksBetweenTheApps() {
        let id = UUID()
        #expect(JourneyManLink.nodeID(from: JourneyManLink.nodeURL(id)) == id)
        #expect(JourneyManLink.nodeID(from: URL(string: "atlas://node/\(id.uuidString.lowercased())")!) == id)
        #expect(JourneyManLink.nodeID(from: URL(string: "https://example.com/node/\(id.uuidString)")!) == nil)
        #expect(JourneyManLink.journeyManURL(for: id, appURL: "http://localhost:8000/#today")?.absoluteString
            == "http://localhost:8000/#task/atlas:\(id.uuidString)")
        #expect(JourneyManLink.journeyManURL(for: id, appURL: "journeyman://localhost/index.html")?.absoluteString
            == "journeyman://localhost/index.html#task/atlas:\(id.uuidString)") // the JourneyMan Mac app
        #expect(JourneyManLink.journeyManURL(for: id, appURL: "javascript:alert(1)") == nil)
        #expect(JourneyManLink.journeyManURL(for: id, appURL: "") == nil)
        #expect(JourneyManLink.durationText(minutes: 80) == "1h 20m")
        #expect(JourneyManLink.durationText(minutes: 45) == "45m")
        #expect(JourneyManLink.durationText(minutes: 120) == "2h")
    }
}
