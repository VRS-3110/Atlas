import CoreGraphics
import Foundation
import AtlasLayout

/// The meaning of a relation edge between two nodes.
public enum RelationType: String, Codable, CaseIterable, Sendable, Identifiable {
    case related
    case supports
    case contradicts
    case leadsTo
    case partOf
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .related: "Related"
        case .supports: "Supports"
        case .contradicts: "Contradicts"
        case .leadsTo: "Leads To"
        case .partOf: "Part Of"
        case .custom: "Custom"
        }
    }

    public var defaultLineStyle: LineStyle {
        switch self {
        case .contradicts: .dashed
        case .partOf: .dotted
        default: .solid
        }
    }

    public var defaultHasArrow: Bool { self != .related }
}

public enum LineStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case solid
    case dashed
    case dotted

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

/// A typed relation between two nodes. Edges are global: they show on every map that
/// contains both ends.
public struct EdgeData: EntityData {
    public static let entityKind = EntityKind.edge

    public var fromID: UUID
    public var toID: UUID
    public var relation: RelationType
    /// The label for `.custom` relations; an optional override for the others.
    public var label: String
    public var lineStyle: LineStyle
    public var hasArrow: Bool
    public var createdAt: Date

    public init(from fromID: UUID, to toID: UUID, relation: RelationType = .related,
                label: String = "", lineStyle: LineStyle? = nil, hasArrow: Bool? = nil,
                createdAt: Date = .now) {
        self.fromID = fromID
        self.toID = toID
        self.relation = relation
        self.label = label
        self.lineStyle = lineStyle ?? relation.defaultLineStyle
        self.hasArrow = hasArrow ?? relation.defaultHasArrow
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case fromID, toID, relation, label, lineStyle, hasArrow, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fromID = try c.decode(UUID.self, forKey: .fromID)
        toID = try c.decode(UUID.self, forKey: .toID)
        relation = c.lenient(.relation, .related)
        label = c.lenient(.label, "")
        lineStyle = c.lenient(.lineStyle, relation.defaultLineStyle)
        hasArrow = c.lenient(.hasArrow, relation.defaultHasArrow)
        createdAt = c.lenient(.createdAt, Date(timeIntervalSinceReferenceDate: 0))
    }

    /// The text shown on the canvas next to the edge, if any.
    public var displayLabel: String {
        if !label.isEmpty { return label }
        return relation == .related || relation == .custom ? "" : relation.title.lowercased()
    }

    public func connects(_ a: UUID, _ b: UUID) -> Bool {
        (fromID == a && toID == b) || (fromID == b && toID == a)
    }
}

/// A named canvas. Which nodes it shows, and where, lives in its placements.
public struct MapData: EntityData {
    public static let entityKind = EntityKind.map

    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    /// The layout last applied; new nodes follow it.
    public var layoutStyle: LayoutStyle
    /// Order in the sidebar.
    public var sortIndex: Double

    public init(name: String, layoutStyle: LayoutStyle = .mindMap, sortIndex: Double = 0,
                createdAt: Date = .now) {
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.layoutStyle = layoutStyle
        self.sortIndex = sortIndex
    }

    public mutating func didModify(at date: Date) { updatedAt = date }

    public func hasSameContent(as other: MapData) -> Bool {
        var other = other
        other.updatedAt = updatedAt
        return self == other
    }

    enum CodingKeys: String, CodingKey { case name, createdAt, updatedAt, layoutStyle, sortIndex }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.lenient(.name, "Untitled Map")
        createdAt = c.lenient(.createdAt, Date(timeIntervalSinceReferenceDate: 0))
        updatedAt = c.lenient(.updatedAt, createdAt)
        layoutStyle = c.lenient(.layoutStyle, .free)
        sortIndex = c.lenient(.sortIndex, 0)
    }
}

/// A node's appearance on one map: its position, its parent in that map's tree, and
/// per-map view state. A node appears at most once per map.
public struct PlacementData: EntityData {
    public static let entityKind = EntityKind.placement

    public var mapID: UUID
    public var nodeID: UUID
    /// Centre of the node in canvas coordinates.
    public var x: Double
    public var y: Double
    /// The node's parent in this map's tree; nil for a root.
    public var parentID: UUID?
    /// Sort order among siblings.
    public var order: Double
    public var isCollapsed: Bool
    /// Pinned nodes keep their position when an automatic layout runs.
    public var isPinned: Bool

    public init(mapID: UUID, nodeID: UUID, position: CGPoint, parentID: UUID? = nil,
                order: Double = 0, isCollapsed: Bool = false, isPinned: Bool = false) {
        self.mapID = mapID
        self.nodeID = nodeID
        self.x = position.x
        self.y = position.y
        self.parentID = parentID
        self.order = order
        self.isCollapsed = isCollapsed
        self.isPinned = isPinned
    }

    public var position: CGPoint {
        get { CGPoint(x: x, y: y) }
        set {
            x = newValue.x
            y = newValue.y
        }
    }

    enum CodingKeys: String, CodingKey { case mapID, nodeID, x, y, parentID, order, isCollapsed, isPinned }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mapID = try c.decode(UUID.self, forKey: .mapID)
        nodeID = try c.decode(UUID.self, forKey: .nodeID)
        x = c.lenient(.x, 0)
        y = c.lenient(.y, 0)
        parentID = c.optional(.parentID)
        order = c.lenient(.order, 0)
        isCollapsed = c.lenient(.isCollapsed, false)
        isPinned = c.lenient(.isPinned, false)
    }
}

/// A labelled frame drawn around a group of nodes on one map. Its rectangle follows the
/// member nodes, so it never needs resizing by hand.
public struct FrameData: EntityData {
    public static let entityKind = EntityKind.frame

    public var mapID: UUID
    public var title: String
    public var color: NodeColor
    public var nodeIDs: [UUID]
    public var createdAt: Date

    public init(mapID: UUID, title: String, color: NodeColor = .blue, nodeIDs: [UUID],
                createdAt: Date = .now) {
        self.mapID = mapID
        self.title = title
        self.color = color
        self.nodeIDs = nodeIDs
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case mapID, title, color, nodeIDs, createdAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mapID = try c.decode(UUID.self, forKey: .mapID)
        title = c.lenient(.title, "")
        color = c.lenient(.color, .blue)
        nodeIDs = c.lenient(.nodeIDs, [])
        createdAt = c.lenient(.createdAt, Date(timeIntervalSinceReferenceDate: 0))
    }
}

/// The automatic note for one calendar day.
public struct DayLogData: EntityData {
    public static let entityKind = EntityKind.dayLog

    /// Local calendar day, `yyyy-MM-dd`.
    public var day: String
    /// Free-form Markdown notes for the day.
    public var body: String
    /// Nodes created or edited that day, in first-touched order.
    public var touchedNodeIDs: [UUID]
    public var createdAt: Date

    public init(day: String, body: String = "", touchedNodeIDs: [UUID] = [], createdAt: Date = .now) {
        self.day = day
        self.body = body
        self.touchedNodeIDs = touchedNodeIDs
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case day, body, touchedNodeIDs, createdAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        body = c.lenient(.body, "")
        touchedNodeIDs = c.lenient(.touchedNodeIDs, [])
        createdAt = c.lenient(.createdAt, Date(timeIntervalSinceReferenceDate: 0))
    }
}
