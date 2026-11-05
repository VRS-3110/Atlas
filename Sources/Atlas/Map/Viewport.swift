import AppKit
import QuartzCore
import SwiftUI

/// Maps canvas (world) coordinates to view coordinates: view = world × zoom + offset.
struct Viewport: Equatable {
    var offset: CGPoint = .zero
    var zoom: CGFloat = 1

    static let minZoom: CGFloat = 0.1
    static let maxZoom: CGFloat = 4

    func viewPoint(_ world: CGPoint) -> CGPoint {
        CGPoint(x: world.x * zoom + offset.x, y: world.y * zoom + offset.y)
    }

    func worldPoint(_ view: CGPoint) -> CGPoint {
        CGPoint(x: (view.x - offset.x) / zoom, y: (view.y - offset.y) / zoom)
    }

    func viewRect(_ world: CGRect) -> CGRect {
        CGRect(origin: viewPoint(world.origin), size: CGSize(width: world.width * zoom, height: world.height * zoom))
    }

    func worldRect(_ view: CGRect) -> CGRect {
        CGRect(origin: worldPoint(view.origin), size: CGSize(width: view.width / zoom, height: view.height / zoom))
    }

    /// A viewport showing `world` centred in a view of `size`, with `margin` points spare.
    static func fitting(_ world: CGRect, in size: CGSize, margin: CGFloat = 60, maxZoom: CGFloat = 1) -> Viewport {
        let availableW = max(size.width - margin * 2, 40)
        let availableH = max(size.height - margin * 2, 40)
        let zoom = min(availableW / max(world.width, 1), availableH / max(world.height, 1), maxZoom)
            .clamped(to: minZoom...Viewport.maxZoom)
        return Viewport(offset: CGPoint(x: size.width / 2 - world.midX * zoom, y: size.height / 2 - world.midY * zoom),
                        zoom: zoom)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

/// Animates a viewport change frame by frame on a spring. Both the node layer and the edge
/// canvas read the same interpolated viewport, so connectors never lag behind nodes.
@MainActor
final class ViewportAnimator {
    private var timer: Timer?
    private let spring = Spring(duration: 0.38, bounce: 0)

    var isAnimating: Bool { timer != nil }

    func animate(from start: Viewport, to end: Viewport, in size: CGSize,
                 update: @escaping @MainActor (Viewport) -> Void) {
        stop()
        guard !LayoutAnimator.reduceMotion else {
            update(end)
            return
        }
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let startWorld = start.worldPoint(centre)
        let endWorld = end.worldPoint(centre)
        // Zoom is interpolated on a log scale so zooming in and out feel alike.
        let startLog = log(start.zoom)
        let endLog = log(end.zoom)
        let began = CACurrentMediaTime()
        let spring = spring
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let elapsed = CACurrentMediaTime() - began
                let done = elapsed >= spring.settlingDuration
                let e = done ? 1 : CGFloat(spring.value(target: 1.0, time: elapsed))
                let zoom = exp(startLog + (endLog - startLog) * e)
                let world = CGPoint(x: startWorld.x + (endWorld.x - startWorld.x) * e,
                                    y: startWorld.y + (endWorld.y - startWorld.y) * e)
                update(Viewport(offset: CGPoint(x: centre.x - world.x * zoom, y: centre.y - world.y * zoom), zoom: zoom))
                if done { self?.stop() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// Remembers each map's viewport between launches.
enum ViewportStore {
    private static func key(_ mapID: UUID) -> String { "atlas.viewport.\(mapID.uuidString)" }

    static func load(_ mapID: UUID) -> Viewport? {
        guard let values = UserDefaults.standard.array(forKey: key(mapID)) as? [Double], values.count == 3 else { return nil }
        return Viewport(offset: CGPoint(x: values[0], y: values[1]), zoom: CGFloat(values[2]).clamped(to: Viewport.minZoom...Viewport.maxZoom))
    }

    static func save(_ viewport: Viewport, for mapID: UUID) {
        UserDefaults.standard.set([Double(viewport.offset.x), Double(viewport.offset.y), Double(viewport.zoom)], forKey: key(mapID))
    }
}
