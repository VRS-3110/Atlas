import Testing
@testable import AtlasLayout

@Suite("Timeline lanes")
struct TimelineLanesTests {
    @Test func separateBlocksTakeTheFullWidth() {
        let slots = TimelineLanes.assign([(0, 30), (30, 60), (90, 120)])
        #expect(slots.allSatisfy { $0 == .init(lane: 0, laneCount: 1) })
    }

    @Test func overlappingBlocksShareTheWidth() {
        // A 9:00–10:00 and B 9:30–10:30 overlap; C 10:00–10:30 fits back into A's lane.
        let slots = TimelineLanes.assign([(540, 600), (570, 630), (600, 630)])
        #expect(slots[0] == .init(lane: 0, laneCount: 2))
        #expect(slots[1] == .init(lane: 1, laneCount: 2))
        #expect(slots[2] == .init(lane: 0, laneCount: 2))
    }

    @Test func groupsAreIndependentAndOrderIsKept() {
        let slots = TimelineLanes.assign([(200, 260), (0, 100), (10, 20), (20, 30), (220, 240)])
        #expect(slots[1] == .init(lane: 0, laneCount: 2))
        #expect(slots[2] == .init(lane: 1, laneCount: 2))
        #expect(slots[3] == .init(lane: 1, laneCount: 2))
        #expect(slots[0] == .init(lane: 0, laneCount: 2))
        #expect(slots[4] == .init(lane: 1, laneCount: 2))
        // Zero-length blocks still get a lane.
        #expect(TimelineLanes.assign([(5, 5), (5, 5)]).map(\.laneCount) == [2, 2])
    }
}
