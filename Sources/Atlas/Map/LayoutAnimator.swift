import AppKit
import Observation
import QuartzCore
import SwiftUI

/// Where one node is drawn right now. Each node has its own observable object, so a node
/// moving redraws that node (and the connector canvas), not every node on the map.
@MainActor
@Observable
final class NodeDisplay {
    var center: CGPoint

    init(_ center: CGPoint) {
        self.center = center
    }
}

/// Springs nodes from where they are drawn to where the layout wants them. Nodes and
/// connectors read the same interpolated positions, so connectors never lag behind.
@MainActor
final class LayoutAnimator {
    private var timer: Timer?
    private var start: [UUID: CGPoint] = [:]
    private var end: [UUID: CGPoint] = [:]
    private var began: CFTimeInterval = 0
    private var apply: ((UUID, CGPoint) -> Void)?
    private let spring = Spring(duration: 0.42, bounce: 0.12)

    var isAnimating: Bool { timer != nil }

    /// Animates every node in `end` from its `start` (or from where it already is).
    /// Calling it again mid-flight carries on from the current positions.
    func animate(from start: [UUID: CGPoint], to end: [UUID: CGPoint],
                 apply: @escaping @MainActor (UUID, CGPoint) -> Void) {
        stop()
        guard !Self.reduceMotion else {
            for (id, point) in end { apply(id, point) }
            return
        }
        self.start = start
        self.end = end
        self.apply = apply
        began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        apply = nil
    }

    private func tick() {
        guard let apply else { return }
        let elapsed = CACurrentMediaTime() - began
        let done = elapsed >= spring.settlingDuration
        let progress = done ? 1 : CGFloat(spring.value(target: 1.0, time: elapsed))
        for (id, target) in end {
            let from = start[id] ?? target
            apply(id, CGPoint(x: from.x + (target.x - from.x) * progress,
                              y: from.y + (target.y - from.y) * progress))
        }
        if done { stop() }
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
