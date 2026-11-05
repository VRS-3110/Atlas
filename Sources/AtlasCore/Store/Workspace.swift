import CoreGraphics
import Foundation
import Observation

/// The single shared store behind every window and view. Entities are observable objects,
/// so a rename in the planner updates the map, the inspector and the sources library at once.
@MainActor
@Observable
public final class Workspace {
    // MARK: Tables

    public internal(set) var nodes: [UUID: Node] = [:]
    public internal(set) var edges: [UUID: GraphEdge] = [:]
    public internal(set) var maps: [UUID: MindMap] = [:]
    public internal(set) var placements: [UUID: Placement] = [:]
    public internal(set) var frames: [UUID: MapFrame] = [:]
    public internal(set) var dayLogs: [UUID: DayLog] = [:]

    // MARK: Indices (kept in step with the tables)

    /// mapID → nodeID → placement.
    public internal(set) var placementsByMap: [UUID: [UUID: Placement]] = [:]
    /// nodeID → ids of its placements (one per map the node is on).
    public internal(set) var placementIDsByNode: [UUID: Set<UUID>] = [:]
    /// nodeID → ids of the edges touching it.
    public internal(set) var edgeIDsByNode: [UUID: Set<UUID>] = [:]
    /// mapID → ids of its frames.
    public internal(set) var frameIDsByMap: [UUID: Set<UUID>] = [:]

    /// Increments every time a change set is applied (edit, undo or redo).
    public private(set) var revision = 0

    public let history = UndoHistory()

    @ObservationIgnored public internal(set) var persistence: PersistenceController?
    @ObservationIgnored var activeTransaction: Transaction?
    @ObservationIgnored private var observers: [ObserverEntry] = []
    /// Entities taken out of the tables, held weakly so that undoing the removal brings back
    /// the very same object, and views still holding it keep working.
    @ObservationIgnored private var retired: [RecordKey: WeakEntity] = [:]
    /// Injectable clock, so tests can control timestamps.
    @ObservationIgnored public var clock: () -> Date = { Date() }
    /// When on, every edit adds the nodes it touched to today's daily log (in the same undo
    /// step). The app turns it on; tests opt in.
    @ObservationIgnored public var tracksDailyLog = false

    private struct ObserverEntry {
        weak var owner: AnyObject?
        let handler: @MainActor (ChangeSet, ChangeOrigin) -> Void
    }

    private struct WeakEntity {
        weak var object: AnyObject?
    }

    public init() {}

    // MARK: - Transactions

    /// Runs `body` as one undoable step. Nested calls join the outer transaction.
    /// If `body` throws, everything it changed is rolled back.
    @discardableResult
    public func perform<R>(_ name: String, coalesce: String? = nil,
                           coalesceWindow: TimeInterval? = nil,
                           _ body: (Transaction) throws -> R) rethrows -> R {
        if let tx = activeTransaction { return try body(tx) }
        let tx = Transaction(name: name, coalesceKey: coalesce, workspace: self)
        tx.coalesceWindow = coalesceWindow
        activeTransaction = tx
        do {
            let result = try body(tx)
            activeTransaction = nil
            commit(tx)
            return result
        } catch {
            activeTransaction = nil
            tx.rollBack()
            throw error
        }
    }

    /// Starts a transaction that stays open across several events (for example a drag).
    /// Changes made through it are visible immediately but become one undo step on commit.
    public func beginTransaction(_ name: String) -> Transaction {
        if let tx = activeTransaction { return tx }
        let tx = Transaction(name: name, coalesceKey: nil, workspace: self)
        activeTransaction = tx
        return tx
    }

    public func commitTransaction(_ tx: Transaction) {
        guard activeTransaction === tx else { return }
        activeTransaction = nil
        commit(tx)
    }

    public func cancelTransaction(_ tx: Transaction) {
        guard activeTransaction === tx else { return }
        activeTransaction = nil
        tx.rollBack()
    }

    public var isInTransaction: Bool { activeTransaction != nil }

    private func commit(_ tx: Transaction) {
        if tracksDailyLog { recordTouches(in: tx) }
        let changes = tx.changes()
        guard !changes.isEmpty else { return }
        let set = ChangeSet(name: tx.name, changes: changes, coalesceKey: tx.coalesceKey,
                            coalesceWindow: tx.coalesceWindow, date: clock())
        history.record(set)
        didApply(set, origin: .edit)
    }

    // MARK: - Undo

    /// Reverts the most recent step. Returns the changes as applied (before and after
    /// from the point of view of the undo), or nil when there was nothing to undo.
    @discardableResult
    public func undo() -> ChangeSet? {
        guard activeTransaction == nil, let set = history.popUndo() else { return nil }
        for change in set.changes.reversed() { setRecord(change.key, change.before) }
        history.pushRedo(set)
        didApply(set.inverted, origin: .undo)
        return set.inverted
    }

    @discardableResult
    public func redo() -> ChangeSet? {
        guard activeTransaction == nil, let set = history.popRedo() else { return nil }
        for change in set.changes { setRecord(change.key, change.after) }
        history.pushUndoAfterRedo(set)
        didApply(set, origin: .redo)
        return set
    }

    /// Reverts the most recent step without making it redoable, if it carries `coalesceKey`.
    /// Used to cancel an edit in progress (Esc while typing a title).
    @discardableResult
    public func discardLastStep(ifCoalesceKey key: String) -> Bool {
        guard activeTransaction == nil, history.undoStack.last?.coalesceKey == key,
              let set = history.popUndo() else { return false }
        for change in set.changes.reversed() { setRecord(change.key, change.before) }
        didApply(set.inverted, origin: .undo)
        return true
    }

    private func didApply(_ set: ChangeSet, origin: ChangeOrigin) {
        persistence?.markDirty(set.keys)
        revision &+= 1
        observers.removeAll { $0.owner == nil }
        for observer in observers { observer.handler(set, origin) }
    }

    /// Calls `handler` after every applied change set for as long as `owner` is alive.
    public func addChangeObserver(_ owner: AnyObject,
                                  _ handler: @escaping @MainActor (ChangeSet, ChangeOrigin) -> Void) {
        observers.append(ObserverEntry(owner: owner, handler: handler))
    }

    // MARK: - Typed storage

    func lookup<V: EntityData>(_ id: UUID, as type: V.Type) -> Entity<V>? {
        switch V.entityKind {
        case .node: nodes[id] as? Entity<V>
        case .edge: edges[id] as? Entity<V>
        case .map: maps[id] as? Entity<V>
        case .placement: placements[id] as? Entity<V>
        case .frame: frames[id] as? Entity<V>
        case .dayLog: dayLogs[id] as? Entity<V>
        }
    }

    func store<V: EntityData>(_ entity: Entity<V>) {
        switch entity {
        case let node as Node:
            nodes[node.id] = node
        case let edge as GraphEdge:
            edges[edge.id] = edge
            indexEdge(edge.id, edge.data)
        case let map as MindMap:
            maps[map.id] = map
        case let placement as Placement:
            placements[placement.id] = placement
            indexPlacement(placement)
        case let frame as MapFrame:
            frames[frame.id] = frame
            frameIDsByMap[frame.data.mapID, default: []].insert(frame.id)
        case let log as DayLog:
            dayLogs[log.id] = log
        default:
            assertionFailure("Unknown entity type \(V.self)")
        }
    }

    func unstore<V: EntityData>(_ entity: Entity<V>) {
        switch entity {
        case let node as Node:
            nodes[node.id] = nil
        case let edge as GraphEdge:
            edges[edge.id] = nil
            unindexEdge(edge.id, edge.data)
        case let map as MindMap:
            maps[map.id] = nil
        case let placement as Placement:
            placements[placement.id] = nil
            unindexPlacement(placement, data: placement.data)
        case let frame as MapFrame:
            frames[frame.id] = nil
            frameIDsByMap[frame.data.mapID]?.remove(frame.id)
        case let log as DayLog:
            dayLogs[log.id] = nil
        default:
            assertionFailure("Unknown entity type \(V.self)")
        }
        retired[entity.key] = WeakEntity(object: entity)
        if retired.count > 1000 { retired = retired.filter { $0.value.object != nil } }
    }

    /// Replaces an entity's data, keeping the indices correct.
    func write<V: EntityData>(_ entity: Entity<V>, _ value: V) {
        guard entity.data != value else { return }
        switch entity {
        case let edge as GraphEdge:
            let old = edge.data
            let new = value as! EdgeData
            if old.fromID != new.fromID || old.toID != new.toID {
                unindexEdge(edge.id, old)
                indexEdge(edge.id, new)
            }
        case let placement as Placement:
            let old = placement.data
            let new = value as! PlacementData
            if old.mapID != new.mapID || old.nodeID != new.nodeID {
                unindexPlacement(placement, data: old)
                entity.data = value
                indexPlacement(placement)
                return
            }
        case let frame as MapFrame:
            let old = frame.data
            let new = value as! FrameData
            if old.mapID != new.mapID {
                frameIDsByMap[old.mapID]?.remove(frame.id)
                frameIDsByMap[new.mapID, default: []].insert(frame.id)
            }
        default:
            break
        }
        entity.data = value
    }

    private func indexEdge(_ id: UUID, _ data: EdgeData) {
        edgeIDsByNode[data.fromID, default: []].insert(id)
        edgeIDsByNode[data.toID, default: []].insert(id)
    }

    private func unindexEdge(_ id: UUID, _ data: EdgeData) {
        edgeIDsByNode[data.fromID]?.remove(id)
        edgeIDsByNode[data.toID]?.remove(id)
        if edgeIDsByNode[data.fromID]?.isEmpty == true { edgeIDsByNode[data.fromID] = nil }
        if edgeIDsByNode[data.toID]?.isEmpty == true { edgeIDsByNode[data.toID] = nil }
    }

    private func indexPlacement(_ placement: Placement) {
        let data = placement.data
        placementsByMap[data.mapID, default: [:]][data.nodeID] = placement
        placementIDsByNode[data.nodeID, default: []].insert(placement.id)
    }

    private func unindexPlacement(_ placement: Placement, data: PlacementData) {
        if placementsByMap[data.mapID]?[data.nodeID] === placement {
            placementsByMap[data.mapID]?[data.nodeID] = nil
        }
        placementIDsByNode[data.nodeID]?.remove(placement.id)
        if placementIDsByNode[data.nodeID]?.isEmpty == true { placementIDsByNode[data.nodeID] = nil }
    }

    // MARK: - Untyped record access (undo, persistence, backup)

    public func currentRecord(_ key: RecordKey) -> (any EntityData)? {
        switch key.kind {
        case .node: nodes[key.id]?.data
        case .edge: edges[key.id]?.data
        case .map: maps[key.id]?.data
        case .placement: placements[key.id]?.data
        case .frame: frames[key.id]?.data
        case .dayLog: dayLogs[key.id]?.data
        }
    }

    /// Makes the record match `value`: inserts, updates or (for nil) deletes it.
    func setRecord(_ key: RecordKey, _ value: (any EntityData)?) {
        switch key.kind {
        case .node: setEntity(key.id, value as? NodeData)
        case .edge: setEntity(key.id, value as? EdgeData)
        case .map: setEntity(key.id, value as? MapData)
        case .placement: setEntity(key.id, value as? PlacementData)
        case .frame: setEntity(key.id, value as? FrameData)
        case .dayLog: setEntity(key.id, value as? DayLogData)
        }
    }

    private func setEntity<V: EntityData>(_ id: UUID, _ value: V?) {
        if let value {
            if let existing = lookup(id, as: V.self) {
                write(existing, value)
            } else if let previous = retired.removeValue(forKey: RecordKey(kind: V.entityKind, id: id))?.object
                        as? Entity<V> {
                previous.data = value
                store(previous)
            } else {
                store(Entity(id: id, data: value))
            }
        } else if let existing = lookup(id, as: V.self) {
            unstore(existing)
        }
    }

    /// Every record in the workspace (for saving everything and for backups).
    public func allRecords() -> [(key: RecordKey, value: any EntityData)] {
        var result: [(key: RecordKey, value: any EntityData)] = []
        result.reserveCapacity(nodes.count + edges.count + maps.count + placements.count + frames.count + dayLogs.count)
        for e in maps.values { result.append((e.key, e.data)) }
        for e in nodes.values { result.append((e.key, e.data)) }
        for e in placements.values { result.append((e.key, e.data)) }
        for e in edges.values { result.append((e.key, e.data)) }
        for e in frames.values { result.append((e.key, e.data)) }
        for e in dayLogs.values { result.append((e.key, e.data)) }
        return result
    }

    /// Loads records without recording undo steps or marking anything for saving.
    func loadRecords(_ records: [(key: RecordKey, value: any EntityData)]) {
        for record in records { setRecord(record.key, record.value) }
    }

    /// Removes everything and loads `records` instead (used by restore). Not undoable.
    public func replaceContents(with records: [(key: RecordKey, value: any EntityData)]) {
        let oldKeys = allRecords().map(\.key)
        nodes = [:]; edges = [:]; maps = [:]; placements = [:]; frames = [:]; dayLogs = [:]
        placementsByMap = [:]; placementIDsByNode = [:]; edgeIDsByNode = [:]; frameIDsByMap = [:]
        loadRecords(records)
        history.removeAll()
        persistence?.markDirty(oldKeys + records.map(\.key))
        revision &+= 1
    }
}
