import AtlasCore
import SwiftUI

/// One window: sidebar plus the selected page.
struct RootView: View {
    let initialItem: SidebarItem?
    @Environment(Workspace.self) private var workspace
    @State private var window = WindowState()
    @State private var loadProblem: String?

    var body: some View {
        NavigationSplitView {
            SidebarView(window: window)
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 340)
        } detail: {
            DetailView(window: window)
        }
        .overlay {
            if window.isPaletteVisible {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .onTapGesture { window.isPaletteVisible = false }
                        .accessibilityHidden(true)
                    CommandPalette(window: window)
                        .padding(.top, 64)
                }
            }
        }
        .environment(window)
        .focusedSceneValue(\.windowState, window)
        // atlas://node/<id> (from JourneyMan's Open in Atlas) reveals the node in this window.
        .onOpenURL { url in
            guard let id = JourneyManLink.nodeID(from: url), workspace.nodes[id] != nil else { return }
            window.reveal(id, in: workspace)
        }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onAppear {
            DebugScript.activeWindow = window
            if window.selection == nil {
                window.selection = initialItem ?? workspace.sortedMaps.first.map { .map($0.id) } ?? .inbox
            }
            loadProblem = AppStore.shared.takeLoadProblem()
        }
        .alert("Workspace Problem", isPresented: Binding(get: { loadProblem != nil }, set: { if !$0 { loadProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(loadProblem ?? "")
        }
    }
}

private struct DetailView: View {
    let window: WindowState
    @Environment(Workspace.self) private var workspace

    var body: some View {
        switch window.selection {
        case .map(let id):
            if let map = workspace.maps[id] {
                MapScreen(map: map, controller: window.controller(for: map, workspace: workspace))
                    .id(id)
            } else {
                ContentUnavailableView("Map Deleted", systemImage: "trash",
                                       description: Text("Choose another map in the sidebar."))
            }
        case .tags:
            TagsView()
        case .inbox:
            InboxView(window: window)
        case .today:
            TodayView(window: window)
        case .week:
            WeekView(window: window)
        case .sources:
            SourcesView(window: window)
        case .review:
            ReviewView(window: window)
        case nil:
            ContentUnavailableView("Nothing Selected", systemImage: "sidebar.left",
                                   description: Text("Choose a map or a section in the sidebar."))
        }
    }
}
