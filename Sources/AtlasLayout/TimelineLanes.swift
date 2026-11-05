import Foundation

/// Side-by-side placement of overlapping blocks on a day timeline, as calendar apps do:
/// each block takes the first free lane, and every block in a group of mutually
/// overlapping blocks shares that group's lane count, so their widths match.
public enum TimelineLanes {
    public struct Slot: Equatable, Sendable {
        public let lane: Int
        public let laneCount: Int
    }

    /// `items` are (start, end) pairs in any unit; the result is in the same order.
    /// Zero-length items count as one unit long so they still get a lane.
    public static func assign(_ items: [(start: Double, end: Double)]) -> [Slot] {
        let order = items.indices.sorted {
            items[$0].start != items[$1].start ? items[$0].start < items[$1].start : items[$0].end > items[$1].end
        }
        var lanes = Array(repeating: 0, count: items.count)
        var counts = Array(repeating: 1, count: items.count)
        var laneEnds: [Double] = []
        var group: [Int] = []
        var groupEnd = -Double.infinity

        func closeGroup() {
            let count = (group.map { lanes[$0] }.max() ?? 0) + 1
            for index in group { counts[index] = count }
            group = []
            laneEnds = []
        }

        for index in order {
            let start = items[index].start
            let end = max(items[index].end, start + 1)
            if !group.isEmpty, start >= groupEnd { closeGroup() }
            if let free = laneEnds.firstIndex(where: { $0 <= start }) {
                lanes[index] = free
                laneEnds[free] = end
            } else {
                lanes[index] = laneEnds.count
                laneEnds.append(end)
            }
            group.append(index)
            groupEnd = max(group.count == 1 ? end : groupEnd, end)
        }
        if !group.isEmpty { closeGroup() }
        return items.indices.map { Slot(lane: lanes[$0], laneCount: counts[$0]) }
    }
}
