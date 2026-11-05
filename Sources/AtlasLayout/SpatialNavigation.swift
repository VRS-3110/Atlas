import CoreGraphics

/// Arrow-key navigation between nodes based on where they sit on screen.
public enum SpatialNavigation {
    public enum Direction: Sendable, CaseIterable {
        case up, down, left, right

        var vector: CGVector {
            switch self {
            case .up: CGVector(dx: 0, dy: -1)
            case .down: CGVector(dx: 0, dy: 1)
            case .left: CGVector(dx: -1, dy: 0)
            case .right: CGVector(dx: 1, dy: 0)
            }
        }
    }

    /// The candidate closest to `origin` in `direction`. Candidates must lie inside a
    /// roughly 60° cone either side of the direction; sideways distance is penalised so
    /// the most "in line" node wins over a slightly nearer one off to the side.
    public static func nearest<ID: Hashable>(from origin: CGPoint, direction: Direction,
                                             candidates: [(id: ID, center: CGPoint)]) -> ID? {
        let v = direction.vector
        var best: (id: ID, score: CGFloat)?
        for candidate in candidates {
            let dx = candidate.center.x - origin.x
            let dy = candidate.center.y - origin.y
            let along = dx * v.dx + dy * v.dy
            guard along > 1 else { continue }
            let across = abs(dx * v.dy - dy * v.dx)
            guard across <= along * 1.8 else { continue }
            let score = along + across * 2
            if best == nil || score < best!.score { best = (candidate.id, score) }
        }
        return best?.id
    }
}
