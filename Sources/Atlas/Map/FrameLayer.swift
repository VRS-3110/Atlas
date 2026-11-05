import AtlasCore
import SwiftUI

/// Labelled frames drawn behind the nodes they group. A frame follows its members, so it
/// never needs resizing; its title tab selects it, drags the group, or renames it.
struct FrameLayer: View {
    let controller: MapController

    var body: some View {
        let viewport = controller.viewport
        FrameLayerContent(controller: controller)
            .scaleEffect(viewport.zoom, anchor: .topLeading)
            .offset(x: viewport.offset.x, y: viewport.offset.y)
    }
}

private struct FrameLayerContent: View {
    let controller: MapController

    var body: some View {
        let selected = controller.selectedFrameID
        let editing = controller.editingFrameID
        ZStack(alignment: .topLeading) {
            ForEach(controller.mapFrames, id: \.id) { frame in
                if let rect = controller.frameRect(frame) {
                    FrameView(frame: frame, rect: rect, controller: controller,
                              isSelected: selected == frame.id, isEditing: editing == frame.id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct FrameView: View {
    let frame: MapFrame
    let rect: CGRect
    let controller: MapController
    let isSelected: Bool
    let isEditing: Bool

    @GestureState private var isDragging = false

    var body: some View {
        let tint = frame.color.color
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let dimmed = controller.focusedIDs.map { focused in !frame.nodeIDs.contains(where: focused.contains) } ?? false
        ZStack(alignment: .topLeading) {
            shape.fill(tint.opacity(0.06))
                .overlay(shape.strokeBorder(tint.opacity(isSelected ? 0.95 : 0.45),
                                            style: StrokeStyle(lineWidth: isSelected ? 2 : 1.2, dash: isSelected ? [] : [6, 4])))
                .frame(width: rect.width, height: rect.height)
                .allowsHitTesting(false)
                .position(x: rect.midX, y: rect.midY)

            titleTab(tint)
                .frame(width: max(rect.width - 20, 20), alignment: .leading)
                .position(x: rect.midX, y: controller.frameTitleAnchor(rect).y)
        }
        .opacity(dimmed ? 0.3 : 1)
    }

    private func titleTab(_ tint: Color) -> some View {
        Text(frame.title.isEmpty ? "Untitled Group" : frame.title)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(frame.title.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(isSelected ? 0.28 : 0.16)))
            .fixedSize()
            .opacity(isEditing ? 0 : 1)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(CanvasView.coordinateSpace))
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { controller.frameDragChanged(frame.id, translation: $0.translation) }
                    .onEnded { _ in controller.dragEnded() }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { controller.beginFrameEditing(frame.id) })
            .simultaneousGesture(TapGesture().onEnded { controller.selectFrame(frame.id) })
            .onChange(of: isDragging) { _, dragging in
                if !dragging { controller.dragEnded() }
            }
            .contextMenu {
                Button("Rename") { controller.beginFrameEditing(frame.id) }
                Menu("Colour") {
                    ForEach(NodeColor.allCases) { color in
                        Button(color.title) {
                            controller.selectFrame(frame.id)
                            controller.setFrameColor(color)
                        }
                    }
                }
                Button("Select Nodes") { controller.selectMembers(of: frame.id) }
                Divider()
                Button("Ungroup") {
                    controller.selectFrame(frame.id)
                    controller.ungroup()
                }
            }
            .help("Drag to move the group; double-click to rename")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Group: \(frame.title)")
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
