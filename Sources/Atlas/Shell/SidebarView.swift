import AtlasCore
import SwiftUI

struct SidebarView: View {
    @Bindable var window: WindowState
    @Environment(Workspace.self) private var workspace
    @Environment(\.openWindow) private var openWindow
    @State private var renamingMapID: UUID?
    @State private var renameText = ""
    @State private var mapToDelete: MindMap?
    @FocusState private var renameFocused: Bool

    var body: some View {
        List(selection: $window.selection) {
            Section("Workspace") {
                row(.inbox).badge(workspace.inboxNodes.count)
                row(.today)
                row(.week)
                row(.sources).badge(workspace.sourceNodes.count)
                row(.tags)
                row(.review)
            }
            Section("Maps") {
                ForEach(workspace.sortedMaps) { map in
                    mapRow(map)
                        .tag(SidebarItem.map(map.id))
                }
                .onMove { indices, destination in
                    let maps = workspace.sortedMaps
                    guard let first = indices.first else { return }
                    let target = destination > first ? destination - 1 : destination
                    workspace.moveMap(maps[first], toIndex: target)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { newMap() } label: { Label("New Map", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .help("New Map (⌘N)")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .confirmationDialog("Delete “\(mapToDelete?.name ?? "")”?",
                            isPresented: Binding(get: { mapToDelete != nil }, set: { if !$0 { mapToDelete = nil } }),
                            presenting: mapToDelete) { map in
            Button("Delete Map", role: .destructive) { delete(map) }
        } message: { _ in
            Text("Nodes that appear only on this map are deleted too. Sources, tasks and nodes on other maps are kept. You can undo this.")
        }
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.symbolName)
            .tag(item)
            .contextMenu {
                Button("Open in New Window") { openWindow(value: item) }
            }
    }

    @ViewBuilder
    private func mapRow(_ map: MindMap) -> some View {
        if renamingMapID == map.id {
            TextField("Map name", text: $renameText)
                .focused($renameFocused)
                .onSubmit { finishRename(map) }
                .onExitCommand { renamingMapID = nil }
                .onChange(of: renameFocused) { _, focused in if !focused { finishRename(map) } }
        } else {
            Label(map.name, systemImage: SidebarItem.map(map.id).symbolName)
                .contextMenu {
                    Button("Rename") { startRename(map) }
                    Button("Open in New Window") { openWindow(value: SidebarItem.map(map.id)) }
                    Divider()
                    Button("Delete Map…", role: .destructive) { mapToDelete = map }
                }
        }
    }

    private func newMap() {
        let map = workspace.createMap(named: "Untitled Map")
        window.selection = .map(map.id)
        startRename(map)
    }

    private func startRename(_ map: MindMap) {
        renameText = map.name
        renamingMapID = map.id
        DispatchQueue.main.async { renameFocused = true }
    }

    private func finishRename(_ map: MindMap) {
        guard renamingMapID == map.id else { return }
        renamingMapID = nil
        if renameText != map.name { workspace.renameMap(map, to: renameText) }
    }

    private func delete(_ map: MindMap) {
        if window.selection == .map(map.id) {
            window.selection = workspace.sortedMaps.first { $0.id != map.id }.map { .map($0.id) } ?? .inbox
        }
        workspace.deleteMap(map)
    }
}
