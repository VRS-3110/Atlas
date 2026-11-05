import AtlasCore
import SwiftUI

/// A small card beside the node under the pointer, after a short pause: a source's details,
/// a link's address, what a node cites, its task dates and the start of its notes. It never
/// takes clicks, so it cannot get in the way.
struct HoverPreview: View {
    let controller: MapController
    @State private var shownID: UUID?

    var body: some View {
        let hovered = controller.hoveredNodeID
        let busy = controller.editingNodeID != nil || controller.connectDrag != nil
            || controller.dragFeedback != nil || controller.marquee != nil || controller.relationPicker != nil
        let canvas = controller.canvasSize
        // A ZStack, not a Group: a Group would hand the modifiers below (the delay task
        // included) to its children, of which there are none until the card shows.
        ZStack(alignment: .topLeading) {
            Color.clear
            if !busy, let id = shownID, id == hovered, let node = controller.workspace.nodes[id],
               let rect = controller.viewRect(id), let lines = Self.lines(for: node, workspace: controller.workspace) {
                let x = min(max(8, rect.minX), max(8, canvas.width - 288))
                // Below the node, or above it when the node is in the lower part of the canvas.
                let above = rect.maxY > canvas.height * 0.6
                card(node: node, lines: lines)
                    .frame(width: 280, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: above ? .bottomLeading : .topLeading)
                    .offset(x: x, y: above ? -(canvas.height - rect.minY + 10) : rect.maxY + 10)
                    .transition(.opacity)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeOut(duration: 0.12), value: shownID)
        .task(id: hovered) {
            shownID = nil
            guard hovered != nil else { return }
            try? await Task.sleep(nanoseconds: 650_000_000)
            if !Task.isCancelled { shownID = hovered }
        }
    }

    private func card(node: Node, lines: [Line]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(node.data.displayTitle, systemImage: node.data.leadingSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(node.data.effectiveColor.color)
                .lineLimit(3)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Group {
                    if let label = line.label {
                        (Text(label + "  ").foregroundStyle(.secondary) + Text(line.text))
                    } else {
                        Text(line.text)
                    }
                }
                .font(.system(size: 11))
                .lineLimit(line.limit)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    struct Line {
        var label: String?
        var text: String
        var limit = 2
    }

    /// What the card shows, or nil for a node with nothing beyond its title.
    static func lines(for node: Node, workspace: Workspace) -> [Line]? {
        let data = node.data
        var lines: [Line] = []
        if let info = data.source {
            if !info.authors.isEmpty {
                let names = info.authors.prefix(4).joined(separator: "; ") + (info.authors.count > 4 ? " et al." : "")
                lines.append(Line(label: "By", text: names))
            }
            let published = [info.year.map(String.init), info.container.isEmpty ? nil : info.container,
                             info.publisher.isEmpty ? nil : info.publisher].compactMap { $0 }
            if !published.isEmpty { lines.append(Line(label: "In", text: published.joined(separator: " · "))) }
            if !info.doi.isEmpty { lines.append(Line(label: "DOI", text: info.doi, limit: 1)) }
            else if !info.url.isEmpty { lines.append(Line(label: "Link", text: info.url, limit: 1)) }
            let usage = workspace.usage(of: node.id)
            var used: [String] = []
            if !usage.maps.isEmpty { used.append("\(usage.maps.count) map\(usage.maps.count == 1 ? "" : "s")") }
            if !usage.citing.isEmpty { used.append("cited \(usage.citing.count)×") }
            if workspace.document(of: node.id) != nil { used.append("PDF attached") }
            if !used.isEmpty { lines.append(Line(label: "Used", text: used.joined(separator: ", "))) }
        }
        if let link = data.link, !link.isEmpty { lines.append(Line(label: "Link", text: link, limit: 1)) }
        if !data.citations.isEmpty, let cite = workspace.inTextCitation(for: node.id), data.source == nil {
            lines.append(Line(label: "Cites", text: cite))
        }
        if let task = data.task {
            var parts = [task.status.title]
            if let due = task.due { parts.append("due \(due.formatted(date: .abbreviated, time: .omitted))") }
            if let start = task.scheduledStart { parts.append("on \(start.formatted(date: .abbreviated, time: .shortened))") }
            lines.append(Line(label: "Task", text: parts.joined(separator: ", ")))
        }
        let notes = data.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { lines.append(Line(text: notes.count > 280 ? String(notes.prefix(280)) + "…" : notes, limit: 6)) }
        if !data.tags.isEmpty { lines.append(Line(text: data.tags.map { "#\($0)" }.joined(separator: " "), limit: 1)) }
        return lines.isEmpty ? nil : lines
    }
}
