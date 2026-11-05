import AppKit
import AtlasCore
import AtlasLayout
import SwiftUI

struct MapControllerKey: FocusedValueKey {
    typealias Value = MapController
}

struct WindowStateKey: FocusedValueKey {
    typealias Value = WindowState
}

extension FocusedValues {
    var mapController: MapController? {
        get { self[MapControllerKey.self] }
        set { self[MapControllerKey.self] = newValue }
    }

    var windowState: WindowState? {
        get { self[WindowStateKey.self] }
        set { self[WindowStateKey.self] = newValue }
    }
}

/// Menu bar commands. Map commands act on the map in the key window.
struct AtlasCommands: Commands {
    let workspace: Workspace
    @FocusedValue(\.mapController) private var map: MapController?
    @FocusedValue(\.windowState) private var window: WindowState?
    @Environment(\.openWindow) private var openWindow
    @AppStorage("atlas.showMinimap") private var showMinimap = true

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Map") { newMap() }
                .keyboardShortcut("n")
            Menu("New Map from Template") {
                ForEach(ResearchTemplate.allCases) { template in
                    Button(template.title) { newMap(from: template) }
                }
            }
            Button("New Window") { openWindow(value: window?.selection ?? .today) }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Quick Capture…") { QuickCapture.shared.show() }
                .help("Also available from anywhere in macOS with the capture shortcut set in Settings")
        }

        CommandGroup(replacing: .importExport) {
            Menu("Export Map") {
                ForEach(MapExportFormat.allCases) { format in
                    Button(format.title) { if let map { ExportService.exportMap(map, as: format) } }
                }
            }
            .disabled(map == nil)
            Button("Import Outline…") { ExportService.importOutline(into: workspace, window: window) }
            Divider()
            Button("Back Up Workspace…") { ExportService.backUp(workspace) }
            Button("Restore from Backup…") { ExportService.restore(workspace) }
        }

        CommandGroup(replacing: .undoRedo) {
            Button(workspace.history.undoActionName.map { "Undo \($0)" } ?? "Undo") { undo() }
                .keyboardShortcut("z")
            Button(workspace.history.redoActionName.map { "Redo \($0)" } ?? "Redo") { redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }

        CommandMenu("Node") {
            Button("Add Child  (Tab)") { map?.addChild() }
                .disabled(map == nil)
            Button("Add Sibling  (Return)") { map?.addSibling() }
                .disabled(map == nil)
            Button("Edit Title  (Space)") { map?.beginEditing() }
                .disabled(map == nil)
            Button("Duplicate") { map?.duplicateSelection() }
                .keyboardShortcut("d")
                .disabled(map?.canCopy != true)
            Divider()
            Button("Indent") { map?.indentSelection() }
                .keyboardShortcut("]")
                .disabled(map?.selection.isEmpty != false)
            Button("Outdent  (⇧Tab)") { map?.outdentSelection() }
                .keyboardShortcut("[")
                .disabled(map?.selection.isEmpty != false)
            Button("Move Up") { map?.moveSelection(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(map?.selection.isEmpty != false)
            Button("Move Down") { map?.moveSelection(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(map?.selection.isEmpty != false)
            Divider()
            Button("Connect Selected Nodes") { map?.connectSelection() }
                .keyboardShortcut("l")
                .disabled(map?.canConnectSelection != true)
            Button("Collapse or Expand Branch") { map?.toggleCollapse() }
                .keyboardShortcut(".")
                .disabled(map == nil)
            Menu("Type") {
                ForEach(Array(NodeKind.allCases.enumerated()), id: \.element) { index, kind in
                    Button(kind.title) { map?.setKind(kind) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .control])
                }
            }
            .disabled(map == nil)
            Menu("Insert Template") {
                ForEach(ResearchTemplate.allCases) { template in
                    Button(template.title) { map?.insertTemplate(template) }
                }
            }
            .disabled(map == nil)
            Divider()
            Button(map?.selectionIsTask == true ? "Remove Task" : "Make Task") { map?.toggleTask() }
                .keyboardShortcut("t")
                .disabled(map?.selection.isEmpty != false)
            Button("Copy Citation") { map?.copyCitation() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(map?.canCite != true)
            Divider()
            Button("Delete  (⌫)") { map?.deleteSelection() }
                .disabled(map == nil)
        }

        CommandMenu("Arrange") {
            ForEach(Array(LayoutStyle.allCases.enumerated()), id: \.element) { index, style in
                Toggle(style.title, isOn: Binding(get: { map?.style == style },
                                                  set: { if $0 { map?.setLayoutStyle(style) } }))
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
            }
            .disabled(map == nil)
            Divider()
            Menu("Align") {
                ForEach(Arrange.Alignment.allCases) { alignment in
                    Button(alignment.title) { map?.align(alignment) }
                }
            }
            .disabled(map?.canAlign != true)
            Menu("Distribute") {
                ForEach(Arrange.Axis.allCases) { axis in
                    Button(axis.title) { map?.distribute(axis) }
                }
            }
            .disabled(map?.canDistribute != true)
            Divider()
            Button("Group") { map?.groupSelection() }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(map?.canGroup != true)
            Button("Ungroup") { map?.ungroup() }
                .keyboardShortcut("g", modifiers: [.command, .option, .shift])
                .disabled(map?.canUngroup != true)
            Divider()
            Button(map?.selectionIsPinned == true ? "Unpin" : "Pin in Place") { map?.togglePin() }
                .disabled(map?.canPin != true)
            Button("Unpin All") { map?.unpinAll() }
                .disabled(map.map { $0.style == .free || $0.tree.pinned.isEmpty } ?? true)
        }

        CommandGroup(after: .sidebar) {
            Button("Zoom In") { map?.zoomIn() }
                .keyboardShortcut("=")
                .disabled(map == nil)
            Button("Zoom Out") { map?.zoomOut() }
                .keyboardShortcut("-")
                .disabled(map == nil)
            Button("Actual Size") { map?.actualSize() }
                .keyboardShortcut("0")
                .disabled(map == nil)
            Button("Zoom to Fit") { map?.zoomToFit() }
                .keyboardShortcut("9")
                .disabled(map == nil)
            Divider()
            Toggle("Focus Mode", isOn: Binding(get: { map?.isFocusMode == true }, set: { map?.isFocusMode = $0 }))
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(map == nil)
            Menu("Focus Depth") {
                ForEach(1...6, id: \.self) { hops in
                    Toggle("\(hops) Hop\(hops == 1 ? "" : "s")", isOn: Binding(get: { map?.focusHops == hops },
                                                                          set: { if $0 { map?.focusHops = hops } }))
                }
            }
            .disabled(map == nil)
            Toggle("Show Minimap", isOn: $showMinimap)
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Divider()
        }

        CommandMenu("Go") {
            ForEach(Array([SidebarItem.inbox, .today, .week, .sources, .tags, .review].enumerated()), id: \.offset) { index, item in
                Button(item.title) { window?.selection = item }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                    .disabled(window == nil)
            }
            Divider()
            Button("Command Palette…") { window?.isPaletteVisible.toggle() }
                .keyboardShortcut("k")
                .disabled(window == nil)
            Divider()
            Button("Open in New Window") {
                if let item = window?.selection { openWindow(value: item) }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(window?.selection == nil)
        }
    }

    private func newMap(from template: ResearchTemplate) {
        let map = workspace.createMap(from: template)
        if let window { window.selection = .map(map.id) } else { openWindow(value: SidebarItem.map(map.id)) }
    }

    private func newMap() {
        let map = workspace.createMap(named: "Untitled Map")
        if let window {
            window.selection = .map(map.id)
        } else {
            openWindow(value: SidebarItem.map(map.id))
        }
    }

    /// While a text field is being edited, ⌘Z undoes typing; otherwise it undoes the last
    /// workspace change and selects what it touched in the key window's map.
    private func undo() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isEditable,
           text.undoManager?.canUndo == true {
            text.undoManager?.undo()
        } else if let set = workspace.undo() {
            map?.selectAfterHistoryStep(set)
        }
    }

    private func redo() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isEditable,
           text.undoManager?.canRedo == true {
            text.undoManager?.redo()
        } else if let set = workspace.redo() {
            map?.selectAfterHistoryStep(set)
        }
    }
}
