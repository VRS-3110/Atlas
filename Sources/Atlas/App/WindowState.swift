import AtlasCore
import Foundation
import Observation

/// A sidebar destination. Codable so each window can be reopened on the same page.
enum SidebarItem: Hashable, Codable {
    case inbox
    case today
    case week
    case sources
    case tags
    case review
    case map(UUID)

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .today: "Today"
        case .week: "Week"
        case .sources: "Sources"
        case .tags: "Tags"
        case .review: "Review"
        case .map: "Map"
        }
    }

    var symbolName: String {
        switch self {
        case .inbox: "tray"
        case .today: "sun.max"
        case .week: "calendar"
        case .sources: "books.vertical"
        case .tags: "tag"
        case .review: "checklist"
        case .map: "point.3.connected.trianglepath.dotted"
        }
    }
}

/// Asks the map screen to select and scroll to a node once it is showing.
struct RevealRequest: Equatable {
    let mapID: UUID
    let nodeID: UUID
    let token = UUID()
}

/// Per-window navigation state.
@MainActor
@Observable
final class WindowState {
    var selection: SidebarItem?
    var revealRequest: RevealRequest?
    /// Selected rows in the Inbox and the sources library.
    var inboxSelection: Set<UUID> = []
    var sourceSelection: Set<UUID> = []
    /// The source whose PDF is open beside the library.
    var openDocumentID: UUID?
    /// The day the Today page shows, and the week (any day in it) the Week page shows.
    var todayDate = Date()
    var weekDate = Date()
    /// The ⌘K command palette.
    var isPaletteVisible = false {
        didSet { activeMapController?.isObscured = isPaletteVisible }
    }

    /// One controller per map, kept while the window lives so selection and viewport
    /// survive switching between maps.
    @ObservationIgnored private var controllers: [UUID: MapController] = [:]

    init(selection: SidebarItem? = nil) {
        self.selection = selection
    }

    func controller(for map: MindMap, workspace: Workspace) -> MapController {
        if let existing = controllers[map.id] { return existing }
        let controller = MapController(map: map, workspace: workspace)
        controllers[map.id] = controller
        return controller
    }

    /// The controller of the map this window shows, if it shows one.
    var activeMapController: MapController? {
        if case .map(let id) = selection { return controllers[id] }
        return nil
    }

    /// The map this window shows, if any.
    var currentMapID: UUID? {
        if case .map(let id) = selection { return id }
        return nil
    }

    /// Opens a map showing the node (the preferred map if the node is on it) and selects it.
    /// Nodes on no map open where they live: the Inbox, the sources library (a quote opens
    /// its source) or the planner.
    func reveal(_ nodeID: UUID, in workspace: Workspace, preferring mapID: UUID? = nil) {
        let maps = workspace.maps(containing: nodeID)
        guard let target = maps.first(where: { $0.id == mapID }) ?? maps.first else {
            guard let node = workspace.nodes[nodeID] else { return }
            if node.inbox != .none {
                selection = .inbox
                inboxSelection = [nodeID]
            } else if node.source != nil {
                selection = .sources
                sourceSelection = [nodeID]
            } else if let source = node.citations.first?.sourceID, workspace.nodes[source] != nil {
                selection = .sources
                sourceSelection = [source]
            } else if let task = node.task {
                if let start = task.scheduledStart {
                    todayDate = start
                    selection = .today
                } else {
                    selection = .week
                }
            }
            return
        }
        selection = .map(target.id)
        revealRequest = RevealRequest(mapID: target.id, nodeID: nodeID)
    }
}
