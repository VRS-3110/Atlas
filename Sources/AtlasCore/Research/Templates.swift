import CoreGraphics
import Foundation

/// Ready-made map structures for common research tasks.
public enum ResearchTemplate: String, CaseIterable, Identifiable, Sendable {
    case researchQuestion
    case literatureReview
    case argumentMap

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .researchQuestion: "Research Question"
        case .literatureReview: "Literature Review"
        case .argumentMap: "Argument Map"
        }
    }

    public var summary: String {
        switch self {
        case .researchQuestion: "Question → hypotheses → evidence for and against → open questions"
        case .literatureReview: "Themes, each to be linked to its sources"
        case .argumentMap: "Claim, premises, objections and rebuttals"
        }
    }

    public var symbolName: String {
        switch self {
        case .researchQuestion: "questionmark.bubble"
        case .literatureReview: "books.vertical"
        case .argumentMap: "scale.3d"
        }
    }

    /// One node of a template and its children.
    public struct Item: Sendable {
        public var title: String
        public var kind: NodeKind
        public var color: NodeColor?
        public var children: [Item]

        init(_ title: String, _ kind: NodeKind, color: NodeColor? = nil, _ children: [Item] = []) {
            self.title = title
            self.kind = kind
            self.color = color
            self.children = children
        }

        public var count: Int { 1 + children.reduce(0) { $0 + $1.count } }
    }

    public var structure: Item {
        switch self {
        case .researchQuestion:
            let hypothesis = { (n: Int) in
                Item("Hypothesis \(n)", .hypothesis, [
                    Item("Evidence For", .evidence, color: .green),
                    Item("Evidence Against", .evidence, color: .red),
                ])
            }
            return Item("Research Question", .question, [
                hypothesis(1), hypothesis(2), Item("Open Questions", .question),
            ])
        case .literatureReview:
            return Item("Literature Review", .idea, [
                Item("Theme 1", .idea), Item("Theme 2", .idea), Item("Theme 3", .idea),
                Item("Gaps in the Literature", .question),
            ])
        case .argumentMap:
            return Item("Claim", .claim, [
                Item("Premise 1", .claim, color: .green),
                Item("Premise 2", .claim, color: .green),
                Item("Objection", .claim, color: .red, [Item("Rebuttal", .claim, color: .blue)]),
            ])
        }
    }
}

extension Workspace {
    /// Drops a template onto a map, under `parentID` or as a new root at `position`, as
    /// one undo step. For a literature review, `sources` are placed under an
    /// "Unsorted Sources" branch, ready to drag onto themes. Returns the template's root.
    @discardableResult
    public func insertTemplate(_ template: ResearchTemplate, in mapID: UUID, under parentID: UUID? = nil,
                               at position: CGPoint? = nil, sources: [UUID] = []) -> UUID? {
        guard maps[mapID] != nil else { return nil }
        let origin = position ?? parentID.map { suggestedChildPosition(parent: $0, in: mapID) } ?? .zero
        return perform("Insert \(template.title)") { tx -> UUID in
            var row: CGFloat = 0
            @MainActor func place(_ item: ResearchTemplate.Item, parent: UUID?, depth: Int) -> UUID {
                let firstRow = row
                var childIDs: [UUID] = []
                var node = NodeData(title: item.title, kind: item.kind, color: item.color, createdAt: clock())
                node.setKind(item.kind)
                let entity = tx.insert(node)
                insertPlacement(nodeID: entity.id, mapID: mapID, at: .zero, parent: parent, after: nil, tx: tx)
                for child in item.children { childIDs.append(place(child, parent: entity.id, depth: depth + 1)) }
                if item.children.isEmpty { row += 1 }
                let y = item.children.isEmpty ? firstRow : (firstRow + row - 1) / 2
                if let p = placement(of: entity.id, in: mapID) {
                    tx.update(p) { $0.position = CGPoint(x: origin.x + CGFloat(depth) * 230, y: origin.y + y * 58) }
                }
                return entity.id
            }
            let rootID = place(template.structure, parent: parentID, depth: 0)
            if template == .literatureReview, !sources.isEmpty {
                let unsorted = tx.insert(NodeData(title: "Unsorted Sources", kind: .note, color: .gray, createdAt: clock()))
                insertPlacement(nodeID: unsorted.id, mapID: mapID, at: CGPoint(x: origin.x + 230, y: origin.y + row * 58),
                                parent: rootID, after: nil, tx: tx)
                for (index, sourceID) in sources.enumerated() where nodes[sourceID] != nil {
                    if let existing = placement(of: sourceID, in: mapID) {
                        tx.update(existing) { $0.parentID = unsorted.id }
                    } else {
                        insertPlacement(nodeID: sourceID, mapID: mapID,
                                        at: CGPoint(x: origin.x + 460, y: origin.y + (row + CGFloat(index)) * 58),
                                        parent: unsorted.id, after: nil, tx: tx)
                    }
                    if let node = nodes[sourceID], node.inbox != .none { tx.update(node) { $0.inbox = .none } }
                }
            }
            return rootID
        }
    }

    /// A new map holding a template.
    @discardableResult
    public func createMap(from template: ResearchTemplate, sources: [UUID] = []) -> MindMap {
        perform("New \(template.title) Map") { _ in
            let map = createMap(named: template.title, rootTitle: nil)
            insertTemplate(template, in: map.id, at: .zero, sources: sources)
            return map
        }
    }
}
