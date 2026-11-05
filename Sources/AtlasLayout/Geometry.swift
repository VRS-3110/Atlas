import CoreGraphics

/// Geometry helpers shared by the canvas renderer, hit testing and exporters.
public enum Geometry {

    /// The rect of a node centred on `center`.
    public static func rect(center: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
               width: size.width, height: size.height)
    }

    /// The point where a ray from the centre of `rect` towards `target` leaves the rect.
    /// Returns the centre when the target is the centre itself.
    public static func borderPoint(of rect: CGRect, toward target: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = target.x - center.x
        let dy = target.y - center.y
        guard dx != 0 || dy != 0 else { return center }
        let halfW = rect.width / 2
        let halfH = rect.height / 2
        // Scale the direction vector so it touches the nearest side.
        let scaleX = dx == 0 ? CGFloat.infinity : halfW / abs(dx)
        let scaleY = dy == 0 ? CGFloat.infinity : halfH / abs(dy)
        let scale = min(scaleX, scaleY)
        return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
    }

    public enum ConnectorAxis: Equatable, Sendable { case horizontal, vertical }

    /// A cubic Bézier connector between a parent and a child node.
    public struct Connector: Equatable, Sendable {
        public var start: CGPoint
        public var control1: CGPoint
        public var control2: CGPoint
        public var end: CGPoint
        public var axis: ConnectorAxis

        /// Point on the curve at parameter t in 0...1.
        public func point(at t: CGFloat) -> CGPoint {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(x: a * start.x + b * control1.x + c * control2.x + d * end.x,
                           y: a * start.y + b * control1.y + c * control2.y + d * end.y)
        }
    }

    /// The axis a connector should use when the layout does not dictate one: horizontal
    /// whenever the boxes are separated left-to-right, vertical when one sits above the other.
    public static func preferredAxis(from parent: CGRect, to child: CGRect) -> ConnectorAxis {
        let horizontalGap = max(child.minX - parent.maxX, parent.minX - child.maxX)
        if horizontalGap > 0 { return .horizontal }
        let verticalGap = max(child.minY - parent.maxY, parent.minY - child.maxY)
        if verticalGap > 0 { return .vertical }
        let dx = child.midX - parent.midX
        let dy = child.midY - parent.midY
        return abs(dx) >= abs(dy) ? .horizontal : .vertical
    }

    /// A tree connector attached to the left/right sides (horizontal) or top/bottom
    /// sides (vertical) of the two boxes. Pass `axis` to force the layout's direction.
    public static func treeConnector(from parent: CGRect, to child: CGRect,
                                     axis: ConnectorAxis? = nil) -> Connector {
        let dx = child.midX - parent.midX
        let dy = child.midY - parent.midY

        if (axis ?? preferredAxis(from: parent, to: child)) == .horizontal {
            let toRight = dx >= 0
            let start = CGPoint(x: toRight ? parent.maxX : parent.minX, y: parent.midY)
            let end = CGPoint(x: toRight ? child.minX : child.maxX, y: child.midY)
            let bend = max(abs(end.x - start.x) * 0.5, 12)
            let sign: CGFloat = toRight ? 1 : -1
            return Connector(start: start,
                             control1: CGPoint(x: start.x + bend * sign, y: start.y),
                             control2: CGPoint(x: end.x - bend * sign, y: end.y),
                             end: end, axis: .horizontal)
        } else {
            let below = dy >= 0
            let start = CGPoint(x: parent.midX, y: below ? parent.maxY : parent.minY)
            let end = CGPoint(x: child.midX, y: below ? child.minY : child.maxY)
            let bend = max(abs(end.y - start.y) * 0.5, 12)
            let sign: CGFloat = below ? 1 : -1
            return Connector(start: start,
                             control1: CGPoint(x: start.x, y: start.y + bend * sign),
                             control2: CGPoint(x: end.x, y: end.y - bend * sign),
                             end: end, axis: .vertical)
        }
    }

    /// Endpoints for a relation edge drawn between two node rects (border to border).
    public static func relationEndpoints(from a: CGRect, to b: CGRect) -> (start: CGPoint, end: CGPoint) {
        let ca = CGPoint(x: a.midX, y: a.midY)
        let cb = CGPoint(x: b.midX, y: b.midY)
        return (borderPoint(of: a, toward: cb), borderPoint(of: b, toward: ca))
    }

    /// The gentle curve of a relation edge: border to border, bowed to the left of its
    /// direction so that edges running both ways between two nodes stay apart.
    public struct RelationCurve: Equatable, Sendable {
        public var start: CGPoint
        public var control: CGPoint
        public var end: CGPoint

        public func point(at t: CGFloat) -> CGPoint {
            let u = 1 - t
            return CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                           y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
        }

        public var midpoint: CGPoint { point(at: 0.5) }

        /// Shortest distance from `p` to the curve (measured on a fine polyline).
        public func distance(to p: CGPoint) -> CGFloat {
            var best = CGFloat.infinity
            var previous = start
            for step in 1...24 {
                let next = point(at: CGFloat(step) / 24)
                best = min(best, Geometry.distance(from: p, toSegment: previous, next))
                previous = next
            }
            return best
        }
    }

    public static func relationCurve(from a: CGRect, to b: CGRect) -> RelationCurve {
        let ends = relationEndpoints(from: a, to: b)
        let mid = CGPoint(x: (ends.start.x + ends.end.x) / 2, y: (ends.start.y + ends.end.y) / 2)
        let dx = ends.end.x - ends.start.x
        let dy = ends.end.y - ends.start.y
        let length = max(hypot(dx, dy), 1)
        let bend = min(40, length * 0.12)
        let control = CGPoint(x: mid.x - dy / length * bend, y: mid.y + dx / length * bend)
        return RelationCurve(start: ends.start, control: control, end: ends.end)
    }

    /// Where a relation's label is centred: on the middle of its curve, or, when the nodes
    /// are too close for it to fit between them, just beside the curve where it clears
    /// them (on the side the curve bows towards, unless the other side is nearer).
    public static func labelCenter(on curve: RelationCurve, size: CGSize, avoiding obstacles: [CGRect],
                                   margin: CGFloat = 3) -> CGPoint {
        let blocked = obstacles.map { $0.insetBy(dx: -margin, dy: -margin) }
        func isClear(_ centre: CGPoint) -> Bool {
            let box = rect(center: centre, size: size)
            return !blocked.contains { $0.intersects(box) }
        }
        let mid = curve.midpoint
        if isClear(mid) { return mid }
        let dx = curve.end.x - curve.start.x
        let dy = curve.end.y - curve.start.y
        let length = hypot(dx, dy)
        let normal = length > 0.5 ? CGPoint(x: -dy / length, y: dx / length) : CGPoint(x: 0, y: -1)
        let reach = size.width + size.height + (obstacles.map { max($0.width, $0.height) }.max() ?? 0)
        var distance: CGFloat = 2
        while distance <= reach {
            for side: CGFloat in [1, -1] {
                let centre = CGPoint(x: mid.x + normal.x * distance * side, y: mid.y + normal.y * distance * side)
                if isClear(centre) { return centre }
            }
            distance += 2
        }
        return mid
    }

    /// Shortest distance from `p` to the segment `a`–`b`.
    public static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let lengthSquared = abx * abx + aby * aby
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / lengthSquared))
        let proj = CGPoint(x: a.x + t * abx, y: a.y + t * aby)
        return hypot(p.x - proj.x, p.y - proj.y)
    }

    /// The smallest rect containing all `rects`, or nil for an empty input.
    public static func union(_ rects: [CGRect]) -> CGRect? {
        guard var result = rects.first else { return nil }
        for r in rects.dropFirst() { result = result.union(r) }
        return result
    }
}
