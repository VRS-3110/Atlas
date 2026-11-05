import AppKit
import AtlasCore
import AtlasLayout

extension NSPasteboard.PasteboardType {
    /// Branches copied from an Atlas map (with their types, notes and connections).
    static let atlasBranches = NSPasteboard.PasteboardType(MapClipboard.pasteboardType)
}

/// Copy, cut, paste and duplicate. Copies go on the general pasteboard twice: as Atlas
/// branches, and as an indented outline of titles that other apps can paste. Text copied
/// from elsewhere pastes as an outline of new nodes.
extension MapController {

    /// Where copies go: the general pasteboard, or a private one named by
    /// `ATLAS_PASTEBOARD`, so scripted checks leave the clipboard alone.
    static let pasteboard: NSPasteboard = {
        if let name = ProcessInfo.processInfo.environment["ATLAS_PASTEBOARD"], !name.isEmpty {
            return NSPasteboard(name: NSPasteboard.Name(name))
        }
        return .general
    }()

    var canCopy: Bool { !selection.isEmpty }

    var canPaste: Bool {
        let types = Self.pasteboard.types ?? []
        return types.contains(.atlasBranches) || types.contains(.string)
    }

    func copySelection() {
        guard !selection.isEmpty else {
            NSSound.beep()
            return
        }
        commitEditingIfNeeded()
        let clip = workspace.copyBranches(selection, in: mapID, position: laidOutCenter)
        guard !clip.isEmpty, let data = try? JSONEncoder().encode(clip) else { return }
        let pasteboard = Self.pasteboard
        pasteboard.declareTypes([.atlasBranches, .string], owner: nil)
        pasteboard.setData(data, forType: .atlasBranches)
        pasteboard.setString(OutlineText.render(clip.outline), forType: .string)
    }

    func cutSelection() {
        guard !selection.isEmpty else {
            NSSound.beep()
            return
        }
        copySelection()
        deleteSelection(actionName: "Cut")
    }

    /// Pastes under the selected node, or as new free-standing branches in the middle of
    /// the view when nothing (or several nodes) is selected.
    func paste() {
        commitEditingIfNeeded()
        guard let clip = pasteboardClip() else {
            NSSound.beep()
            return
        }
        let parent = selection.count == 1 ? primarySelection : nil
        let origin = parent.map { childPosition(for: $0) } ?? worldPoint(viewCenter)
        let collapsed = parent.map { tree.collapsed.contains($0) } ?? false
        let mapID = self.mapID
        let tops = workspace.perform("Paste") { _ -> [UUID] in
            if let parent, collapsed { workspace.setCollapsed(false, nodeIDs: [parent], in: mapID) }
            return workspace.paste(clip, into: mapID, under: parent, origin: origin)
        }
        selectPasted(tops)
    }

    /// ⌘D: copies each selected branch in place, right after the original.
    func duplicateSelection() {
        commitEditingIfNeeded()
        let tops = selectedBranchRoots
        guard !tops.isEmpty else {
            NSSound.beep()
            return
        }
        let mapID = self.mapID
        let copies = workspace.perform("Duplicate") { _ -> [UUID] in
            var copies: [UUID] = []
            for top in tops {
                let clip = workspace.copyBranches([top], in: mapID, position: laidOutCenter)
                let parent = tree.parent[top]
                let origin = parent.map { siblingPosition(after: top, parent: $0) } ?? positionBelowTree(of: top)
                copies += workspace.paste(clip, into: mapID, under: parent, at: .after(top), origin: origin,
                                          actionName: "Duplicate")
            }
            return copies
        }
        selectPasted(copies)
    }

    /// What the general pasteboard holds, as branches to paste.
    private func pasteboardClip() -> MapClipboard? {
        let pasteboard = Self.pasteboard
        if let data = pasteboard.data(forType: .atlasBranches),
           let clip = try? JSONDecoder().decode(MapClipboard.self, from: data), !clip.isEmpty {
            return clip
        }
        if let text = pasteboard.string(forType: .string) {
            let outline = OutlineText.parse(text)
            if !outline.isEmpty { return MapClipboard(outline: outline, createdAt: workspace.clock()) }
        }
        return nil
    }

    /// For a copied root: a spot below everything in its tree.
    private func positionBelowTree(of root: UUID) -> CGPoint {
        let ids = [root] + tree.descendants(of: root).filter(visibleSet.contains)
        guard let bounds = Geometry.union(ids.compactMap(targetRect)), let rect = targetRect(root) else {
            return worldPoint(viewCenter)
        }
        return CGPoint(x: rect.midX, y: bounds.maxY + 80 + rect.height / 2)
    }

    /// Selects freshly pasted nodes and scrolls to them once they are on screen.
    private func selectPasted(_ ids: [UUID]) {
        guard let first = ids.first else { return }
        setSelection(Set(ids), primary: first)
        ensureVisible(first)
        focusCanvas()
    }
}
