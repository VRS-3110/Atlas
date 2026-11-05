import AppKit
import AtlasCore
import AtlasLayout

/// Development aid for checking interactions without a person at the keyboard.
///
/// `ATLAS_SCRIPT=/path/steps.txt` runs one command per line after launch. Keys go through
/// the window server to this process, and mouse and scroll events into the window's event
/// queue, so they take the same route as hardware input (first responder, SwiftUI
/// gestures, menu shortcuts and focused values). Commands:
///
///     wait 0.5                  key tab | key cmd+z | key shift+down
///     type Some text            click Title | shiftclick Title | doubleclick Title
///     drag Title 120 40         clickcanvas 300 200 | doubleclickcanvas 300 200
///     scroll -40 0              snapshot /tmp/a.png | dump /tmp/state.json
///     menus /tmp/menus.txt      quit | crash
///
/// Input only arrives while Atlas is the active app, so input steps first wait briefly for
/// it to come forward. When the system keeps another app in front, these call the methods
/// that the gestures and menu commands call:
///
///     select Title              movenode Title 60 80      addat 120 120
///     do undo | redo | collapse | delete | zoomin | zoomout | actualsize | fit | background
///
/// Phase 2 additions (controller steps unless noted):
///
///     selectmore Title          hover Title               layout mindMap | treeRight | orgChart | radial | free
///     dragto A -> B [child|before|after]                  mousedragto A -> B [slot]   (real mouse events)
///     marquee 10 10 400 300     mousedrag 10 10 400 300 (real mouse events)
///     connect A -> B            mouseconnect A -> B (real drag from A's handle)       pick 2
///     focus on | off | 3        align left | distribute horizontal
///     do copy | cut | paste | duplicate | indent | outdent | moveup | movedown | pin | unpinall
///        | connect | group | ungroup | palette | selectall | space
///
/// Phases 3–5:
///
///     go inbox | today | week | sources | tags | review | map Name
///     capture Text              template researchQuestion    schedule Title 9:30 [minutes]
///     export png|pdf|md|opml /path          backup /path      restore /path
///     generate 500              fps 4 /path.txt [zoom]        showcapture
@MainActor
enum DebugScript {
    /// The map controller of the most recently shown map (set by `MapScreen`).
    static weak var activeController: MapController?
    /// The state of the most recently opened window (set by `RootView`).
    static weak var activeWindow: WindowState?

    private static var steps: [String] = []

    static func scheduleIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["ATLAS_SCRIPT"],
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        steps = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            runNext()
        }
    }

    private static let inputCommands: Set<String> = [
        "key", "type", "click", "shiftclick", "doubleclick", "clickcanvas", "doubleclickcanvas", "drag", "scroll",
        "mousedragto", "mousedrag", "mouseconnect", "mousemarquee", "clickedge", "doubleclickedge", "clickminimap",
        "mousedragframe",
    ]
    /// How often the app had to be brought back to the front before an input step.
    private static var reactivations = 0
    private static var activationAttempts = 0

    private static func runNext() {
        guard let line = steps.first else { return }
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts[0].lowercased()
        let argument = parts.count > 1 ? parts[1] : ""
        if inputCommands.contains(command), !(NSApp.isActive && window?.isKeyWindow == true), activationAttempts < 8 {
            if activationAttempts == 0 { reactivations += 1 }
            activationAttempts += 1
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { runNext() }
            return
        }
        if activationAttempts >= 8 { NSLog("DebugScript: app not active for step \(line)") }
        activationAttempts = 0
        steps.removeFirst()
        var delay = 0.25
        switch command {
        case "wait": delay = Double(argument) ?? 0.5
        case "key": postKey(argument)
        case "keydown": postKey(argument, phases: [true])
        case "keyup": postKey(argument, phases: [false])
        case "type": typeText(argument)
        case "click": clickNode(argument, count: 1)
        case "shiftclick": clickNode(argument, count: 1, flags: .shift)
        case "doubleclick": clickNode(argument, count: 2)
        case "clickcanvas": clickCanvas(argument, count: 1)
        case "doubleclickcanvas": clickCanvas(argument, count: 2)
        case "drag": delay = dragNode(argument)
        case "scroll": scroll(argument)
        case "select": selectNode(argument)
        case "selectmore": selectNode(argument, extending: true)
        case "hover": if let id = nodeID(argument) { activeController?.hoverChanged(id, inside: true) }
        case "layout": setLayout(argument)
        case "dragto": delay = dragTo(argument, realMouse: false)
        case "mousedragto": delay = dragTo(argument, realMouse: true)
        case "marquee": delay = marquee(argument)
        case "mousedrag": delay = mouseDrag(argument)
        case "connect": connect(argument)
        case "mouseconnect": delay = mouseConnect(argument)
        case "pick": _ = activeController?.pickRelation(number: Int(argument) ?? 0)
        case "mousemarquee": delay = mouseMarquee(argument)
        case "clickedge": clickEdge(argument, count: 1)
        case "doubleclickedge": clickEdge(argument, count: 2)
        case "clickminimap": clickMinimap(argument)
        case "setclip": setClip(argument)
        case "mousedragframe": delay = mouseDragFrame(argument)
        case "dragframe": delay = dragFrame(argument)
        case "focus": focus(argument)
        case "align": if let a = Arrange.Alignment(rawValue: argument.lowercased()) { activeController?.align(a) }
        case "distribute": if let axis = Arrange.Axis(rawValue: argument.lowercased()) { activeController?.distribute(axis) }
        case "movenode": delay = moveNode(argument)
        case "addat": addNode(at: argument)
        case "do": perform(argument)
        case "menus": dumpMenus(to: URL(fileURLWithPath: argument))
        case "snapshot": DebugSnapshot.capture(to: URL(fileURLWithPath: argument))
        case "dump": dump(to: URL(fileURLWithPath: argument))
        case "export": exportMap(argument)
        case "backup": try? activeController?.workspace.backupData().write(to: URL(fileURLWithPath: argument))
        case "restore": restoreBackup(argument)
        case "go": go(argument)
        case "capture": AppStore.shared.workspace.capture(argument)
        case "template": if let t = ResearchTemplate(rawValue: argument) { activeController?.insertTemplate(t) }
        case "schedule": scheduleTask(argument)
        case "showcapture": QuickCapture.shared.show()
        case "generate": delay = generate(argument)
        case "fps": delay = measureFrames(argument)
        case "quit": NSApp.terminate(nil)
        case "crash": kill(getpid(), SIGKILL) // no chance to save: tests that autosave already did
        default: NSLog("DebugScript: unknown command \(line)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { runNext() }
    }

    // MARK: Phase 5 steps

    /// `export png|pdf|md|opml /path/file`
    private static func exportMap(_ argument: String) {
        let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let format = MapExportFormat(argument: parts[0]), let controller = activeController,
              let data = ExportService.data(for: format, controller: controller) else {
            NSLog("DebugScript: export failed for \(argument)")
            return
        }
        try? data.write(to: URL(fileURLWithPath: parts[1]))
    }

    private static func restoreBackup(_ path: String) {
        let workspace = AppStore.shared.workspace
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let contents = try? WorkspaceBackup.decode(data) else { return }
        _ = try? workspace.restoreBackup(contents)
    }

    /// `schedule Title 14:30 [minutes]` puts a node on today's timeline.
    private static func scheduleTask(_ argument: String) {
        let parts = argument.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return }
        let hasMinutes = parts.count >= 3 && Int(parts[parts.count - 1]) != nil && parts[parts.count - 2].contains(":")
        let minutes = hasMinutes ? Int(parts[parts.count - 1]) : nil
        let timeText = hasMinutes ? parts[parts.count - 2] : parts[parts.count - 1]
        let title = parts.dropLast(hasMinutes ? 2 : 1).joined(separator: " ")
        let hm = timeText.split(separator: ":").compactMap { Int($0) }
        let workspace = AppStore.shared.workspace
        guard hm.count == 2, let node = workspace.nodes.values.first(where: { $0.title == title }),
              let start = Calendar.current.date(bySettingHour: hm[0], minute: hm[1], second: 0, of: Date()) else { return }
        workspace.schedule(node.id, at: start, minutes: minutes)
    }

    /// `go inbox | today | week | sources | tags | review | map Name`
    private static func go(_ argument: String) {
        guard let window = activeWindow else { return }
        let lower = argument.lowercased()
        if lower.hasPrefix("map ") {
            let name = String(argument.dropFirst(4))
            if let map = AppStore.shared.workspace.sortedMaps.first(where: { $0.name == name }) {
                window.selection = .map(map.id)
            }
            return
        }
        let items: [String: SidebarItem] = ["inbox": .inbox, "today": .today, "week": .week, "sources": .sources,
                                            "tags": .tags, "review": .review]
        if let item = items[lower] { window.selection = item }
    }

    /// `generate 500` adds a map of that many nodes (a few levels deep) and opens it.
    private static func generate(_ argument: String) -> Double {
        let count = max(1, Int(argument) ?? 500)
        let workspace = AppStore.shared.workspace
        let map = workspace.perform("Generate") { _ -> MindMap in
            let map = workspace.createMap(named: "Generated \(count)", rootTitle: "Generated")
            guard let root = workspace.tree(of: map.id).roots.first else { return map }
            // Six children per node, filled breadth first: four or five levels for 500 nodes.
            var frontier = [root]
            var made = 1
            while made < count {
                let parent = frontier[(made - 1) / 6]
                let child = workspace.addChild(to: parent, in: map.id,
                                               data: NodeData(title: "Node \(made)", kind: NodeKind.allCases[made % 9]))
                frontier.append(child.id)
                made += 1
            }
            return map
        }
        activeWindow?.selection = .map(map.id)
        return 1.5
    }

    /// `fps 3 /path/out.txt [zoom]` pans the active map continuously (around where it is)
    /// for that many seconds, also zooming with `zoom`, and writes the frames drawn per
    /// second, measured with a display link.
    private static func measureFrames(_ argument: String) -> Double {
        let parts = argument.split(separator: " ").map(String.init)
        let seconds = Double(parts.first ?? "") ?? 3
        let zooms = parts.count > 2 && parts[2] == "zoom"
        guard let controller = activeController, let view = controller.keyView else { return 0.25 }
        let base = controller.viewport
        FrameMeter.shared.start(view: view, seconds: seconds, step: { t in
            // A full screen width each way, so culled maps cross their margins.
            controller.viewport.offset.x = base.offset.x + controller.canvasSize.width * sin(t * 1.5)
            controller.viewport.offset.y = base.offset.y + controller.canvasSize.height * 0.6 * sin(t * 1.1)
            if zooms { controller.viewport.zoom = base.zoom * (1 + 0.4 * sin(t)) }
        }, done: { report in
            if parts.count > 1 { try? report.write(toFile: parts[1], atomically: true, encoding: .utf8) }
        })
        return seconds + 0.5
    }

    // MARK: Events

    private static var window: NSWindow? {
        activeController?.keyView?.window ?? NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    private static func post(_ event: CGEvent?) {
        event?.postToPid(getpid())
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "tab": 48, "return": 36, "space": 49, "escape": 53, "delete": 51, "forwarddelete": 117,
        "left": 123, "right": 124, "down": 125, "up": 126, "f2": 120,
        "a": 0, "n": 45, "o": 31, "z": 6, ".": 47, "0": 29, "1": 18, "9": 25, "=": 24, "-": 27,
        "k": 40, "g": 5, "l": 37, "d": 2, "f": 3, "m": 46, "c": 8, "v": 9, "x": 7, "[": 33, "]": 30,
        "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28,
    ]

    /// Posts a key ("cmd+shift+z"); `phases` can hold it down or let it go on its own.
    private static func postKey(_ spec: String, phases: [Bool] = [true, false]) {
        var flags: CGEventFlags = []
        var code: CGKeyCode?
        for part in spec.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "alt": flags.insert(.maskAlternate)
            case "ctrl": flags.insert(.maskControl)
            default: code = keyCodes[part]
            }
        }
        guard let code else {
            NSLog("DebugScript: unknown key \(spec)")
            return
        }
        for down in phases {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = flags
            post(event)
        }
    }

    private static func typeText(_ text: String) {
        for character in text {
            let units = Array(String(character).utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: character == " " ? 49 : 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                post(event)
            }
        }
    }

    private static var eventNumber = 0

    /// Window coordinates of a point in the canvas.
    private static func windowPoint(fromCanvas point: CGPoint) -> CGPoint? {
        activeController?.keyView.map { $0.convert(point, to: nil) }
    }

    private static func postMouse(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 1,
                                  flags: NSEvent.ModifierFlags = []) {
        eventNumber += 1
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window?.windowNumber ?? 0, context: nil,
                                             eventNumber: eventNumber, clickCount: clicks,
                                             pressure: type == .leftMouseUp ? 0 : 1) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private static func nodeCentre(_ title: String) -> CGPoint? {
        nodeID(title).flatMap(nodeCentre)
    }

    private static func nodeCentre(_ id: UUID) -> CGPoint? {
        guard let rect = activeController?.viewRect(id) else { return nil }
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    private static func click(at point: CGPoint, count: Int, flags: NSEvent.ModifierFlags = []) {
        for n in 1...count {
            postMouse(.leftMouseDown, at: point, clicks: n, flags: flags)
            postMouse(.leftMouseUp, at: point, clicks: n, flags: flags)
        }
    }

    private static func clickNode(_ title: String, count: Int, flags: NSEvent.ModifierFlags = []) {
        guard let centre = nodeCentre(title), let point = windowPoint(fromCanvas: centre) else { return }
        click(at: point, count: count, flags: flags)
    }

    private static func clickCanvas(_ argument: String, count: Int) {
        let values = argument.split(separator: " ").compactMap { Double($0) }
        guard values.count == 2, let point = windowPoint(fromCanvas: CGPoint(x: values[0], y: values[1])) else { return }
        click(at: point, count: count)
    }

    /// Drags a node by (dx, dy) view points in several steps. Returns how long it takes.
    private static func dragNode(_ argument: String) -> Double {
        let parts = argument.split(separator: " ").map(String.init)
        guard parts.count >= 3, let dx = Double(parts[parts.count - 2]), let dy = Double(parts[parts.count - 1]),
              let centre = nodeCentre(parts.dropLast(2).joined(separator: " ")),
              let start = windowPoint(fromCanvas: centre) else { return 0.1 }
        postMouse(.leftMouseDown, at: start)
        for step in 1...8 {
            let t = CGFloat(step) / 8
            // Window y points up, canvas y down.
            let point = CGPoint(x: start.x + dx * t, y: start.y - dy * t)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(step)) {
                postMouse(.leftMouseDragged, at: point)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            postMouse(.leftMouseUp, at: CGPoint(x: start.x + dx, y: start.y - dy))
        }
        return 0.6
    }

    /// A two-finger scroll over the middle of the canvas. A scroll event made in code has no
    /// window, which the canvas's event monitor rightly ignores, so it goes straight to the
    /// canvas's gesture handling.
    private static func scroll(_ argument: String) {
        let values = argument.split(separator: " ").compactMap { Int32($0) }
        guard values.count == 2, let view = activeController?.keyView as? CanvasEventView,
              let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                    wheel1: values[1], wheel2: values[0], wheel3: 0),
              let event = NSEvent(cgEvent: cgEvent) else { return }
        _ = view.handleGesture(event, at: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
    }

    // MARK: Controller steps

    private static func nodeID(_ title: String) -> UUID? {
        guard let controller = activeController else { return nil }
        let id = controller.visibleIDs.first { controller.workspace.nodes[$0]?.title == title }
        if id == nil { NSLog("DebugScript: no visible node titled \(title)") }
        return id
    }

    private static func selectNode(_ title: String, extending: Bool = false) {
        guard let id = nodeID(title) else { return }
        activeController?.select(id, extending: extending)
    }

    private static func setLayout(_ name: String) {
        guard let style = LayoutStyle.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) else {
            NSLog("DebugScript: unknown layout \(name)")
            return
        }
        activeController?.setLayoutStyle(style)
    }

    /// "A -> B [slot]": the two titles and an optional drop slot.
    private static func pair(_ argument: String) -> (from: UUID, to: UUID, slot: String)? {
        let halves = argument.components(separatedBy: " -> ")
        guard halves.count == 2 else { return nil }
        var target = halves[1].trimmingCharacters(in: .whitespaces)
        var slot = "child"
        for candidate in ["before", "after", "child"] where target.hasSuffix(" " + candidate) {
            slot = candidate
            target = String(target.dropLast(candidate.count + 1))
        }
        guard let from = nodeID(halves[0].trimmingCharacters(in: .whitespaces)), let to = nodeID(target) else { return nil }
        return (from, to, slot)
    }

    /// The view point inside a node that a drop slot uses.
    private static func dropPoint(on id: UUID, slot: String) -> CGPoint? {
        guard let controller = activeController, let rect = controller.viewRect(id) else { return nil }
        let vertical = controller.style == .orgChart
        switch slot {
        case "before": return vertical ? CGPoint(x: rect.minX + 3, y: rect.midY) : CGPoint(x: rect.midX, y: rect.minY + 3)
        case "after": return vertical ? CGPoint(x: rect.maxX - 3, y: rect.midY) : CGPoint(x: rect.midX, y: rect.maxY - 3)
        default: return CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    /// Drags a node onto another (or before or after it), through the controller or with
    /// real mouse events.
    private static func dragTo(_ argument: String, realMouse: Bool) -> Double {
        guard let controller = activeController, let (from, to, slot) = pair(argument),
              let start = nodeCentre(from), let end = dropPoint(on: to, slot: slot) else { return 0.1 }
        if realMouse {
            postDrag(from: start, to: end)
            return 0.7
        }
        for step in 1...8 {
            let t = Double(step) / 8
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(step)) {
                controller.dragChanged(from, translation: CGSize(width: point.x - start.x, height: point.y - start.y),
                                       location: point)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { controller.dragEnded() }
        return 0.6
    }

    private static func points(_ argument: String) -> (CGPoint, CGPoint)? {
        let v = argument.split(separator: " ").compactMap { Double($0) }
        guard v.count == 4 else { return nil }
        return (CGPoint(x: v[0], y: v[1]), CGPoint(x: v[2], y: v[3]))
    }

    private static func marquee(_ argument: String) -> Double {
        guard let controller = activeController, let (start, end) = points(argument) else { return 0.1 }
        for step in 1...6 {
            let t = CGFloat(step) / 6
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(step)) {
                controller.backgroundDragChanged(start: start, location: point)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { controller.backgroundDragEnded() }
        return 0.5
    }

    /// A real mouse drag between two canvas points.
    private static func mouseDrag(_ argument: String) -> Double {
        guard let (start, end) = points(argument) else { return 0.1 }
        postDrag(from: start, to: end)
        return 0.7
    }

    private static func connect(_ argument: String) {
        guard let controller = activeController, let (from, to, _) = pair(argument),
              let end = nodeCentre(to) else { return }
        controller.connectDragChanged(from: from, location: end)
        controller.connectDragEnded()
    }

    /// Hovers the first node, then drags from its bottom connection handle to the second.
    private static func mouseConnect(_ argument: String) -> Double {
        guard let controller = activeController, let (from, to, _) = pair(argument),
              let rect = controller.viewRect(from), let end = nodeCentre(to) else { return 0.1 }
        controller.hoverChanged(from, inside: true)
        let handle = CGPoint(x: rect.midX, y: rect.maxY)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { postDrag(from: handle, to: end) }
        return 0.9
    }

    /// Real mouse events from one canvas point to another, in eight steps.
    private static func postDrag(from start: CGPoint, to end: CGPoint) {
        guard let a = windowPoint(fromCanvas: start), let b = windowPoint(fromCanvas: end) else { return }
        postMouse(.leftMouseDown, at: a)
        for step in 1...8 {
            let t = CGFloat(step) / 8
            let point = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(step)) {
                postMouse(.leftMouseDragged, at: point)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { postMouse(.leftMouseUp, at: b) }
    }

    /// A real marquee drag around the named nodes ("A | B | C"), starting just outside them.
    private static func mouseMarquee(_ argument: String) -> Double {
        guard let controller = activeController else { return 0.1 }
        let ids = argument.components(separatedBy: " | ").compactMap { nodeID($0.trimmingCharacters(in: .whitespaces)) }
        guard let bounds = Geometry.union(ids.compactMap { controller.viewRect($0) }) else { return 0.1 }
        postDrag(from: CGPoint(x: bounds.minX - 14, y: bounds.minY - 14), to: CGPoint(x: bounds.maxX + 14, y: bounds.maxY + 14))
        return 0.7
    }

    /// Drags the first frame on the map by its title tab ("dx dy" in view points).
    private static func mouseDragFrame(_ argument: String) -> Double {
        let values = argument.split(separator: " ").compactMap { Double($0) }
        guard values.count == 2, let controller = activeController, let frame = controller.mapFrames.first,
              let rect = controller.frameRect(frame) else { return 0.1 }
        let tab = controller.viewport.viewPoint(controller.frameTitleAnchor(rect))
        let start = CGPoint(x: tab.x + 14, y: tab.y)
        postDrag(from: start, to: CGPoint(x: start.x + values[0], y: start.y + values[1]))
        return 0.7
    }

    /// Drags the first frame on the map by ("dx dy") view points through the controller.
    private static func dragFrame(_ argument: String) -> Double {
        let values = argument.split(separator: " ").compactMap { Double($0) }
        guard values.count == 2, let controller = activeController, let frame = controller.mapFrames.first else { return 0.1 }
        for step in 1...8 {
            let t = Double(step) / 8
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(step)) {
                controller.frameDragChanged(frame.id, translation: CGSize(width: values[0] * t, height: values[1] * t))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { controller.dragEnded() }
        return 0.6
    }

    /// Clicks the middle of the connection between two nodes.
    private static func clickEdge(_ argument: String, count: Int) {
        guard let controller = activeController, let (from, to, _) = pair(argument),
              let edge = controller.workspace.edge(between: from, and: to),
              let curve = controller.relationCurve(for: edge),
              let point = windowPoint(fromCanvas: controller.viewport.viewPoint(curve.point(at: 0.4))) else { return }
        click(at: point, count: count)
    }

    /// Clicks the minimap at fractions of its width and height.
    private static func clickMinimap(_ argument: String) {
        let values = argument.split(separator: " ").compactMap { Double($0) }
        guard values.count == 2, let controller = activeController else { return }
        let point = CGPoint(x: 12 + 190 * values[0], y: controller.canvasSize.height - 12 - 124 + 124 * values[1])
        guard let window = windowPoint(fromCanvas: point) else { return }
        click(at: window, count: 1)
    }

    /// Puts text on the pasteboard copies go to: "|" separates lines and "\t" is a tab.
    private static func setClip(_ argument: String) {
        let text = argument.replacingOccurrences(of: "|", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
        let pasteboard = MapController.pasteboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func focus(_ argument: String) {
        guard let controller = activeController else { return }
        switch argument.lowercased() {
        case "on": controller.isFocusMode = true
        case "off": controller.isFocusMode = false
        default: if let hops = Int(argument) { controller.focusHops = hops }
        }
    }

    /// Feeds a node drag to the controller in steps, as the drag gesture does.
    private static func moveNode(_ argument: String) -> Double {
        let parts = argument.split(separator: " ").map(String.init)
        guard parts.count >= 3, let dx = Double(parts[parts.count - 2]), let dy = Double(parts[parts.count - 1]),
              let id = nodeID(parts.dropLast(2).joined(separator: " ")), let controller = activeController else { return 0.1 }
        for step in 1...8 {
            let t = Double(step) / 8
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(step)) {
                controller.dragChanged(id, translation: CGSize(width: dx * t, height: dy * t))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { controller.dragEnded() }
        return 0.6
    }

    private static func addNode(at argument: String) {
        let values = argument.split(separator: " ").compactMap { Double($0) }
        guard values.count == 2 else { return }
        activeController?.addNode(atView: CGPoint(x: values[0], y: values[1]))
    }

    private static func perform(_ action: String) {
        guard let controller = activeController else { return }
        switch action.lowercased() {
        case "undo": if let set = controller.workspace.undo() { controller.selectAfterHistoryStep(set) }
        case "redo": if let set = controller.workspace.redo() { controller.selectAfterHistoryStep(set) }
        case "collapse": controller.toggleCollapse()
        case "delete": controller.deleteSelection()
        case "zoomin": controller.zoomIn()
        case "zoomout": controller.zoomOut()
        case "actualsize": controller.actualSize()
        case "fit": controller.zoomToFit()
        case "background": controller.handleBackgroundClick()
        case "copy": controller.copySelection()
        case "cut": controller.cutSelection()
        case "paste": controller.paste()
        case "duplicate": controller.duplicateSelection()
        case "indent": controller.indentSelection()
        case "outdent": controller.outdentSelection()
        case "moveup": controller.moveSelection(by: -1)
        case "movedown": controller.moveSelection(by: 1)
        case "pin": controller.togglePin()
        case "unpinall": controller.unpinAll()
        case "connect": controller.connectSelection()
        case "group": controller.groupSelection()
        case "ungroup": controller.ungroup()
        case "selectall": controller.selectAll()
        case "space": controller.activateSelection()
        case "spacedown": controller.spaceDown()
        case "spaceup": controller.spaceUp()
        case "palette": activeWindow?.isPaletteVisible.toggle()
        default: NSLog("DebugScript: unknown action \(action)")
        }
    }

    /// Writes the menu bar as text: title, shortcut and whether each item is enabled.
    private static func dumpMenus(to url: URL) {
        var lines: [String] = ["keyWindow: \(NSApp.keyWindow?.title ?? "nil"), mainWindow: \(NSApp.mainWindow?.title ?? "nil")"]
        func walk(_ menu: NSMenu, depth: Int) {
            menu.update()
            for item in menu.items where !item.isSeparatorItem {
                let shortcut = item.keyEquivalent.isEmpty ? "" :
                    " [\(item.keyEquivalentModifierMask.rawValue >> 16):\(item.keyEquivalent.debugDescription)]"
                lines.append(String(repeating: "  ", count: depth) + item.title + shortcut + (item.isEnabled ? "" : " (disabled)"))
                if let submenu = item.submenu { walk(submenu, depth: depth + 1) }
            }
        }
        if let main = NSApp.mainMenu { walk(main, depth: 0) }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: State dump

    private static func dump(to url: URL) {
        guard let controller = activeController else { return }
        let workspace = controller.workspace
        func title(_ id: UUID?) -> String? { id.flatMap { workspace.nodes[$0]?.title } }
        let nodes: [[String: Any]] = controller.tree.allIDs.compactMap { id in
            guard let node = workspace.nodes[id], let p = controller.placement(id) else { return nil }
            var entry: [String: Any] = [
                "title": node.title, "kind": node.kind.rawValue,
                "x": (p.x * 10).rounded() / 10, "y": (p.y * 10).rounded() / 10,
                "collapsed": p.isCollapsed, "visible": controller.visibleSet.contains(id),
            ]
            entry["parent"] = title(p.parentID) ?? NSNull()
            if let task = node.task { entry["task"] = task.status.rawValue }
            if p.isPinned { entry["pinned"] = true }
            if let target = controller.targets[id] {
                entry["tx"] = (target.x * 10).rounded() / 10
                entry["ty"] = (target.y * 10).rounded() / 10
            }
            let size = controller.nodeSize(id)
            entry["w"] = (size.width * 10).rounded() / 10
            entry["h"] = (size.height * 10).rounded() / 10
            if let shown = controller.displays[id]?.center {
                entry["dx"] = (shown.x * 10).rounded() / 10
                entry["dy"] = (shown.y * 10).rounded() / 10
            }
            if controller.isDimmed(id) { entry["dimmed"] = true }
            return entry
        }
        let edges: [[String: Any]] = controller.mapEdges.map {
            ["from": title($0.fromID) ?? "?", "to": title($0.toID) ?? "?", "relation": $0.relation.rawValue,
             "label": $0.label, "selected": $0.id == controller.selectedEdgeID]
        }
        let frames: [[String: Any]] = controller.mapFrames.map { frame in
            var entry: [String: Any] = ["title": frame.title, "color": frame.color.rawValue,
                                        "members": frame.nodeIDs.compactMap { title($0) }.sorted(),
                                        "selected": frame.id == controller.selectedFrameID,
                                        "editing": frame.id == controller.editingFrameID]
            if let rect = controller.frameRect(frame) {
                entry["rect"] = [rect.minX.rounded(), rect.minY.rounded(), rect.width.rounded(), rect.height.rounded()]
            }
            return entry
        }
        let responder = controller.keyView?.window?.firstResponder
        let state: [String: Any] = [
            "map": controller.map.name,
            "maps": workspace.sortedMaps.map(\.name),
            "zoom": (controller.viewport.zoom * 1000).rounded() / 1000,
            "offset": [controller.viewport.offset.x.rounded(), controller.viewport.offset.y.rounded()],
            "canvasSize": [controller.canvasSize.width, controller.canvasSize.height],
            "selection": controller.selection.compactMap { title($0) }.sorted(),
            "primary": title(controller.primarySelection) ?? NSNull(),
            "editing": title(controller.editingNodeID) ?? NSNull(),
            "firstResponder": responder.map { String(describing: type(of: $0)) } ?? "nil",
            "undo": workspace.history.undoActionName ?? NSNull(),
            "redo": workspace.history.redoActionName ?? NSNull(),
            "undoDepth": workspace.history.undoStack.count,
            "active": NSApp.isActive,
            "windowIsKey": controller.keyView?.window?.isKeyWindow ?? false,
            "reactivations": reactivations,
            "nodes": nodes,
            "edges": edges,
            "frames": frames,
            "style": controller.style.rawValue,
            "focusMode": controller.isFocusMode,
            "focusHops": controller.focusHops,
            "focused": controller.focusedIDs.map { $0.compactMap { title($0) }.sorted() } ?? NSNull(),
            "picker": controller.relationPicker.map { ["edges": $0.edgeIDs.count, "coalesced": $0.coalesceKey != nil] } ?? NSNull(),
            "hovered": title(controller.hoveredNodeID) ?? NSNull(),
            "dropTarget": title(controller.dropHighlightID) ?? NSNull(),
            "spaceHeld": controller.isSpaceHeld,
            "palette": activeWindow?.isPaletteVisible ?? false,
            "pasteboard": MapController.pasteboard.string(forType: .string) ?? NSNull(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }
}
