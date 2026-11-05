import AppKit
import AtlasCore
import Carbon.HIToolbox
import SwiftUI

/// The shortcuts quick capture can use from anywhere in macOS.
enum CaptureShortcut: String, CaseIterable, Identifiable {
    case optionSpace
    case controlOptionSpace
    case shiftCommandSpace
    case optionCommandC
    case off

    static let defaultsKey = "atlas.captureShortcut"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optionSpace: "⌥Space"
        case .controlOptionSpace: "⌃⌥Space"
        case .shiftCommandSpace: "⇧⌘Space"
        case .optionCommandC: "⌥⌘C"
        case .off: "Off"
        }
    }

    /// Carbon key code and modifiers.
    var carbon: (key: UInt32, modifiers: UInt32)? {
        switch self {
        case .optionSpace: (UInt32(kVK_Space), UInt32(optionKey))
        case .controlOptionSpace: (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .shiftCommandSpace: (UInt32(kVK_Space), UInt32(shiftKey | cmdKey))
        case .optionCommandC: (UInt32(kVK_ANSI_C), UInt32(optionKey | cmdKey))
        case .off: nil
        }
    }

    static var current: CaptureShortcut {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(CaptureShortcut.init(rawValue:)) ?? .optionSpace
    }
}

/// A system-wide hot key. Carbon's `RegisterEventHotKey` needs no Accessibility permission.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?

    /// Registers `shortcut`, replacing the previous one. Returns false if another app
    /// already owns that combination.
    @discardableResult
    func register(_ shortcut: CaptureShortcut) -> Bool {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        guard let (key, modifiers) = shortcut.carbon else { return true }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.shared.action?() } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x41544C53), id: 1) // "ATLS"
        let status = RegisterEventHotKey(key, modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        return status == noErr
    }
}

/// The floating capture panel. It takes keyboard focus without bringing Atlas's windows
/// forward, so capturing from Safari leaves Safari where it was.
@MainActor
final class QuickCapture {
    static let shared = QuickCapture()

    private var panel: CapturePanel?
    private(set) var lastShortcutFailed = false

    func start() {
        GlobalHotKey.shared.action = { [weak self] in self?.toggle() }
        applyShortcut()
    }

    func applyShortcut() {
        lastShortcutFailed = !GlobalHotKey.shared.register(CaptureShortcut.current)
    }

    func toggle() {
        if let panel, panel.isVisible { close() } else { show() }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: QuickCaptureView(workspace: AppStore.shared.workspace) { [weak self] in
            self?.close()
        })
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - frame.height * 0.28))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> CapturePanel {
        let panel = CapturePanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 210),
                                 styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.title = "Quick Capture"
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        return panel
    }
}

final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct QuickCaptureView: View {
    let workspace: Workspace
    let dismiss: () -> Void
    @State private var text = ""
    @State private var kind: NodeKind?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Quick Capture", systemImage: "tray.and.arrow.down").font(.headline)
                Spacer()
                Picker("Type", selection: $kind) {
                    Text("Automatic").tag(NodeKind?.none)
                    Divider()
                    ForEach(NodeKind.allCases) { kind in
                        Label(kind.title, systemImage: kind.symbolName).tag(NodeKind?.some(kind))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            TextEditor(text: $text)
                .font(.system(size: 14))
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("An idea, a question, a link or a DOI…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Capture text")
            HStack {
                Text("First line is the title · #tags · ends with ? for a question · [] for a task")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save to Inbox") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 560, height: 210)
        .onAppear { focused = true }
    }

    private func save() {
        if let node = workspace.capture(text, kind: kind) {
            DropImport.finish(node.id, workspace: workspace)
        }
        text = ""
        dismiss()
    }
}
