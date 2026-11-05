import AppKit
import AtlasCore

/// Citations, tasks and templates for the nodes on the map.
extension MapController {
    /// Copies the primary selection's citation (a source's reference, or a quote with its
    /// in-text citation). Returns false when there is nothing to cite.
    @discardableResult
    func copyCitation() -> Bool {
        guard let id = primarySelection ?? selection.first, let text = workspace.citationText(for: id) else {
            NSSound.beep()
            return false
        }
        Self.pasteboard.clearContents()
        Self.pasteboard.setString(text, forType: .string)
        return true
    }

    var canCite: Bool {
        guard let id = primarySelection ?? selection.first, let node = workspace.nodes[id] else { return false }
        return node.source != nil || !node.citations.isEmpty
    }

    /// Whether every selected node is already a task.
    var selectionIsTask: Bool {
        !selection.isEmpty && selection.allSatisfy { workspace.nodes[$0]?.task != nil }
    }

    /// ⌘T: makes the selected nodes tasks, or (when they all are) plain nodes again.
    /// Nodes of the Task type stay tasks.
    func toggleTask() {
        guard !selection.isEmpty else { return }
        if selectionIsTask {
            workspace.updateNodes(selection.filter { workspace.nodes[$0]?.kind != .task }, "Remove Task") { $0.task = nil }
        } else {
            workspace.convertToTasks(selection)
        }
    }

    /// Inserts a template under the primary selection, or at the centre of the view.
    func insertTemplate(_ template: ResearchTemplate) {
        commitEditingIfNeeded()
        let sources = selection.filter { workspace.nodes[$0]?.source != nil }
        let parent = primarySelection.flatMap { workspace.nodes[$0]?.source == nil ? $0 : nil }
        let position = parent == nil ? worldPoint(viewCenter) : nil
        guard let root = workspace.insertTemplate(template, in: mapID, under: parent, at: position,
                                                  sources: template == .literatureReview ? Array(sources) : []) else { return }
        select(root)
        fitIfOutOfView()
    }
}
