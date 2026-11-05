import AtlasCore
import SwiftUI

/// The weekly review: what got done, what came in, what is still open and what has gone quiet.
struct ReviewView: View {
    @Bindable var window: WindowState
    @Environment(Workspace.self) private var workspace
    @State private var weeksBack = 0

    var body: some View {
        let end = Calendar.current.date(byAdding: .weekOfYear, value: -weeksBack, to: Date()) ?? Date()
        let review = workspace.weeklyReview(now: end, staleDays: PlannerSettings.staleDays)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(review)
                HStack(spacing: 12) {
                    tile("Completed", "\(review.completed.count)", "checkmark.circle", .green)
                    tile("New Sources", "\(review.newSources.count)", "books.vertical", .blue)
                    tile("Open Questions", "\(review.openQuestions.count)", "questionmark.circle", .orange)
                    tile("Stale Branches", "\(review.staleBranches.count)", "leaf", .brown)
                    tile("Focus Time", hours(review.focusSeconds), "timer", .purple)
                }
                section("Completed Tasks", empty: "No tasks completed in this period.", items: review.completed) { node in
                    row(node, detail: node.task?.completedAt?.formatted(date: .abbreviated, time: .shortened) ?? "")
                }
                section("New Sources", empty: "No sources added in this period.", items: review.newSources) { node in
                    row(node, detail: node.source.map { CitationFormatter.inText($0, title: node.title) } ?? "")
                }
                section("Open Questions", empty: "Every question has an answer. Questions count as answered once a claim or evidence node is linked to them, or when you mark them.",
                        items: review.openQuestions) { node in
                    HStack {
                        row(node, detail: workspace.maps(containing: node.id).first?.name ?? "Not on a map")
                        Button("Mark Answered") { workspace.markAnswered(node.id) }
                            .controlSize(.small)
                    }
                }
                section("Stale Branches", empty: "Nothing has gone quiet for \(PlannerSettings.staleDays) days.",
                        items: review.staleBranches) { branch in
                    if let node = workspace.nodes[branch.nodeID] {
                        HStack {
                            row(node, detail: "\(workspace.maps[branch.mapID]?.name ?? "") · \(branch.size) node\(branch.size == 1 ? "" : "s") · untouched since \(branch.lastTouched.formatted(date: .abbreviated, time: .omitted))",
                                mapID: branch.mapID)
                            Button("Mark Reviewed") { workspace.markReviewed(branch.nodeID) }
                                .controlSize(.small)
                                .help("Note in today's log that you looked at this branch")
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Weekly Review")
        .navigationSubtitle(period(review.interval))
    }

    private func header(_ review: WeeklyReview) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(weeksBack == 0 ? "This Week" : weeksBack == 1 ? "Last Week" : "\(weeksBack) Weeks Ago")
                    .font(.largeTitle.weight(.semibold))
                Text(period(review.interval)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { weeksBack += 1 } label: { Image(systemName: "chevron.left") }
                .help("Previous week")
            Button { weeksBack = max(0, weeksBack - 1) } label: { Image(systemName: "chevron.right") }
                .disabled(weeksBack == 0)
                .help("Next week")
        }
        .buttonStyle(.borderless)
    }

    private func tile(_ title: String, _ value: String, _ symbol: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(color)
            Text(value).font(.title.weight(.semibold).monospacedDigit())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private func section<Item: Identifiable, Row: View>(_ title: String, empty: String, items: [Item],
                                                        @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            if items.isEmpty {
                Text(empty).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        row(item).padding(.vertical, 6)
                        Divider()
                    }
                }
            }
        }
    }

    private func row(_ node: Node, detail: String, mapID: UUID? = nil) -> some View {
        Button { window.reveal(node.id, in: workspace, preferring: mapID) } label: {
            HStack {
                Label(node.data.displayTitle, systemImage: node.data.leadingSymbol)
                    .foregroundStyle(node.data.effectiveColor.color)
                    .lineLimit(1)
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func period(_ interval: DateInterval) -> String {
        let last = interval.end.addingTimeInterval(-1)
        return "\(interval.start.formatted(.dateTime.month().day())) – \(last.formatted(.dateTime.month().day().year()))"
    }

    private func hours(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
