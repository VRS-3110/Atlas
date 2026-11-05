import Foundation

/// The before and after state of one record. `nil` means the record did not exist.
public struct Change {
    public let key: RecordKey
    public var before: (any EntityData)?
    public var after: (any EntityData)?

    public var isInsert: Bool { before == nil && after != nil }
    public var isDelete: Bool { before != nil && after == nil }
    var isNoOp: Bool { recordsHaveSameContent(before, after) }

    /// Typed access to the before/after values.
    public func values<V: EntityData>(_ type: V.Type) -> (before: V?, after: V?) {
        (before as? V, after as? V)
    }
}

/// One undoable step: everything a single command changed.
public struct ChangeSet {
    public let name: String
    public internal(set) var changes: [Change]
    let coalesceKey: String?
    /// Overrides the history's coalesce window for this step (`.infinity` keeps merging
    /// until coalescing is explicitly broken).
    var coalesceWindow: TimeInterval? = nil
    var date: Date

    public var keys: [RecordKey] { changes.map(\.key) }

    public func contains(kind: EntityKind) -> Bool {
        changes.contains { $0.key.kind == kind }
    }

    /// The same changes run backwards (used to describe an undo to observers).
    var inverted: ChangeSet {
        var copy = self
        copy.changes = changes.reversed().map { Change(key: $0.key, before: $0.after, after: $0.before) }
        return copy
    }

    /// Folds `later` into this change set, keeping the earliest `before` for each record.
    mutating func absorb(_ later: ChangeSet) {
        var index: [RecordKey: Int] = [:]
        for (i, change) in changes.enumerated() { index[change.key] = i }
        for change in later.changes {
            if let i = index[change.key] {
                changes[i].after = change.after
            } else {
                index[change.key] = changes.count
                changes.append(change)
            }
        }
        changes.removeAll { $0.isNoOp }
        date = later.date
    }
}

/// Why a change set was applied.
public enum ChangeOrigin: Sendable {
    case edit
    case undo
    case redo
}
