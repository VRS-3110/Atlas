import AppKit
import QuartzCore

/// Development aid: counts the frames the window actually presents while a step function
/// animates something, using the view's display link. A frame that takes longer than the
/// refresh interval shows up as a skipped callback.
@MainActor
final class FrameMeter: NSObject {
    static let shared = FrameMeter()

    private var link: CADisplayLink?
    private var timestamps: [CFTimeInterval] = []
    private var start: CFTimeInterval = 0
    private var seconds: Double = 3
    private var step: ((Double) -> Void)?
    private var done: ((String) -> Void)?

    func start(view: NSView, seconds: Double, step: @escaping (Double) -> Void, done: @escaping (String) -> Void) {
        link?.invalidate()
        timestamps = []
        start = 0
        self.seconds = seconds
        self.step = step
        self.done = done
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if start == 0 { start = now }
        timestamps.append(now)
        let t = now - start
        if t >= seconds {
            finish(refresh: link.targetTimestamp - link.timestamp)
            return
        }
        step?(t)
    }

    private func finish(refresh: CFTimeInterval) {
        link?.invalidate()
        link = nil
        let intervals = zip(timestamps.dropFirst(), timestamps).map { $0 - $1 }.sorted()
        let elapsed = (timestamps.last ?? 0) - (timestamps.first ?? 0)
        let fps = elapsed > 0 ? Double(intervals.count) / elapsed : 0
        let p95 = intervals.isEmpty ? 0 : intervals[min(intervals.count - 1, Int(Double(intervals.count) * 0.95))]
        let worst = intervals.last ?? 0
        let report = String(format: "frames %d  fps %.1f  p95 %.1f ms  worst %.1f ms  refresh %.1f ms\n",
                            intervals.count, fps, p95 * 1000, worst * 1000, refresh * 1000)
        NSLog("FrameMeter: \(report)")
        done?(report)
        step = nil
        done = nil
    }
}
