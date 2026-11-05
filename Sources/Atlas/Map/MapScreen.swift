import AtlasCore
import AtlasLayout
import SwiftUI

/// A map in the detail column: canvas, toolbar and inspector.
struct MapScreen: View {
    let map: MindMap
    let controller: MapController
    @Environment(WindowState.self) private var window
    @AppStorage("atlas.showInspector") private var showInspector = true

    var body: some View {
        CanvasView(controller: controller)
            .navigationTitle(map.name)
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
            .inspector(isPresented: $showInspector) {
                InspectorView(controller: controller)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 440)
            }
            .focusedSceneValue(\.mapController, controller)
            .onAppear {
                DebugScript.activeController = controller
                consumeReveal()
                controller.focusCanvas()
            }
            .onChange(of: window.revealRequest) { consumeReveal() }
    }

    private var subtitle: String {
        let count = controller.workspace.placements(in: map.id).count
        return "\(count) node\(count == 1 ? "" : "s")"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if controller.selection.isEmpty { controller.addNode(atView: controller.viewCenter) }
                else { controller.addChild() }
            } label: {
                Label("Add Node", systemImage: "plus.rectangle.on.rectangle")
            }
            .help("Add a child to the selected node, or a new node (Tab)")

            Menu {
                ForEach(NodeKind.allCases) { kind in
                    Button { controller.setKind(kind) } label: { Label(kind.title, systemImage: kind.symbolName) }
                }
            } label: {
                Label("Type", systemImage: "square.on.circle")
            }
            .disabled(controller.selection.isEmpty)
            .help("Change the type of the selected nodes")

            Menu {
                Picker("Layout", selection: Binding(get: { controller.style }, set: { controller.setLayoutStyle($0) })) {
                    ForEach(LayoutStyle.allCases) { style in
                        Label(style.title, systemImage: style.symbolName).tag(style)
                    }
                }
                .pickerStyle(.inline)
                if controller.style != .free, !controller.tree.pinned.isEmpty {
                    Divider()
                    Button("Unpin All") { controller.unpinAll() }
                }
            } label: {
                Label("Layout", systemImage: controller.style.symbolName)
            }
            .help("Lay the map out automatically, or place nodes freely (⌥⌘1–5)")

            Toggle(isOn: Binding(get: { controller.isFocusMode }, set: { controller.isFocusMode = $0 })) {
                Label("Focus", systemImage: "scope")
            }
            .help("Focus mode: dim everything far from the selection (⇧⌘F)")

            Button { controller.zoomToFit() } label: {
                Label("Zoom to Fit", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("Zoom to Fit (⌘9)")

            Button { showInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector (⌃⌘I)")
        }
    }

    private func consumeReveal() {
        guard let request = window.revealRequest, request.mapID == map.id else { return }
        window.revealRequest = nil
        DispatchQueue.main.async { controller.reveal(request.nodeID) }
    }
}
