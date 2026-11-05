import CoreGraphics

/// Alignment guides while dragging: snaps a moving rect's edges and centre lines to those of
/// other rects nearby, and reports the guide lines to draw.
public enum SnapGuides {
    public struct Guide: Equatable, Sendable {
        /// A vertical guide is the line x = `position`; a horizontal one is y = `position`.
        public var isVertical: Bool
        public var position: CGFloat
        /// Where the line starts and ends along its own direction.
        public var from: CGFloat
        public var to: CGFloat
    }

    public struct Result: Equatable, Sendable {
        /// Add this to the moving rect's origin to snap it.
        public var offset: CGSize
        public var guides: [Guide]
    }

    /// Snaps `moving` to the nearest edge or centre line of `others` within `threshold`,
    /// separately on each axis.
    public static func snap(_ moving: CGRect, to others: [CGRect], threshold: CGFloat) -> Result {
        var bestX: CGFloat?
        var bestY: CGFloat?
        for other in others {
            for target in lines(other, vertical: true) {
                for line in lines(moving, vertical: true) {
                    let delta = target - line
                    if abs(delta) <= threshold, abs(delta) < abs(bestX ?? .infinity) { bestX = delta }
                }
            }
            for target in lines(other, vertical: false) {
                for line in lines(moving, vertical: false) {
                    let delta = target - line
                    if abs(delta) <= threshold, abs(delta) < abs(bestY ?? .infinity) { bestY = delta }
                }
            }
        }

        let offset = CGSize(width: bestX ?? 0, height: bestY ?? 0)
        let snapped = moving.offsetBy(dx: offset.width, dy: offset.height)
        var guides: [Guide] = []
        if bestX != nil { guides += sharedLines(of: snapped, with: others, vertical: true) }
        if bestY != nil { guides += sharedLines(of: snapped, with: others, vertical: false) }
        return Result(offset: offset, guides: guides)
    }

    /// Left, centre and right (or top, middle and bottom) of a rect.
    private static func lines(_ rect: CGRect, vertical: Bool) -> [CGFloat] {
        vertical ? [rect.minX, rect.midX, rect.maxX] : [rect.minY, rect.midY, rect.maxY]
    }

    /// One guide for each line of `rect` that other rects line up with, spanning all of them.
    private static func sharedLines(of rect: CGRect, with others: [CGRect], vertical: Bool) -> [Guide] {
        var guides: [Guide] = []
        for line in lines(rect, vertical: vertical) {
            var from = vertical ? rect.minY : rect.minX
            var to = vertical ? rect.maxY : rect.maxX
            var found = false
            for other in others where lines(other, vertical: vertical).contains(where: { abs($0 - line) < 0.5 }) {
                found = true
                from = min(from, vertical ? other.minY : other.minX)
                to = max(to, vertical ? other.maxY : other.maxX)
            }
            if found { guides.append(Guide(isVertical: vertical, position: line, from: from, to: to)) }
        }
        return guides
    }
}

/// Align and distribute for a multi-selection.
public enum Arrange {
    public enum Alignment: String, CaseIterable, Sendable, Identifiable {
        case left, centre, right, top, middle, bottom

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .left: "Left"
            case .centre: "Centre"
            case .right: "Right"
            case .top: "Top"
            case .middle: "Middle"
            case .bottom: "Bottom"
            }
        }

        public var symbolName: String {
            switch self {
            case .left: "align.horizontal.left"
            case .centre: "align.horizontal.center"
            case .right: "align.horizontal.right"
            case .top: "align.vertical.top"
            case .middle: "align.vertical.center"
            case .bottom: "align.vertical.bottom"
            }
        }
    }

    public enum Axis: String, CaseIterable, Sendable, Identifiable {
        case horizontal, vertical

        public var id: String { rawValue }
        public var title: String { self == .horizontal ? "Horizontally" : "Vertically" }
        public var symbolName: String {
            self == .horizontal ? "distribute.horizontal.center" : "distribute.vertical.center"
        }
    }

    /// New centres that line the rects up on one edge (or centre line) of their bounds.
    public static func align<ID: Hashable>(_ rects: [ID: CGRect], to alignment: Alignment) -> [ID: CGPoint] {
        guard let bounds = Geometry.union(Array(rects.values)) else { return [:] }
        var result: [ID: CGPoint] = [:]
        for (id, rect) in rects {
            var center = CGPoint(x: rect.midX, y: rect.midY)
            switch alignment {
            case .left: center.x = bounds.minX + rect.width / 2
            case .centre: center.x = bounds.midX
            case .right: center.x = bounds.maxX - rect.width / 2
            case .top: center.y = bounds.minY + rect.height / 2
            case .middle: center.y = bounds.midY
            case .bottom: center.y = bounds.maxY - rect.height / 2
            }
            result[id] = center
        }
        return result
    }

    /// New centres that space the rects evenly between the first and the last along `axis`,
    /// with equal gaps between neighbouring edges. Needs at least three rects.
    public static func distribute<ID: Hashable>(_ rects: [ID: CGRect], along axis: Axis) -> [ID: CGPoint] {
        guard rects.count >= 3 else { return [:] }
        let horizontal = axis == .horizontal
        let ordered = rects.sorted { a, b in
            let ma = horizontal ? a.value.midX : a.value.midY
            let mb = horizontal ? b.value.midX : b.value.midY
            if ma != mb { return ma < mb }
            return (horizontal ? a.value.minY : a.value.minX) < (horizontal ? b.value.minY : b.value.minX)
        }
        let first = ordered[0].value
        let last = ordered[ordered.count - 1].value
        let span = horizontal ? last.maxX - first.minX : last.maxY - first.minY
        let occupied = ordered.reduce(CGFloat(0)) { $0 + (horizontal ? $1.value.width : $1.value.height) }
        let gap = (span - occupied) / CGFloat(ordered.count - 1)
        var cursor = horizontal ? first.minX : first.minY
        var result: [ID: CGPoint] = [:]
        for (id, rect) in ordered {
            if horizontal {
                result[id] = CGPoint(x: cursor + rect.width / 2, y: rect.midY)
                cursor += rect.width + gap
            } else {
                result[id] = CGPoint(x: rect.midX, y: cursor + rect.height / 2)
                cursor += rect.height + gap
            }
        }
        return result
    }
}
