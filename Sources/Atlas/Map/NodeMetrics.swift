import AppKit
import AtlasCore

/// Computes node sizes from their content. Sizes are deterministic (measured with AppKit
/// text metrics, then cached), so connectors, layouts and hit testing never need to wait
/// for SwiftUI to lay a node out.
@MainActor
final class NodeMetrics {
    static let maxTextWidth: CGFloat = 200
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 8
    static let iconWidth: CGFloat = 16
    static let spacing: CGFloat = 6
    static let badgeWidth: CGFloat = 26
    static let minimumSize = CGSize(width: 72, height: 32)
    static let minimumTopicSize = CGSize(width: 120, height: 44)

    private struct Key: Hashable {
        let title: String
        let isTopic: Bool
        let italic: Bool
        let badges: Int
    }

    private var cache: [Key: CGSize] = [:]

    static func titleFont(isTopic: Bool, kind: NodeKind) -> NSFont {
        let base = isTopic ? NSFont.systemFont(ofSize: 16, weight: .semibold) : NSFont.systemFont(ofSize: 13)
        guard kind == .quote else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }

    /// Badges drawn after the title (task state, linked sources, attachments).
    static func badgeCount(for data: NodeData) -> Int {
        var count = 0
        if data.task != nil && data.kind != .task { count += 1 }
        if !data.citations.isEmpty { count += 1 }
        if !data.attachments.isEmpty { count += 1 }
        return count
    }

    func size(for data: NodeData, isTopic: Bool) -> CGSize {
        let key = Key(title: data.title, isTopic: isTopic, italic: data.kind == .quote, badges: Self.badgeCount(for: data))
        if let cached = cache[key] { return cached }
        let font = Self.titleFont(isTopic: isTopic, kind: data.kind)
        let text = data.displayTitle as NSString
        let bounds = text.boundingRect(with: CGSize(width: Self.maxTextWidth, height: 10_000),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading],
                                       attributes: [.font: font])
        let textWidth = min(ceil(bounds.width) + 2, Self.maxTextWidth + 2)
        let minimum = isTopic ? Self.minimumTopicSize : Self.minimumSize
        let width = Self.horizontalPadding * 2 + Self.iconWidth + Self.spacing + textWidth
            + CGFloat(key.badges) * Self.badgeWidth
        let height = ceil(bounds.height) + Self.verticalPadding * 2
        let size = CGSize(width: ceil(max(width, minimum.width)), height: ceil(max(height, minimum.height)))
        if cache.count > 20_000 { cache.removeAll() }
        cache[key] = size
        return size
    }

    /// Width available to the title text inside a node of the given size.
    static func textWidth(nodeWidth: CGFloat, badges: Int) -> CGFloat {
        nodeWidth - horizontalPadding * 2 - iconWidth - spacing - CGFloat(badges) * badgeWidth
    }
}
