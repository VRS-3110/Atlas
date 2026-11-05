import Foundation
import Observation

/// Every persisted record type in the workspace.
public enum EntityKind: String, Codable, CaseIterable, Sendable {
    case node
    case edge
    case map
    case placement
    case frame
    case dayLog
}

/// Identifies one record across all entity kinds (used by undo, persistence and backup).
public struct RecordKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let kind: EntityKind
    public let id: UUID

    public init(kind: EntityKind, id: UUID) {
        self.kind = kind
        self.id = id
    }

    public var description: String { "\(kind.rawValue)/\(id.uuidString)" }
}

/// The value-type state of an entity. All fields of a record live in one struct so that a
/// snapshot of the struct is enough for undo, saving and backup.
public protocol EntityData: Codable, Equatable, Sendable {
    static var entityKind: EntityKind { get }
    /// Called by a transaction after it changes the record (used to stamp `updatedAt`).
    mutating func didModify(at date: Date)
    /// Equal apart from bookkeeping such as `updatedAt`. Undo treats a change that only
    /// touches bookkeeping as no change, so typing a title and then deleting back to the
    /// original leaves no step behind.
    func hasSameContent(as other: Self) -> Bool
}

extension EntityData {
    public mutating func didModify(at date: Date) {}
    public func hasSameContent(as other: Self) -> Bool { self == other }

    func isEqual(to other: any EntityData) -> Bool {
        guard let other = other as? Self else { return false }
        return self == other
    }

    func hasSameContent(asRecord other: any EntityData) -> Bool {
        guard let other = other as? Self else { return false }
        return hasSameContent(as: other)
    }
}

func recordsEqual(_ a: (any EntityData)?, _ b: (any EntityData)?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (a?, b?): return a.isEqual(to: b)
    default: return false
    }
}

func recordsHaveSameContent(_ a: (any EntityData)?, _ b: (any EntityData)?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (a?, b?): return a.hasSameContent(asRecord: b)
    default: return false
    }
}

/// A live, observable object wrapping one record. Views read fields through dynamic member
/// lookup (`node.title`); all writes go through `Workspace.perform` so they are undoable
/// and saved.
@Observable
@dynamicMemberLookup
public final class Entity<Value: EntityData>: Identifiable {
    public let id: UUID
    public internal(set) var data: Value

    public init(id: UUID = UUID(), data: Value) {
        self.id = id
        self.data = data
    }

    public subscript<T>(dynamicMember keyPath: KeyPath<Value, T>) -> T {
        data[keyPath: keyPath]
    }

    public var key: RecordKey { RecordKey(kind: Value.entityKind, id: id) }
}

public typealias Node = Entity<NodeData>
public typealias GraphEdge = Entity<EdgeData>
public typealias MindMap = Entity<MapData>
public typealias Placement = Entity<PlacementData>
public typealias MapFrame = Entity<FrameData>
public typealias DayLog = Entity<DayLogData>

// MARK: - Lenient decoding

extension KeyedDecodingContainer {
    /// Decodes a value, falling back to `fallback` when the key is missing or unreadable.
    /// Records written by older (or newer) versions of Atlas therefore always load.
    func lenient<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) -> T {
        if let value = try? decodeIfPresent(T.self, forKey: key) { return value }
        return fallback()
    }

    /// Decodes an optional value, treating unreadable data as absent.
    func optional<T: Decodable>(_ key: Key, as type: T.Type = T.self) -> T? {
        try? decodeIfPresent(T.self, forKey: key)
    }
}
