import AtlasCore
import AtlasLayout
import SwiftUI

/// Time blocks for one or more days on an hour grid. Tasks can be dragged to another
/// time (or, in the week, another day), resized from their bottom edge, and dropped in
/// from the backlog, the Inbox or the sources library. Calendar events are read-only.
struct PlannerTimeline: View {
    let days: [Date]
    var hourHeight: CGFloat = 52
    /// Whether blocks show the deep-work timer button (the Today page).
    var showsFocus = false
    @Environment(Workspace.self) private var workspace
    @Environment(WindowState.self) private var window

    static let gutter: CGFloat = 54

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                GeometryReader { geometry in
                    let columnWidth = max(60, (geometry.size.width - Self.gutter) / CGFloat(max(days.count, 1)))
                    ZStack(alignment: .topLeading) {
                        HourGrid(hourHeight: hourHeight)
                        HStack(spacing: 0) {
                            Color.clear.frame(width: Self.gutter)
                            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                                DayColumn(day: day, dayIndex: index, dayCount: days.count, columnWidth: columnWidth,
                                          hourHeight: hourHeight, showsFocus: showsFocus)
                                    .frame(width: columnWidth)
                            }
                        }
                    }
                }
                .frame(height: hourHeight * 24)
                .background {
                    // Anchors for scrolling to an hour.
                    VStack(spacing: 0) {
                        ForEach(0..<24, id: \.self) { hour in Color.clear.frame(height: hourHeight).id("hour-\(hour)") }
                    }
                }
            }
            .onAppear { scroll(proxy) }
            .onChange(of: days.first) { scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        let isToday = days.contains { Calendar.current.isDateInToday($0) }
        let hour = isToday ? max(0, min(Calendar.current.component(.hour, from: Date()) - 2, PlannerSettings.dayStartHour)) : PlannerSettings.dayStartHour
        DispatchQueue.main.async { proxy.scrollTo("hour-\(hour)", anchor: .top) }
    }
}

/// Hour lines and labels.
private struct HourGrid: View {
    let hourHeight: CGFloat

    var body: some View {
        Canvas { context, size in
            for hour in 0...24 {
                let y = CGFloat(hour) * hourHeight
                var line = Path()
                line.move(to: CGPoint(x: PlannerTimeline.gutter - 6, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(.primary.opacity(0.1)), lineWidth: 1)
                var half = Path()
                half.move(to: CGPoint(x: PlannerTimeline.gutter, y: y + hourHeight / 2))
                half.addLine(to: CGPoint(x: size.width, y: y + hourHeight / 2))
                context.stroke(half, with: .color(.primary.opacity(0.04)), lineWidth: 1)
                guard hour < 24 else { continue }
                let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
                let label = context.resolve(Text(date.formatted(.dateTime.hour())).font(.caption2).foregroundStyle(.secondary))
                context.draw(label, at: CGPoint(x: PlannerTimeline.gutter - 10, y: y + 1), anchor: .topTrailing)
            }
        }
        .accessibilityHidden(true)
    }
}

/// One item on a day column.
private enum TimelineItem: Identifiable {
    case task(Node)
    case event(CalendarEvent)

    var id: String {
        switch self {
        case .task(let node): node.id.uuidString
        case .event(let event): event.id
        }
    }
}

private struct DayColumn: View {
    let day: Date
    let dayIndex: Int
    let dayCount: Int
    let columnWidth: CGFloat
    let hourHeight: CGFloat
    let showsFocus: Bool
    @Environment(Workspace.self) private var workspace
    @State private var dropTarget: CGFloat?

    var body: some View {
        let interval = PlannerCalendar.dayInterval(day)
        let tasks = workspace.tasks(scheduledIn: interval)
        let events = CalendarService.shared.events(in: interval).filter { !$0.isAllDay }
        let items: [TimelineItem] = events.map(TimelineItem.event) + tasks.map(TimelineItem.task)
        let spans = items.map { item -> (start: Double, end: Double) in
            switch item {
            case .task(let node):
                let start = minutes(node.task?.scheduledStart ?? interval.start, in: interval)
                return (start, start + Double(node.task?.durationMinutes ?? 30))
            case .event(let event):
                return (max(0, minutes(event.start, in: interval)), min(1440, minutes(event.end, in: interval)))
            }
        }
        let slots = TimelineLanes.assign(spans)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Calendar.current.isDateInWeekend(day) ? Color.primary.opacity(0.025) : Color.clear)
                .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1) }
                .contentShape(Rectangle())
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let span = spans[index]
                let slot = slots[index]
                let width = (columnWidth - 8) / CGFloat(slot.laneCount)
                let height = max(18, CGFloat(span.end - span.start) / 60 * hourHeight - 2)
                Group {
                    switch item {
                    case .task(let node):
                        TaskBlock(node: node, columnWidth: columnWidth, dayIndex: dayIndex, dayCount: dayCount,
                                  hourHeight: hourHeight, showsFocus: showsFocus)
                    case .event(let event):
                        EventBlock(event: event)
                    }
                }
                .frame(width: max(20, width - 2), height: height, alignment: .topLeading)
                .offset(x: 4 + CGFloat(slot.lane) * width, y: CGFloat(span.start) / 60 * hourHeight + 1)
            }
            if Calendar.current.isDateInToday(day) {
                NowLine(day: interval, hourHeight: hourHeight)
            }
            if let dropTarget {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    .frame(width: columnWidth - 8, height: hourHeight / 2)
                    .offset(x: 4, y: dropTarget)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: hourHeight * 24, alignment: .top)
        .onDrop(of: DropImport.acceptedTypes, delegate: TimelineDrop(day: interval, hourHeight: hourHeight,
                                                                      workspace: workspace, target: $dropTarget))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
    }

    private func minutes(_ date: Date, in day: DateInterval) -> Double {
        date.timeIntervalSince(day.start) / 60
    }
}

/// Dropping a task (or any Atlas node, or text) on a day schedules it where it lands.
private struct TimelineDrop: DropDelegate {
    let day: DateInterval
    let hourHeight: CGFloat
    let workspace: Workspace
    @Binding var target: CGFloat?

    private func start(at location: CGPoint) -> Date {
        let minutes = max(0, min(1440 - 15, Double(location.y / hourHeight * 60)))
        return PlannerCalendar.snap(day.start.addingTimeInterval(minutes * 60))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let date = start(at: info.location)
        target = CGFloat(date.timeIntervalSince(day.start) / 3600) * hourHeight
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { target = nil }

    func performDrop(info: DropInfo) -> Bool {
        target = nil
        let date = start(at: info.location)
        let providers = info.itemProviders(for: DropImport.acceptedTypes)
        Task { @MainActor in
            for item in await DropImport.load(providers) {
                switch item {
                case .node(let id): workspace.schedule(id, at: date)
                case .text(let text): workspace.createTask(String(text.prefix(200)), scheduledAt: date)
                case .web(let url): workspace.createTask(url.absoluteString, scheduledAt: date)
                default: continue
                }
            }
        }
        return true
    }
}

private struct NowLine: View {
    let day: DateInterval
    let hourHeight: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let y = CGFloat(context.date.timeIntervalSince(day.start) / 3600) * hourHeight
            HStack(spacing: 0) {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                Rectangle().fill(Color.red).frame(height: 1.5)
            }
            .offset(x: -3, y: y - 3.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct EventBlock: View {
    let event: CalendarEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(event.title).font(.caption.weight(.medium)).lineLimit(2)
            Text("\(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened))")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(event.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
        .overlay(alignment: .leading) { Rectangle().fill(event.color.opacity(0.6)).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .help("\(event.title) · \(event.calendarName) (calendar event, read-only)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Calendar event \(event.title)")
    }
}

/// A scheduled task: drag to move, drag the bottom edge to resize.
private struct TaskBlock: View {
    let node: Node
    let columnWidth: CGFloat
    let dayIndex: Int
    let dayCount: Int
    let hourHeight: CGFloat
    let showsFocus: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(WindowState.self) private var window
    @State private var move: CGSize = .zero
    @State private var resize: CGFloat = 0

    var body: some View {
        let task = node.task ?? TaskInfo()
        let color = node.data.effectiveColor.color
        let focusing = FocusTimer.shared.taskID == node.id
        blockContent(task, color: color, focusing: focusing)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(color.opacity(task.status == .done ? 0.08 : 0.2), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color.opacity(focusing ? 0.9 : 0.45), lineWidth: focusing ? 2 : 1))
            .overlay(alignment: .bottom) { resizeHandle }
            .padding(.bottom, -resize)
            .offset(move)
            .zIndex(move == .zero ? 0 : 10)
            .gesture(moveGesture)
            .onTapGesture(count: 2) { window.reveal(node.id, in: workspace) }
            .contextMenu { menu }
            .help("\(node.data.displayTitle): drag to move, drag the bottom edge to change its length, double-click to open")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Task \(node.data.displayTitle), \(timeText(task)), \(task.status.title)")
            .accessibilityAction(named: task.status == .done ? "Mark Not Done" : "Mark Done") {
                workspace.setTaskStatus(task.status == .done ? .todo : .done, of: [node.id])
            }
            .accessibilityAction(named: "Move 15 Minutes Later") { shift(by: 15) }
            .accessibilityAction(named: "Move 15 Minutes Earlier") { shift(by: -15) }
            .accessibilityAction(named: "Make 15 Minutes Longer") {
                workspace.setDuration(task.durationMinutes + 15, of: node.id)
            }
            .accessibilityAction(named: "Make 15 Minutes Shorter") {
                workspace.setDuration(task.durationMinutes - 15, of: node.id)
            }
            .accessibilityAction(named: "Unschedule") { workspace.unschedule(node.id) }
            .accessibilityAction(named: "Show Node") { window.reveal(node.id, in: workspace) }
    }

    private func shift(by minutes: Int) {
        guard let start = node.task?.scheduledStart else { return }
        workspace.schedule(node.id, at: start.addingTimeInterval(Double(minutes) * 60))
    }

    private func blockContent(_ task: TaskInfo, color: Color, focusing: Bool) -> some View {
        let done = task.status == .done
        let timer = FocusTimer.shared
        return VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .top, spacing: 4) {
                Button {
                    workspace.setTaskStatus(done ? .todo : .done, of: [node.id])
                } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(done ? Color.green : color)
                .help(done ? "Mark as not done" : "Mark as done")
                Text(node.data.displayTitle)
                    .font(.caption.weight(.semibold))
                    .strikethrough(done)
                    .lineLimit(3)
                Spacer(minLength: 0)
                if showsFocus, !done {
                    Button {
                        if focusing { timer.stop(workspace: workspace) } else { timer.start(node.id, workspace: workspace) }
                    } label: {
                        Image(systemName: focusing ? "stop.circle.fill" : "timer")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(focusing ? Color.red : Color.secondary)
                    .help(focusing ? "Stop the deep-work timer" : "Start a deep-work timer for this block")
                }
            }
            Text(timeText(task))
                .font(.caption2).foregroundStyle(.secondary)
            if focusing {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Focus \(FocusTimer.format(timer.elapsed(at: context.date)))")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.red)
                }
            } else if task.focusSeconds >= 60 {
                Text("\(Int(task.focusSeconds / 60)) min focused").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 7)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { resize = $0.translation.height }
                    .onEnded { value in
                        let minutes = Double(node.task?.durationMinutes ?? 30) + Double(value.translation.height / hourHeight * 60)
                        let snapped = Int((minutes / 15).rounded()) * 15
                        resize = 0
                        workspace.setDuration(max(15, snapped), of: node.id)
                    }
            )
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { move = $0.translation }
            .onEnded { value in
                move = .zero
                guard let start = node.task?.scheduledStart else { return }
                let dayShift = dayCount > 1
                    ? max(-dayIndex, min(dayCount - 1 - dayIndex, Int((value.translation.width / columnWidth).rounded())))
                    : 0
                let minutes = Double(value.translation.height / hourHeight * 60)
                var moved = start.addingTimeInterval(minutes * 60)
                moved = Calendar.current.date(byAdding: .day, value: dayShift, to: moved) ?? moved
                let snapped = PlannerCalendar.snap(moved)
                if snapped != start { workspace.schedule(node.id, at: snapped) }
            }
    }

    @ViewBuilder
    private var menu: some View {
        let task = node.task ?? TaskInfo()
        Picker("Status", selection: Binding(get: { task.status }, set: { workspace.setTaskStatus($0, of: [node.id]) })) {
            ForEach(TaskStatus.allCases) { Text($0.title).tag($0) }
        }
        Menu("Length") {
            ForEach([15, 30, 45, 60, 90, 120, 180], id: \.self) { minutes in
                Button(minutes < 60 ? "\(minutes) min" : "\(Double(minutes) / 60, specifier: "%g") h") {
                    workspace.setDuration(minutes, of: node.id)
                }
            }
        }
        if showsFocus {
            Button(FocusTimer.shared.taskID == node.id ? "Stop Focus Timer" : "Start Focus Timer") {
                if FocusTimer.shared.taskID == node.id { FocusTimer.shared.stop(workspace: workspace) }
                else { FocusTimer.shared.start(node.id, workspace: workspace) }
            }
        }
        Button("Move 15 Minutes Later") { shift(by: 15) }
        Button("Move 15 Minutes Earlier") { shift(by: -15) }
        Divider()
        Button("Show Node") { window.reveal(node.id, in: workspace) }
        Button("Unschedule") { workspace.unschedule(node.id) }
    }

    private func timeText(_ task: TaskInfo) -> String {
        guard let start = task.scheduledStart, let end = task.scheduledEnd else { return "" }
        return "\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }
}

/// A task in a list (backlog, overdue tray, review), draggable onto a timeline.
struct TaskRow: View {
    let node: Node
    var showsDue = true
    @Environment(Workspace.self) private var workspace
    @Environment(WindowState.self) private var window

    var body: some View {
        let task = node.task ?? TaskInfo()
        HStack(spacing: 8) {
            Button {
                workspace.setTaskStatus(task.status == .done ? .todo : .done, of: [node.id])
            } label: {
                Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.status == .done ? Color.green : node.data.effectiveColor.color)
            }
            .buttonStyle(.plain)
            .help("Mark as done")
            VStack(alignment: .leading, spacing: 1) {
                Text(node.data.displayTitle).lineLimit(2).strikethrough(task.status == .done)
                HStack(spacing: 6) {
                    if task.priority != .none { Text(task.priority.title).foregroundStyle(task.priority == .high ? .red : .secondary) }
                    if showsDue, let due = task.due {
                        Text("Due \(due.formatted(.relative(presentation: .named)))")
                            .foregroundStyle(due < Calendar.current.startOfDay(for: Date()) ? Color.red : Color.secondary)
                    }
                    if let start = task.scheduledStart {
                        Text(start.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let map = workspace.maps(containing: node.id).first { Text(map.name).lineLimit(1) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .draggable(DropImport.dragText(for: node.id))
        .onTapGesture(count: 2) { window.reveal(node.id, in: workspace) }
        .contextMenu {
            Button("Schedule Today") { workspace.schedule(node.id, at: nextFreeSlot()) }
            Button("Show Node") { window.reveal(node.id, in: workspace) }
            if task.scheduledStart != nil { Button("Unschedule") { workspace.unschedule(node.id) } }
            Divider()
            Button("Mark Done") { workspace.setTaskStatus(.done, of: [node.id]) }
            Button("Cancel Task") { workspace.setTaskStatus(.cancelled, of: [node.id]) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Drag onto the timeline to schedule, or use the Schedule Today action")
        .accessibilityAction(named: "Schedule Today") { workspace.schedule(node.id, at: nextFreeSlot()) }
        .accessibilityAction(named: "Mark Done") { workspace.setTaskStatus(.done, of: [node.id]) }
        .accessibilityAction(named: "Show Node") { window.reveal(node.id, in: workspace) }
    }

    /// The next quarter hour from now (or the timeline's start, early in the day).
    private func nextFreeSlot() -> Date {
        let now = Date()
        let dayStart = Calendar.current.date(bySettingHour: PlannerSettings.dayStartHour, minute: 0, second: 0, of: now) ?? now
        let start = max(now, dayStart)
        return PlannerCalendar.snap(start.addingTimeInterval(7.5 * 60))
    }
}
