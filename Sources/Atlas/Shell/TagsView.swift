import AtlasCore
import SwiftUI

/// Every tag with the nodes that carry it.
struct TagsView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(WindowState.self) private var window
    @State private var selectedTag: String?

    var body: some View {
        let tags = workspace.tagCounts()
        HSplitView {
            List(selection: $selectedTag) {
                ForEach(tags, id: \.tag) { entry in
                    HStack {
                        Label("#\(entry.tag)", systemImage: "tag")
                        Spacer()
                        Text("\(entry.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .tag(entry.tag)
                }
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            .overlay {
                if tags.isEmpty {
                    ContentUnavailableView("No Tags", systemImage: "tag",
                                           description: Text("Add tags to nodes in the inspector."))
                }
            }

            Group {
                if let tag = selectedTag {
                    List {
                        ForEach(workspace.nodes(taggedWith: tag)) { node in
                            TaggedNodeRow(node: node)
                        }
                    }
                } else {
                    ContentUnavailableView("Select a Tag", systemImage: "tag")
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity)
        }
        .navigationTitle("Tags")
    }
}

private struct TaggedNodeRow: View {
    let node: Node
    @Environment(Workspace.self) private var workspace
    @Environment(WindowState.self) private var window

    var body: some View {
        let maps = workspace.maps(containing: node.id)
        HStack {
            Label(node.data.displayTitle, systemImage: node.kind.symbolName)
                .foregroundStyle(node.data.effectiveColor.color)
            Spacer()
            Text(maps.map(\.name).joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !maps.isEmpty {
                Button("Show") { window.reveal(node.id, in: workspace) }
                    .buttonStyle(.borderless)
            }
        }
    }
}
