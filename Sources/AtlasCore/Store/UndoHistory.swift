import Foundation
import Observation

/// Workspace-wide undo and redo stacks. One history is shared by every window, so undoing
/// in one window reverts a change made in another.
@MainActor
@Observable
public final class UndoHistory {
    public private(set) var undoStack: [ChangeSet] = []
    public private(set) var redoStack: [ChangeSet] = []

    /// Maximum number of steps kept.
    public var limit = 300
    /// Edits sharing a coalesce key merge into one step while they keep arriving within
    /// this many seconds of each other (typing into a field, nudging with arrow keys).
    public var coalesceWindow: TimeInterval = 3

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoActionName: String? { undoStack.last?.name }
    public var redoActionName: String? { redoStack.last?.name }

    func record(_ set: ChangeSet) {
        redoStack.removeAll()
        if let key = set.coalesceKey, var top = undoStack.last, top.coalesceKey == key,
           set.date.timeIntervalSince(top.date) <= (set.coalesceWindow ?? coalesceWindow) {
            top.absorb(set)
            undoStack.removeLast()
            if !top.changes.isEmpty { undoStack.append(top) }
            return
        }
        undoStack.append(set)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
    }

    func popUndo() -> ChangeSet? { undoStack.popLast() }
    func popRedo() -> ChangeSet? { redoStack.popLast() }

    func pushRedo(_ set: ChangeSet) { redoStack.append(set) }

    func pushUndoAfterRedo(_ set: ChangeSet) {
        undoStack.append(set)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
    }

    /// Ends coalescing so the next edit starts a new undo step.
    public func breakCoalescing() {
        guard var top = undoStack.popLast() else { return }
        top = ChangeSet(name: top.name, changes: top.changes, coalesceKey: nil, date: top.date)
        undoStack.append(top)
    }

    public func removeAll() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
