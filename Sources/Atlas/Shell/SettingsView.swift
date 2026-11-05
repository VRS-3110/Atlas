import AppKit
import AtlasCore
import SwiftUI

/// Atlas ▸ Settings (⌘,).
struct SettingsView: View {
    @AppStorage(CaptureShortcut.defaultsKey) private var shortcut = CaptureShortcut.optionSpace.rawValue
    @AppStorage(PlannerSettings.showCalendarKey) private var showCalendar = true
    @AppStorage(PlannerSettings.dayStartKey) private var dayStart = 7
    @AppStorage(PlannerSettings.staleDaysKey) private var staleDays = 14
    @State private var shortcutTaken = false
    @State private var calendar = CalendarService.shared
    @AppStorage(JourneyManSync.enabledKey) private var shareWithJourneyMan = false
    @AppStorage(JourneyManSync.addressKey) private var journeyManAddress = ""
    @State private var journeyMan = JourneyManSync.shared

    var body: some View {
        Form {
            Section("Quick Capture") {
                Picker("Shortcut", selection: $shortcut) {
                    ForEach(CaptureShortcut.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: shortcut) {
                    QuickCapture.shared.applyShortcut()
                    shortcutTaken = QuickCapture.shared.lastShortcutFailed
                }
                if shortcutTaken {
                    Label("Another app already uses this shortcut. Choose a different one.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Text("Opens a capture panel from any app. Captures go to the Inbox.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Planner") {
                Toggle("Show calendar events in Today and Week", isOn: $showCalendar)
                    .onChange(of: showCalendar) { _, on in if on { calendar.requestAccess() } }
                if showCalendar {
                    LabeledContent("Calendar access") {
                        Text(calendar.statusText).foregroundStyle(.secondary)
                    }
                    if calendar.isDenied {
                        Button("Open Privacy Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }
                    }
                }
                Picker("Timeline starts at", selection: $dayStart) {
                    ForEach(0..<13) { hour in Text(hourTitle(hour)).tag(hour) }
                }
                Stepper("Review flags branches untouched for \(staleDays) days", value: $staleDays, in: 3...90)
            }
            Section("JourneyMan") {
                Toggle("Share tasks with JourneyMan", isOn: $shareWithJourneyMan)
                    .onChange(of: shareWithJourneyMan) { journeyMan.sharingChanged() }
                Text("JourneyMan, the time tracker, shows your tasks with a project for each map. Ticking a task in either app ticks it in both, focus time goes to JourneyMan, and time tracked there shows in the inspector. Both apps use a folder on this Mac; nothing goes online.")
                    .font(.caption).foregroundStyle(.secondary)
                if shareWithJourneyMan {
                    LabeledContent("Folder") {
                        Button(journeyMan.folder.path) { journeyMan.revealFolder() }
                            .buttonStyle(.link)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    TextField("JourneyMan address", text: $journeyManAddress,
                              prompt: Text(journeyMan.reportedAddress ?? "Filled in by JourneyMan"))
                    LabeledContent("Status") {
                        Text(journeyMan.statusText).foregroundStyle(.secondary)
                    }
                    if let problem = journeyMan.problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Text("In JourneyMan, open Connections ▸ Atlas and connect this folder.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Workspace") {
                LabeledContent("Saved in") {
                    Button(Workspace.defaultStoreURL.deletingLastPathComponent().path) {
                        NSWorkspace.shared.activateFileViewerSelecting([Workspace.defaultStoreURL])
                    }
                    .buttonStyle(.link)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                Text("Atlas saves as you work and keeps a dated copy of the workspace each day in the Backups folder beside it. File ▸ Back Up Workspace makes a portable copy.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            shortcutTaken = QuickCapture.shared.lastShortcutFailed
            calendar.refreshStatus()
        }
    }

    private func hourTitle(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}
