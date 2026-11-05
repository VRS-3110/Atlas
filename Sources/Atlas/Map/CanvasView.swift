import AtlasCore
import SwiftUI

/// The infinite canvas: grid, frames, connectors, nodes, interaction feedback and the
/// inline title editors, with zoom controls, the minimap and the focus banner on top.
struct CanvasView: View {
    static let coordinateSpace = "atlas.canvas"

    let controller: MapController
    @FocusState private var titleFocused: Bool
    @FocusState private var frameTitleFocused: Bool
    @GestureState private var isDraggingBackground = false
    @AppStorage("atlas.showMinimap") private var showMinimap = true

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                GridBackground(controller: controller)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .local)
                            .updating($isDraggingBackground) { _, state, _ in state = true }
                            .onChanged { controller.backgroundDragChanged(start: $0.startLocation, location: $0.location) }
                            .onEnded { _ in controller.backgroundDragEnded() }
                    )
                    .onTapGesture(count: 2, coordinateSpace: .local) { controller.handleBackgroundDoubleClick(at: $0) }
                    .onTapGesture(count: 1, coordinateSpace: .local) { controller.handleBackgroundClick(at: $0) }
                    .accessibilityHidden(true)

                FrameLayer(controller: controller)
                EdgeLayer(controller: controller)
                NodeLayer(controller: controller)
                InteractionOverlay(controller: controller)
                HoverPreview(controller: controller)

                if controller.editingNodeID != nil {
                    TitleEditor(controller: controller, focused: $titleFocused)
                }
                if controller.editingFrameID != nil {
                    FrameTitleEditor(controller: controller, focused: $frameTitleFocused)
                }
            }
            .coordinateSpace(name: Self.coordinateSpace)
            .background(CanvasEventCatcher(controller: controller))
            .clipped()
            .onAppear { controller.canvasSize = geometry.size }
            .onChange(of: geometry.size) { _, size in controller.canvasSize = size }
            .onChange(of: isDraggingBackground) { _, dragging in
                if !dragging { controller.backgroundDragEnded() }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            ZoomControls(controller: controller, showMinimap: $showMinimap).padding(12)
        }
        .overlay(alignment: .bottomLeading) {
            if showMinimap, !controller.visibleIDs.isEmpty {
                MinimapView(controller: controller).padding(12)
            }
        }
        .overlay(alignment: .top) {
            if controller.isFocusMode {
                FocusBanner(controller: controller).padding(.top, 10)
            }
        }
        .overlay {
            if controller.visibleIDs.isEmpty {
                ContentUnavailableView("Empty Map", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("Double-click anywhere to add a node, or press Tab."))
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: DropImport.acceptedTypes, isTargeted: nil) { providers, location in
            Task {
                let items = await DropImport.load(providers)
                DropImport.addToMap(items, controller: controller, atView: location)
            }
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Map canvas")
    }
}

/// The text field shown over a node while its title is edited. It lives in view space
/// (not inside the zoomed layer) so the AppKit text field is never transformed.
private struct TitleEditor: View {
    let controller: MapController
    var focused: FocusState<Bool>.Binding

    var body: some View {
        if let id = controller.editingNodeID, let node = controller.workspace.nodes[id],
           let rect = controller.viewRect(id) {
            let zoom = controller.viewport.zoom
            let font = NodeMetrics.titleFont(isTopic: controller.isTopic(id), kind: node.kind)
            let width = max(rect.width, 200 * zoom, 120)
            TextField("Title", text: Binding(get: { node.title }, set: { controller.updateEditingTitle($0) }),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(Font(font.withSize(max(10, font.pointSize * zoom)) as CTFont))
                .lineLimit(1...10)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(width: width)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor, lineWidth: 2))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .position(x: rect.minX + width / 2, y: rect.midY)
                .focused(focused)
                .onSubmit { controller.commitEditing() }
                .onExitCommand { controller.cancelEditing() }
                .onKeyPress(.tab) {
                    controller.commitEditing()
                    controller.addChild()
                    return .handled
                }
                .onAppear {
                    DispatchQueue.main.async { focused.wrappedValue = true }
                }
                .onChange(of: focused.wrappedValue) { _, isFocused in
                    // Clicking elsewhere ends the edit, but only for this node's field.
                    if !isFocused, controller.editingNodeID == id { controller.commitEditing() }
                }
                .id(id)
        }
    }
}

/// The text field shown over a frame's title tab while it is renamed.
private struct FrameTitleEditor: View {
    let controller: MapController
    var focused: FocusState<Bool>.Binding

    var body: some View {
        if let id = controller.editingFrameID, let frame = controller.workspace.frames[id],
           let rect = controller.frameRect(frame) {
            let anchor = controller.viewport.viewPoint(controller.frameTitleAnchor(rect))
            let width: CGFloat = 220
            TextField("Group title", text: Binding(get: { frame.title }, set: { controller.renameFrame($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(width: width)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor, lineWidth: 2))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .position(x: anchor.x + width / 2 - 2, y: anchor.y)
                .focused(focused)
                .onSubmit { controller.endFrameEditing() }
                .onExitCommand { controller.endFrameEditing() }
                .onAppear {
                    DispatchQueue.main.async { focused.wrappedValue = true }
                }
                .onChange(of: focused.wrappedValue) { _, isFocused in
                    if !isFocused, controller.editingFrameID == id { controller.endFrameEditing() }
                }
                .id(id)
        }
    }
}

private struct ZoomControls: View {
    let controller: MapController
    @Binding var showMinimap: Bool

    var body: some View {
        HStack(spacing: 2) {
            Button { showMinimap.toggle() } label: {
                Image(systemName: showMinimap ? "map.fill" : "map").frame(width: 18, height: 18)
            }
            .help(showMinimap ? "Hide Minimap (⇧⌘M)" : "Show Minimap (⇧⌘M)")
            Divider().frame(height: 14)
            Button { controller.zoomOut() } label: { Image(systemName: "minus").frame(width: 18, height: 18) }
                .help("Zoom Out (⌘−)")
            Button { controller.actualSize() } label: {
                Text("\(Int((controller.viewport.zoom * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 42)
            }
            .help("Actual Size (⌘0)")
            Button { controller.zoomIn() } label: { Image(systemName: "plus").frame(width: 18, height: 18) }
                .help("Zoom In (⌘=)")
            Divider().frame(height: 14)
            Button { controller.zoomToFit() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 18, height: 18)
            }
            .help("Zoom to Fit (⌘9)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
    }
}
