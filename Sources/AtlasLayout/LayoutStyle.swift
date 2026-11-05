import Foundation

/// How a map arranges its nodes. `free` means positions are only ever set by hand.
public enum LayoutStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case free
    case mindMap
    case treeRight
    case orgChart
    case radial

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .free: "Free Placement"
        case .mindMap: "Mind Map"
        case .treeRight: "Tree (Right)"
        case .orgChart: "Org Chart"
        case .radial: "Radial"
        }
    }

    public var symbolName: String {
        switch self {
        case .free: "hand.draw"
        case .mindMap: "brain"
        case .treeRight: "list.bullet.indent"
        case .orgChart: "rectangle.3.group"
        case .radial: "circle.hexagongrid"
        }
    }
}
