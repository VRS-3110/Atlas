import Foundation

/// Collects the records touched by one command. Every insert, update and delete in the
/// workspace goes through a transaction, which is what makes all edits undoable and saved.
///
///     workspace.perform("Rename") { tx in
///         tx.update(node) { $0.title = "New title" }
///     }
@MainActor
public final class Transaction {
    public let name: String
    let coalesceKey: String?
    var coalesceWindow: TimeInterval?
    unowned let workspace: Workspace

    struct Snapshot {
        let value: (any EntityData)?
    }

    /// The state of each touched record when the transaction first touched it.
    private(set) var initial: [RecordKey: Snapshot] = [:]
    /// Touched records in first-touch order.
    private(set) var touchOrder: [RecordKey] = []

    init(name: String, coalesceKey: String?, workspace: Workspace) {
        self.name = name
        self.coalesceKey = coalesceKey
        self.workspace = workspace
    }

    private func noteTouch(_ key: RecordKey) {
        guard initial[key] == nil else { return }
        initial[key] = Snapshot(value: workspace.currentRecord(key))
        touchOrder.append(key)
    }

    /// Adds a new record and returns its live entity.
    @discardableResult
    public func insert<V: EntityData>(_ value: V, id: UUID = UUID()) -> Entity<V> {
        if let existing = workspace.lookup(id, as: V.self) {
            update(existing) { $0 = value }
            return existing
        }
        noteTouch(RecordKey(kind: V.entityKind, id: id))
        let entity = Entity(id: id, data: value)
        workspace.store(entity)
        return entity
    }

    /// Mutates a record. Ignored if the entity is no longer in the workspace.
    public func update<V: EntityData>(_ entity: Entity<V>, _ mutate: (inout V) -> Void) {
        guard workspace.lookup(entity.id, as: V.self) === entity else { return }
        var copy = entity.data
        mutate(&copy)
        guard copy != entity.data else { return }
        noteTouch(entity.key)
        copy.didModify(at: workspace.clock())
        workspace.write(entity, copy)
    }

    /// Removes a record. Callers are responsible for removing dependants
    /// (see the higher-level operations on `Workspace`).
    public func delete<V: EntityData>(_ entity: Entity<V>) {
        guard workspace.lookup(entity.id, as: V.self) === entity else { return }
        noteTouch(entity.key)
        workspace.unstore(entity)
    }

    /// Records the before/after pairs for everything that actually changed.
    func changes() -> [Change] {
        touchOrder.compactMap { key in
            let change = Change(key: key, before: initial[key]?.value, after: workspace.currentRecord(key))
            return change.isNoOp ? nil : change
        }
    }

    /// Puts every touched record back the way it was.
    func rollBack() {
        for key in touchOrder.reversed() {
            workspace.setRecord(key, initial[key]?.value)
        }
    }
}
