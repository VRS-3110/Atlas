import AppKit
import AtlasCore
import SwiftUI

extension NodeColor {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }
}

extension NodeKind {
    var symbolName: String {
        switch self {
        case .idea: "lightbulb"
        case .question: "questionmark.circle"
        case .hypothesis: "flask"
        case .claim: "exclamationmark.bubble"
        case .evidence: "checkmark.seal"
        case .source: "book.closed"
        case .quote: "quote.opening"
        case .task: "checkmark.circle"
        case .note: "note.text"
        }
    }

    var defaultColor: NodeColor {
        switch self {
        case .idea: .orange
        case .question: .purple
        case .hypothesis: .teal
        case .claim: .blue
        case .evidence: .green
        case .source: .brown
        case .quote: .pink
        case .task: .red
        case .note: .gray
        }
    }
}

extension TaskStatus {
    var symbolName: String {
        switch self {
        case .todo: "circle"
        case .doing: "circle.lefthalf.filled"
        case .done: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        }
    }
}

extension NodeData {
    var effectiveColor: NodeColor { color ?? kind.defaultColor }
    var displayTitle: String { title.isEmpty ? "Untitled" : title }

    /// The icon shown at the leading edge: a live checkbox for tasks, the kind icon otherwise.
    var leadingSymbol: String {
        if kind == .task, let task { return task.status.symbolName }
        return kind.symbolName
    }
}

extension RelationType {
    var color: Color {
        switch self {
        case .supports: .green
        case .contradicts: .red
        case .leadsTo: .blue
        case .partOf: .gray
        case .related, .custom: .secondary
        }
    }
}

/// The outline of a node; each kind has its own silhouette.
struct NodeShape: Shape {
    let kind: NodeKind
    var isTopic = false

    func path(in rect: CGRect) -> Path {
        if isTopic { return RoundedRectangle(cornerRadius: min(rect.height / 2, 20), style: .continuous).path(in: rect) }
        switch kind {
        case .idea:
            return RoundedRectangle(cornerRadius: 12, style: .continuous).path(in: rect)
        case .question:
            return RoundedRectangle(cornerRadius: min(rect.height / 2, 18), style: .continuous).path(in: rect)
        case .hypothesis:
            let inset = min(12, rect.height / 2)
            var p = Path()
            p.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            p.closeSubpath()
            return p
        case .claim:
            return RoundedRectangle(cornerRadius: 3, style: .continuous).path(in: rect)
        case .evidence, .task:
            return RoundedRectangle(cornerRadius: 7, style: .continuous).path(in: rect)
        case .source:
            let fold: CGFloat = min(11, rect.height / 3)
            var p = Path()
            p.move(to: CGPoint(x: rect.minX + 4, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 4))
            p.addQuadCurve(to: CGPoint(x: rect.maxX - 4, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + 4, y: rect.maxY))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - 4), control: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 4))
            p.addQuadCurve(to: CGPoint(x: rect.minX + 4, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
            p.closeSubpath()
            return p
        case .quote:
            return RoundedRectangle(cornerRadius: 14, style: .continuous).path(in: rect)
        case .note:
            return Rectangle().path(in: rect)
        }
    }
}
