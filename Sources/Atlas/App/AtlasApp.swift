import AppKit
import AtlasCore
import SwiftUI

@main
struct AtlasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let store = AppStore.shared

    var body: some Scene {
        // Each window remembers which page it shows, so a map can sit in one window
        // and Today in another.
        WindowGroup("Atlas", for: SidebarItem.self) { $item in
            RootView(initialItem: item)
                .environment(store.workspace)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            AtlasCommands(workspace: store.workspace)
            SidebarCommands()
            InspectorCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

/// Owns the single workspace shared by every window.
@MainActor
final class AppStore {
    static let shared = AppStore()

    let workspace: Workspace
    /// Set when the workspace file could not be opened; shown once in the first window.
    private(set) var loadProblem: String?

    private init() {
        let url = Workspace.defaultStoreURL
        do {
            let (workspace, report) = try Workspace.open(at: url)
            self.workspace = workspace
            workspace.migrateLayoutsIfNeeded()
            workspace.tracksDailyLog = true
            if report.unreadableRecords > 0 {
                loadProblem = "\(report.unreadableRecords) saved item(s) could not be read and were left untouched in the file."
            }
            let seededKey = "atlas.seededWelcome.\(url.path)"
            if workspace.maps.isEmpty, workspace.nodes.isEmpty, !UserDefaults.standard.bool(forKey: seededKey) {
                workspace.populateWelcomeContent()
                UserDefaults.standard.set(true, forKey: seededKey)
            }
        } catch {
            workspace = Workspace()
            workspace.populateWelcomeContent()
            loadProblem = "Atlas could not open its workspace at \(url.path) (\(error)). Changes made now will not be saved."
        }
    }

    func takeLoadProblem() -> String? {
        defer { loadProblem = nil }
        return loadProblem
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppStore.shared.workspace.persistence?.makeDailyBackupIfNeeded()
        QuickCapture.shared.start()
        DebugSnapshot.scheduleIfRequested()
        DebugScript.scheduleIfRequested()
    }

    func applicationWillTerminate(_ notification: Notification) {
        FocusTimer.shared.stop(workspace: AppStore.shared.workspace)
        AppStore.shared.workspace.saveNow()
    }

    func applicationDidResignActive(_ notification: Notification) {
        AppStore.shared.workspace.saveNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
