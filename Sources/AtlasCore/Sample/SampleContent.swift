import CoreGraphics
import Foundation

extension Workspace {
    /// Fills an empty workspace with a short guided map. Not undoable.
    public func populateWelcomeContent() {
        guard maps.isEmpty, nodes.isEmpty else { return }
        perform("Welcome") { tx in
            let now = clock()
            let map = tx.insert(MapData(name: "Welcome to Atlas", layoutStyle: .mindMap, sortIndex: 0, createdAt: now))

            @MainActor func add(_ title: String, _ kind: NodeKind, body: String = "", at point: CGPoint,
                     parent: Node? = nil, order: Double = 0, tags: [String] = [],
                     configure: (inout NodeData) -> Void = { _ in }) -> Node {
                var data = NodeData(title: title, body: body, kind: kind, tags: tags, createdAt: now)
                configure(&data)
                let node = tx.insert(data)
                tx.insert(PlacementData(mapID: map.id, nodeID: node.id, position: point,
                                        parentID: parent?.id, order: order))
                return node
            }

            let root = add("Welcome to Atlas", .idea,
                           body: "Atlas keeps ideas, sources and plans in **one graph**. Every box on this map is a node.",
                           at: CGPoint(x: 0, y: 0))

            let keys = add("How do I edit a map?", .question,
                           body: "Select a node, then use the keyboard.",
                           at: CGPoint(x: -250, y: -110), parent: root, order: 0)
            _ = add("Tab adds a child, Return adds a sibling", .note, at: CGPoint(x: -525, y: -170), parent: keys, order: 0)
            _ = add("Space edits the title", .note, at: CGPoint(x: -525, y: -110), parent: keys, order: 1)
            _ = add("Double-click empty canvas for a new node", .note, at: CGPoint(x: -525, y: -50), parent: keys, order: 2)

            let hypothesis = add("Everything is a node", .hypothesis,
                                 body: "A node can live on several maps, cite sources and become a task.",
                                 at: CGPoint(x: 250, y: -130), parent: root, order: 1, tags: ["atlas"])
            let evidence = add("Rename a node in the inspector and the map updates instantly", .evidence,
                               at: CGPoint(x: 540, y: -130), parent: hypothesis, order: 0)

            let source = add("On the Origin of Species", .source,
                             body: "Public-domain classic, used here as an example source.",
                             at: CGPoint(x: 250, y: 10), parent: root, order: 2, tags: ["biology"]) { data in
                data.source = SourceInfo(entryType: "book", authors: ["Darwin, Charles"], year: 1859,
                                         publisher: "John Murray", citationKey: "darwin1859origin")
            }
            _ = add("There is grandeur in this view of life", .quote,
                    at: CGPoint(x: 540, y: 10), parent: source, order: 0) { data in
                data.citations = [Citation(sourceID: source.id, page: "490")]
            }

            _ = add("Plan a first research map", .task,
                    body: "Any node can become a task: set its type to Task (⌃⌘8) or click Make Task in the inspector.",
                    at: CGPoint(x: 250, y: 130), parent: root, order: 3) { data in
                data.task = TaskInfo(status: .todo, priority: .medium)
            }

            tx.insert(EdgeData(from: evidence.id, to: hypothesis.id, relation: .supports, createdAt: now))
        }
        history.removeAll()
    }
}
