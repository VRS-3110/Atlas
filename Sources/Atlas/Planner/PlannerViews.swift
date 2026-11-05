import AtlasCore
import SwiftUI

/// Today: the day's timeline, with the backlog and the daily log beside it.
struct TodayView: View {
    @Bindable var window: WindowState
    @Environment(Workspace.self) private var workspace
    @State private var newTask = ""

    var body: some View {
        let day = window.todayDate
        HSplitView {
            VStack(spacing: 0) {
                DayHeader(date: day, onStep: { window.todayDate = shift(day, by: $0) },
                          onToday: { window.todayDate = Date() })
                AllDayStrip(days: [day])
                Divider()
                PlannerTimeline(days: [day], hourHeight: 56, showsFocus: true)
            }
            .frame(minWidth: 380)
            VSplitView {
                backlog.frame(minHeight: 180)
                DailyLogPane(date: day).frame(minHeight: 200)
            }
            .frame(minWidth: 260, idealWidth: 320, maxWidth: 440)
        }
        .navigationTitle(Calendar.current.isDateInToday(day) ? "Today" : day.formatted(.dateTime.weekday(.wide).month().day()))
        .navigationSubtitle(subtitle(day))
        .toolbar {
            ToolbarItem(placement: .primaryAction) { FocusTimerBadge() }
        }
        .onAppear { CalendarService.shared.requestAccessIfWanted() }
    }

    private var backlog: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Backlog").font(.headline)
                Spacer()
                Text("Drag onto the timeline").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            HStack {
                Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                TextField("New task", text: $newTask)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        let title = newTask.trimmingCharacters(in: .whitespaces)
                        guard !title.isEmpty else { return }
                        workspace.createTask(title)
                        newTask = ""
                    }
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
            Divider()
            let overdue = workspace.overdueTasks(now: Date())
            let backlog = workspace.unscheduledTasks.filter { node in !overdue.contains { $0.id == node.id } }
            List {
                if !overdue.isEmpty {
                    Section("Overdue") { ForEach(overdue) { TaskRow(node: $0) } }
                }
                Section(overdue.isEmpty ? "Unscheduled" : "Unscheduled") {
                    if backlog.isEmpty {
                        Text("Nothing waiting. Make any node a task with ⌘T.").foregroundStyle(.secondary).font(.callout)
                    }
                    ForEach(backlog) { TaskRow(node: $0) }
                }
            }
            .listStyle(.inset)
            .onDrop(of: DropImport.acceptedTypes, isTargeted: nil) { providers in
                Task {
                    for item in await DropImport.load(providers) {
                        if case .node(let id) = item {
                            if workspace.nodes[id]?.task?.scheduledStart != nil { workspace.unschedule(id) }
                            else { workspace.convertToTasks([id]) }
                        }
                    }
                }
                return true
            }
        }
    }

    private func subtitle(_ day: Date) -> String {
        let tasks = workspace.tasks(scheduledIn: PlannerCalendar.dayInterval(day))
        let open = tasks.filter { $0.task?.status.isOpen == true }.count
        let minutes = tasks.reduce(0) { $0 + ($1.task?.durationMinutes ?? 0) }
        return "\(tasks.count) block\(tasks.count == 1 ? "" : "s") · \(open) open · \(minutes / 60)h \(minutes % 60)m planned"
    }

    private func shift(_ date: Date, by days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
    }
}

/// Week: seven days side by side, with overdue and unscheduled tasks in a tray.
struct WeekView: View {
    @Bindable var window: WindowState
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let days = PlannerCalendar.weekDays(containing: window.weekDate)
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                        .help("Previous week")
                    Button("This Week") { window.weekDate = Date() }
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                        .help("Next week")
                    Text(weekTitle(days)).font(.headline).padding(.leading, 6)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12).padding(.vertical, 8)
                HStack(spacing: 0) {
                    Color.clear.frame(width: PlannerTimeline.gutter)
                    ForEach(days, id: \.self) { day in
                        VStack(spacing: 1) {
                            Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption).foregroundStyle(.secondary)
                            Text(day.formatted(.dateTime.day()))
                                .font(.title3.weight(Calendar.current.isDateInToday(day) ? .bold : .regular))
                                .foregroundStyle(Calendar.current.isDateInToday(day) ? Color.accentColor : Color.primary)
                        }
                        .frame(maxWidth: .infinity)
                        .onTapGesture(count: 2) { window.todayDate = day; window.selection = .today }
                        .help("Double-click to open the day")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { window.todayDate = day; window.selection = .today }
                    }
                }
                // The spacer is a Color, which would otherwise grow and take half the page.
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
                AllDayStrip(days: days)
                Divider()
                PlannerTimeline(days: days, hourHeight: 44)
            }
            .frame(minWidth: 560)
            WeekTray()
                .frame(minWidth: 220, idealWidth: 270, maxWidth: 380)
        }
        .navigationTitle("Week")
        .navigationSubtitle(weekTitle(days))
        .toolbar { ToolbarItem(placement: .primaryAction) { FocusTimerBadge() } }
        .onAppear { CalendarService.shared.requestAccessIfWanted() }
    }

    private func step(_ weeks: Int) {
        window.weekDate = Calendar.current.date(byAdding: .weekOfYear, value: weeks, to: window.weekDate) ?? window.weekDate
    }

    private func weekTitle(_ days: [Date]) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        return "\(first.formatted(.dateTime.month().day())) – \(last.formatted(.dateTime.month().day().year()))"
    }
}

private struct WeekTray: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let overdue = workspace.overdueTasks(now: Date())
        let unscheduled = workspace.unscheduledTasks.filter { node in !overdue.contains { $0.id == node.id } }
        List {
            Section {
                if overdue.isEmpty { Text("Nothing overdue").foregroundStyle(.secondary) }
                ForEach(overdue) { TaskRow(node: $0) }
            } header: {
                Label("Overdue", systemImage: "exclamationmark.circle").foregroundStyle(overdue.isEmpty ? Color.secondary : Color.red)
            }
            Section {
                if unscheduled.isEmpty { Text("No unscheduled tasks").foregroundStyle(.secondary) }
                ForEach(unscheduled) { TaskRow(node: $0) }
            } header: {
                Label("Unscheduled", systemImage: "tray")
            }
        }
        .listStyle(.sidebar)
        .onDrop(of: DropImport.acceptedTypes, isTargeted: nil) { providers in
            Task {
                for item in await DropImport.load(providers) {
                    if case .node(let id) = item { workspace.convertToTasks([id]) }
                }
            }
            return true
        }
    }
}

/// Date title with previous/next buttons.
private struct DayHeader: View {
    let date: Date
    let onStep: (Int) -> Void
    let onToday: () -> Void

    var body: some View {
        HStack {
            Button { onStep(-1) } label: { Image(systemName: "chevron.left") }.help("Previous day")
            Button("Today", action: onToday).disabled(Calendar.current.isDateInToday(date))
            Button { onStep(1) } label: { Image(systemName: "chevron.right") }.help("Next day")
            Text(date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                .font(.headline).padding(.leading, 6)
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Tasks due on each day without a time block, and all-day events.
private struct AllDayStrip: View {
    let days: [Date]
    @Environment(Workspace.self) private var workspace
    @Environment(WindowState.self) private var window

    var body: some View {
        let columns = days.map { day in
            (due: workspace.unscheduledTasks(dueOn: day),
             events: CalendarService.shared.events(in: PlannerCalendar.dayInterval(day)).filter(\.isAllDay))
        }
        if columns.contains(where: { !$0.due.isEmpty || !$0.events.isEmpty }) {
            HStack(alignment: .top, spacing: 0) {
                Text("all-day").font(.caption2).foregroundStyle(.secondary)
                    .frame(width: PlannerTimeline.gutter - 6, alignment: .trailing).padding(.trailing, 6)
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(column.events) { event in
                            Text(event.title).font(.caption2).lineLimit(1)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(event.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                        }
                        ForEach(column.due) { node in
                            Label(node.data.displayTitle, systemImage: "flag")
                                .font(.caption2).lineLimit(1)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                                .draggable(DropImport.dragText(for: node.id))
                                .help("Due this day. Drag onto the timeline to schedule a time.")
                                .onTapGesture(count: 2) { window.reveal(node.id, in: workspace) }
                        }
                    }
                    .padding(.horizontal, 3)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// The automatic note for a day: free notes, and links to every node touched that day.
private struct DailyLogPane: View {
    let date: Date
    @Environment(Workspace.self) private var workspace
    @Environment(WindowState.self) private var window

    var body: some View {
        let touched = workspace.touchedNodes(on: date)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Daily Log").font(.headline)
                Spacer()
                Text(PlannerCalendar.dayKey(date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            TextEditor(text: Binding(get: { workspace.dayLog(for: date)?.body ?? "" },
                                     set: { workspace.setDayLogBody($0, for: date) }))
                .font(.body)
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                .accessibilityLabel("Daily log notes")
            Text(touched.isEmpty ? "Nodes you create or edit appear here." : "Touched (\(touched.count))")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(touched) { node in
                        Button { window.reveal(node.id, in: workspace) } label: {
                            Label(node.data.displayTitle, systemImage: node.data.leadingSymbol)
                                .foregroundStyle(node.data.effectiveColor.color)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
    }
}

/// The running deep-work timer, shown in the toolbar.
struct FocusTimerBadge: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let timer = FocusTimer.shared
        if let id = timer.taskID {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Button {
                    timer.stop(workspace: workspace)
                } label: {
                    Label("\(workspace.nodes[id]?.data.displayTitle ?? "Focus") · \(FocusTimer.format(timer.elapsed(at: context.date)))",
                          systemImage: "stop.circle.fill")
                        .monospacedDigit()
                }
                .help("Stop the deep-work timer and log the time on the task")
            }
        }
    }
}

extension CalendarService {
    /// Asks for calendar access the first time a planner page opens, if calendars are on.
    func requestAccessIfWanted() {
        refreshStatus()
        if PlannerSettings.showCalendar { requestAccess() }
    }
}
