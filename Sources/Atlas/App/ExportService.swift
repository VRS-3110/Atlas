import AppKit
import AtlasCore
import AtlasLayout
import SwiftUI
import UniformTypeIdentifiers

/// The map drawn for export: frames, connectors, relations and nodes as they are laid out
/// on screen (collapsed branches stay collapsed), without selection, focus dimming, the
/// grid or the minimap.
struct MapSnapshotView: View {
    let controller: MapController
    let bounds: CGRect

    var body: some View {
        let scene = Self.plainScene(controller.edgeScene())
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(nsColor: .textBackgroundColor))
            ZStack(alignment: .topLeading) {
                ForEach(controller.mapFrames, id: \.id) { frame in
                    if let rect = controller.frameRect(frame) { SnapshotFrame(frame: frame, rect: rect) }
                }
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            .offset(x: -bounds.minX, y: -bounds.minY)
            Canvas { context, _ in
                context.translateBy(x: -bounds.minX, y: -bounds.minY)
                SnapshotEdges.draw(scene, in: &context)
            }
            .frame(width: bounds.width, height: bounds.height)
            ZStack(alignment: .topLeading) {
                ForEach(controller.visibleIDs, id: \.self) { id in
                    if let node = controller.workspace.nodes[id], let rect = controller.worldRect(id) {
                        NodeCard(data: node.data, size: rect.size, isTopic: controller.isTopic(id), isSelected: false)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            .offset(x: -bounds.minX, y: -bounds.minY)
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .light)
    }

    /// Everything at full strength: export ignores focus mode, hover and selection.
    static func plainScene(_ scene: EdgeScene) -> EdgeScene {
        var plain = scene
        for i in plain.connectors.indices { plain.connectors[i].opacity = 1 }
        for i in plain.relations.indices {
            plain.relations[i].opacity = 1
            plain.relations[i].emphasis = .normal
        }
        return plain
    }
}

private struct SnapshotFrame: View {
    let frame: MapFrame
    let rect: CGRect

    var body: some View {
        let tint = frame.color.color
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(tint.opacity(0.06))
                .overlay(shape.strokeBorder(tint.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])))
                .frame(width: rect.width, height: rect.height)
            Text(frame.title.isEmpty ? "Untitled Group" : frame.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(tint.opacity(0.16)))
                .fixedSize()
                .padding(.leading, 10)
                .padding(.top, 4)
        }
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .position(x: rect.midX, y: rect.midY)
    }
}

/// The same drawing as the live edge canvas, without a viewport transform.
enum SnapshotEdges {
    static func draw(_ scene: EdgeScene, in context: inout GraphicsContext) {
        for connector in scene.connectors {
            let g = connector.geometry
            var path = Path()
            path.move(to: g.start)
            path.addCurve(to: g.end, control1: g.control1, control2: g.control2)
            context.stroke(path, with: .color(connector.color),
                           style: StrokeStyle(lineWidth: connector.width, lineCap: .round))
        }
        for relation in scene.relations {
            let curve = relation.curve
            var path = Path()
            path.move(to: curve.start)
            path.addQuadCurve(to: curve.end, control: curve.control)
            let dash: [CGFloat] = switch relation.style {
            case .solid: []
            case .dashed: [7, 5]
            case .dotted: [1.5, 4]
            }
            context.stroke(path, with: .color(relation.color),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: dash))
            if relation.hasArrow {
                let angle = atan2(curve.end.y - curve.control.y, curve.end.x - curve.control.x)
                let spread: CGFloat = .pi / 7, length: CGFloat = 9
                var head = Path()
                head.move(to: curve.end)
                head.addLine(to: CGPoint(x: curve.end.x - length * cos(angle - spread), y: curve.end.y - length * sin(angle - spread)))
                head.addLine(to: CGPoint(x: curve.end.x - length * cos(angle + spread), y: curve.end.y - length * sin(angle + spread)))
                head.closeSubpath()
                context.fill(head, with: .color(relation.color))
            }
            if !relation.label.isEmpty {
                let text = context.resolve(Text(relation.label).font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(relation.color))
                let size = text.measure(in: CGSize(width: 240, height: 40))
                let boxSize = CGSize(width: size.width + 10, height: size.height + 4)
                let centre = Geometry.labelCenter(on: curve, size: boxSize, avoiding: relation.ends)
                let box = Geometry.rect(center: centre, size: boxSize)
                context.fill(Path(roundedRect: box, cornerRadius: box.height / 2),
                             with: .color(Color(nsColor: .textBackgroundColor).opacity(0.92)))
                context.stroke(Path(roundedRect: box, cornerRadius: box.height / 2),
                               with: .color(relation.color.opacity(0.4)), lineWidth: 0.8)
                context.draw(text, at: centre)
            }
        }
    }
}

enum MapExportFormat: String, CaseIterable, Identifiable {
    case png, pdf, markdown, opml

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png: "PNG Image…"
        case .pdf: "PDF…"
        case .markdown: "Markdown Outline…"
        case .opml: "OPML…"
        }
    }

    var contentType: UTType {
        switch self {
        case .png: .png
        case .pdf: .pdf
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .opml: UTType(filenameExtension: "opml") ?? .xml
        }
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .pdf: "pdf"
        case .markdown: "md"
        case .opml: "opml"
        }
    }

    init?(argument: String) {
        switch argument.lowercased() {
        case "png": self = .png
        case "pdf": self = .pdf
        case "md", "markdown": self = .markdown
        case "opml": self = .opml
        default: return nil
        }
    }
}

/// Map export, outline import, and workspace backup and restore. File panels attach to the
/// key window as sheets.
@MainActor
enum ExportService {
    /// Space around the map in images and PDFs.
    static let margin: CGFloat = 40
    /// Images are capped so a huge map still produces a file (and memory) of sensible size.
    static let maxPixels: CGFloat = 16_384

    static func bounds(of controller: MapController) -> CGRect? {
        let rects = controller.visibleIDs.compactMap(controller.worldRect)
            + controller.mapFrames.compactMap(controller.frameRect)
        guard let union = Geometry.union(rects) else { return nil }
        return union.insetBy(dx: -margin, dy: -margin).integral
    }

    /// Exports always use the light appearance, so they print and share well.
    static func data(for format: MapExportFormat, controller: MapController) -> Data? {
        var result: Data?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            result = render(format, controller: controller)
        }
        return result
    }

    private static func render(_ format: MapExportFormat, controller: MapController) -> Data? {
        let workspace = controller.workspace
        switch format {
        case .markdown: return Data(workspace.markdown(for: controller.mapID).utf8)
        case .opml: return Data(workspace.opml(for: controller.mapID).utf8)
        case .png, .pdf:
            guard let bounds = bounds(of: controller) else { return nil }
            let renderer = ImageRenderer(content: MapSnapshotView(controller: controller, bounds: bounds))
            renderer.proposedSize = ProposedViewSize(bounds.size)
            if format == .png {
                renderer.scale = min(2, maxPixels / max(bounds.width, bounds.height))
                guard let image = renderer.cgImage else { return nil }
                return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            }
            let output = NSMutableData()
            renderer.render { size, draw in
                var box = CGRect(origin: .zero, size: size)
                guard let consumer = CGDataConsumer(data: output as CFMutableData),
                      let pdf = CGContext(consumer: consumer, mediaBox: &box,
                                          [kCGPDFContextTitle: controller.map.name] as CFDictionary)
                else { return }
                pdf.beginPDFPage(nil)
                draw(pdf)
                pdf.endPDFPage()
                pdf.closePDF()
            }
            return output.length > 0 ? output as Data : nil
        }
    }

    static func exportMap(_ controller: MapController, as format: MapExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(safeName(controller.map.name)).\(format.fileExtension)"
        panel.canCreateDirectories = true
        present(panel) { url in
            guard let data = data(for: format, controller: controller) else {
                showError("Atlas could not export this map.", detail: "The map is empty.")
                return
            }
            do { try data.write(to: url, options: .atomic) } catch {
                showError("Atlas could not save the export.", detail: error.localizedDescription)
            }
        }
    }

    static func importOutline(into workspace: Workspace, window: WindowState?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "opml"), UTType(filenameExtension: "md"), .plainText]
            .compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.message = "Choose an OPML, Markdown or text outline. It becomes a new map."
        present(panel) { url in
            guard let data = try? Data(contentsOf: url) else { return }
            let (title, items) = OPML.items(fromFile: data)
            let name = title.isEmpty ? url.deletingPathExtension().lastPathComponent : title
            guard let map = workspace.importOutline(items, named: name) else {
                showError("There is nothing to import.", detail: "\(url.lastPathComponent) has no outline items.")
                return
            }
            window?.selection = .map(map.id)
        }
    }

    // MARK: Backup and restore

    static var backupType: UTType {
        UTType(filenameExtension: WorkspaceBackup.fileExtension, conformingTo: .json) ?? .json
    }

    static func backUp(_ workspace: Workspace) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [backupType]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "Atlas Backup \(formatter.string(from: Date())).\(WorkspaceBackup.fileExtension)"
        panel.canCreateDirectories = true
        present(panel) { url in
            do {
                try workspace.backupData().write(to: url, options: .atomic)
            } catch {
                showError("Atlas could not back up the workspace.", detail: error.localizedDescription)
            }
        }
    }

    static func restore(_ workspace: Workspace) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [backupType, .json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an Atlas workspace backup."
        present(panel) { url in
            do {
                let contents = try WorkspaceBackup.decode(Data(contentsOf: url))
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Replace the workspace with this backup?"
                var detail = "The backup holds \(contents.mapCount) map\(contents.mapCount == 1 ? "" : "s") and \(contents.nodeCount) node\(contents.nodeCount == 1 ? "" : "s")"
                if let date = contents.createdAt {
                    detail += ", made \(date.formatted(date: .abbreviated, time: .shortened))"
                }
                detail += ". Everything in Atlas now is replaced and undo history is cleared. A copy of the current workspace is kept in the Backups folder first."
                alert.informativeText = detail
                alert.addButton(withTitle: "Replace Workspace")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                let report = try workspace.restoreBackup(contents)
                if report.skippedRecords > 0 {
                    showError("Restored, with \(report.skippedRecords) item\(report.skippedRecords == 1 ? "" : "s") skipped.",
                              detail: "Some records in the backup could not be read by this version of Atlas.",
                              style: .informational)
                }
            } catch {
                showError("Atlas could not restore this backup.", detail: error.localizedDescription)
            }
        }
    }

    // MARK: Helpers

    private static func present(_ panel: NSSavePanel, then action: @escaping (URL) -> Void) {
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            action(url)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    static func showError(_ message: String, detail: String, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Map" : cleaned
    }
}
