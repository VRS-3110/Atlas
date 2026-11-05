import AppKit
import AtlasCore
import Foundation
import Observation

/// Shares tasks with JourneyMan through ~/Documents/JourneyMan/atlas while sharing is on
/// (Settings ▸ JourneyMan). Writes tasks.json shortly after tasks change, and reads
/// journeyman.json when JourneyMan has rewritten it: at launch, whenever Atlas becomes
/// active, and every 30 seconds. The rules are in `JourneyManLink`.
@MainActor
@Observable
final class JourneyManSync {
    static let shared = JourneyManSync()
    static let enabledKey = "journeyMan.sharing"
    static let addressKey = "journeyMan.address"

    private(set) var lastWritten: Date?
    private(set) var lastRead: Date?
    private(set) var lastReport: JourneyManLink.ApplyReport?
    private(set) var problem: String?
    /// Where JourneyMan said it runs, in the last journeyman.json read.
    private(set) var reportedAddress: String?

    @ObservationIgnored private weak var workspace: Workspace?
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var writtenTasks: [JourneyManLink.TaskEntry]?
    @ObservationIgnored private var readModificationDate: Date?

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var folder: URL { JourneyManLink.defaultFolder }

    /// JourneyMan's address: the one typed in Settings, else the one JourneyMan reported.
    var address: String? {
        let typed = UserDefaults.standard.string(forKey: Self.addressKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !typed.isEmpty { return typed }
        if let reportedAddress, !reportedAddress.isEmpty { return reportedAddress }
        return nil
    }

    /// The JourneyMan page for a task, while sharing is on and JourneyMan's address is known.
    func taskURL(for nodeID: UUID) -> URL? {
        guard isEnabled, let address else { return nil }
        return JourneyManLink.journeyManURL(for: nodeID, appURL: address)
    }

    var statusText: String {
        guard isEnabled else { return "Off" }
        var parts: [String] = []
        if let lastWritten {
            parts.append("Tasks shared at \(lastWritten.formatted(date: .omitted, time: .shortened))")
        }
        if let lastRead {
            var text = "JourneyMan read at \(lastRead.formatted(date: .omitted, time: .shortened))"
            if let lastReport, !lastReport.isEmpty { text += " (\(lastReport.summary))" }
            parts.append(text)
        } else {
            parts.append("Nothing from JourneyMan yet")
        }
        return parts.joined(separator: " · ")
    }

    /// Called once at launch.
    func start(with workspace: Workspace) {
        self.workspace = workspace
        workspace.addChangeObserver(self) { [weak self] set, _ in
            guard let self, self.isEnabled,
                  set.contains(kind: .node) || set.contains(kind: .map) || set.contains(kind: .placement) else { return }
            self.scheduleWrite()
        }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        syncNow()
    }

    /// Call when the Settings toggle changes.
    func sharingChanged() {
        writtenTasks = nil
        readModificationDate = nil
        problem = nil
        if isEnabled { syncNow() }
    }

    /// Reads journeyman.json if JourneyMan rewrote it, then writes tasks.json if tasks changed.
    func syncNow() {
        guard isEnabled, let workspace else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try readIfChanged(workspace)
            try writeIfChanged(workspace)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Writes any change still waiting (at quit).
    func flush() {
        guard pendingWrite != nil else { return }
        pendingWrite?.cancel()
        pendingWrite = nil
        writeNow()
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    private func readIfChanged(_ workspace: Workspace) throws {
        let url = folder.appendingPathComponent(JourneyManLink.journeyManFileName)
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return // JourneyMan has not written yet
        }
        guard modified != readModificationDate else { return }
        let file = try JourneyManLink.decodeJourneyMan(Data(contentsOf: url))
        readModificationDate = modified
        reportedAddress = file.appUrl
        let report = JourneyManLink.apply(file, to: workspace)
        lastRead = Date()
        if !report.isEmpty { lastReport = report }
    }

    private func writeIfChanged(_ workspace: Workspace) throws {
        let file = JourneyManLink.taskFile(from: workspace, exportedAt: Date())
        guard file.tasks != writtenTasks else { return }
        let url = folder.appendingPathComponent(JourneyManLink.tasksFileName)
        try JourneyManLink.encode(file).write(to: url, options: .atomic)
        writtenTasks = file.tasks
        lastWritten = Date()
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        pendingWrite = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pendingWrite = nil
            self.writeNow()
        }
    }

    private func writeNow() {
        guard isEnabled, let workspace else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeIfChanged(workspace)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}
