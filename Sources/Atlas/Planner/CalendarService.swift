import AppKit
import AtlasCore
import EventKit
import Observation
import SwiftUI

enum PlannerSettings {
    static let showCalendarKey = "atlas.showCalendar"
    static let dayStartKey = "atlas.dayStartHour"
    static let staleDaysKey = "atlas.staleDays"

    static var showCalendar: Bool { UserDefaults.standard.object(forKey: showCalendarKey) as? Bool ?? true }
    static var dayStartHour: Int { UserDefaults.standard.object(forKey: dayStartKey) as? Int ?? 7 }
    static var staleDays: Int { UserDefaults.standard.object(forKey: staleDaysKey) as? Int ?? 14 }
}

/// A calendar event shown read-only beside tasks.
struct CalendarEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: Color
    let calendarName: String
}

/// Read-only access to the user's calendars through EventKit.
@MainActor
@Observable
final class CalendarService {
    static let shared = CalendarService()

    private(set) var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    /// Bumped when the calendar database changes, so views read events again.
    private(set) var revision = 0
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var cache: [DateInterval: [CalendarEvent]] = [:]
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated {
                CalendarService.shared.cache = [:]
                CalendarService.shared.revision += 1
            }
        }
    }

    var canRead: Bool { status == .fullAccess }
    var isDenied: Bool { status == .denied || status == .restricted }

    var statusText: String {
        switch status {
        case .fullAccess: "Allowed"
        case .denied: "Denied in System Settings"
        case .restricted: "Restricted"
        case .writeOnly: "Write-only (Atlas needs to read events)"
        case .notDetermined: "Not asked yet"
        @unknown default: "Unknown"
        }
    }

    func refreshStatus() {
        status = EKEventStore.authorizationStatus(for: .event)
    }

    /// Asks once; macOS remembers the answer.
    func requestAccess() {
        guard status == .notDetermined, ProcessInfo.processInfo.environment["ATLAS_SCRIPT"] == nil else { return }
        store.requestFullAccessToEvents { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    CalendarService.shared.refreshStatus()
                    CalendarService.shared.cache = [:]
                    CalendarService.shared.revision += 1
                }
            }
        }
    }

    /// Events overlapping `interval`, or none when calendars are hidden or not allowed.
    func events(in interval: DateInterval) -> [CalendarEvent] {
        _ = revision
        guard PlannerSettings.showCalendar, canRead else { return [] }
        if let cached = cache[interval] { return cached }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        let events = store.events(matching: predicate).map { event in
            CalendarEvent(id: (event.eventIdentifier ?? UUID().uuidString) + "\(event.startDate.timeIntervalSince1970)",
                          title: event.title ?? "Event", start: event.startDate, end: event.endDate,
                          isAllDay: event.isAllDay,
                          color: event.calendar.map { Color(nsColor: $0.color) } ?? .gray,
                          calendarName: event.calendar?.title ?? "")
        }
        .sorted { $0.start < $1.start }
        cache[interval] = events
        return events
    }
}

/// The deep-work timer: one task at a time, its time added to the task when stopped.
@MainActor
@Observable
final class FocusTimer {
    static let shared = FocusTimer()

    private(set) var taskID: UUID?
    private(set) var startedAt: Date?

    var isRunning: Bool { taskID != nil }

    func start(_ id: UUID, workspace: Workspace) {
        stop(workspace: workspace)
        taskID = id
        startedAt = Date()
    }

    func stop(workspace: Workspace) {
        guard let taskID, let startedAt else { return }
        workspace.addFocusTime(Date().timeIntervalSince(startedAt), to: taskID)
        self.taskID = nil
        self.startedAt = nil
    }

    func elapsed(at date: Date) -> TimeInterval {
        startedAt.map { date.timeIntervalSince($0) } ?? 0
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
