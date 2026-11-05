import AppKit

/// Development aid: `ATLAS_SNAPSHOT=/path/out.png` makes the app save a picture of its
/// window a few seconds after launch (`ATLAS_SNAPSHOT_DELAY`, default 2.5 s), and
/// `ATLAS_SNAPSHOT_QUIT=1` quits afterwards. The window draws itself, so no screen
/// recording permission is needed.
@MainActor
enum DebugSnapshot {
    static func scheduleIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["ATLAS_SNAPSHOT"], !path.isEmpty else { return }
        let delay = Double(environment["ATLAS_SNAPSHOT_DELAY"] ?? "") ?? 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            capture(to: URL(fileURLWithPath: path))
            if environment["ATLAS_SNAPSHOT_QUIT"] == "1" { NSApp.terminate(nil) }
        }
    }

    static func capture(to url: URL) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        // A real window image (materials and vibrancy included). An app may always capture
        // its own windows; fall back to asking the views to draw themselves.
        if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                               [.boundsIgnoreFraming, .bestResolution]),
           image.width > 1 {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            return
        }
        guard let frameView = window.contentView?.superview ?? window.contentView else { return }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
