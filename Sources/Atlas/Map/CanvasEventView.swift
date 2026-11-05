import AppKit
import AtlasLayout
import SwiftUI

/// An invisible AppKit view behind the canvas. It never takes clicks (SwiftUI handles
/// those), but it is the canvas's first responder for keyboard commands, and it turns
/// trackpad scrolling and pinching over the canvas into panning and zooming.
struct CanvasEventCatcher: NSViewRepresentable {
    let controller: MapController

    func makeNSView(context: Context) -> CanvasEventView {
        let view = CanvasEventView()
        view.controller = controller
        controller.keyView = view
        return view
    }

    func updateNSView(_ view: CanvasEventView, context: Context) {
        view.controller = controller
        controller.keyView = view
    }

    static func dismantleNSView(_ view: CanvasEventView, coordinator: ()) {
        view.removeMonitor()
    }
}

final class CanvasEventView: NSView {
    weak var controller: MapController?
    private var monitor: Any?
    /// The last point of a middle-button drag, which pans the canvas.
    private var middleDragLast: CGPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        let mask: NSEvent.EventTypeMask = [.scrollWheel, .magnify, .smartMagnify, .otherMouseDown, .otherMouseDragged, .otherMouseUp]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  self.controller?.isObscured != true else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            if self.middleDragLast != nil, event.type == .otherMouseDragged || event.type == .otherMouseUp {
                return self.handleGesture(event, at: point) ? nil : event
            }
            guard self.bounds.contains(point), self.isVisibleInWindow else { return event }
            return self.handleGesture(event, at: point) ? nil : event
        }
        DispatchQueue.main.async { [weak self] in self?.controller?.focusCanvas() }
    }

    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private var isVisibleInWindow: Bool {
        !isHiddenOrHasHiddenAncestor && visibleRect.width > 0
    }

    func handleGesture(_ event: NSEvent, at point: CGPoint) -> Bool {
        guard let controller else { return false }
        switch event.type {
        case .magnify:
            controller.zoom(by: 1 + event.magnification, around: point)
            return true
        case .smartMagnify:
            controller.smartZoom(at: point)
            return true
        case .scrollWheel:
            if event.modifierFlags.contains(.command) {
                let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
                controller.zoom(by: exp(step), around: point)
            } else {
                let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                controller.pan(by: CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale))
            }
            return true
        case .otherMouseDown where event.buttonNumber == 2:
            middleDragLast = point
            NSCursor.closedHand.set()
            return true
        case .otherMouseDragged where middleDragLast != nil:
            if let last = middleDragLast {
                controller.pan(by: CGSize(width: point.x - last.x, height: point.y - last.y))
            }
            middleDragLast = point
            return true
        case .otherMouseUp where middleDragLast != nil:
            middleDragLast = nil
            NSCursor.arrow.set()
            return true
        default:
            return false
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let controller, handleKey(event, controller: controller) else {
            super.keyDown(with: event)
            return
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49, let controller, controller.isSpaceHeld {
            controller.spaceUp()
            return
        }
        super.keyUp(with: event)
    }

    override func resignFirstResponder() -> Bool {
        // A Space released elsewhere must not leave the canvas in panning mode.
        if let controller, controller.isSpaceHeld {
            controller.isSpaceHeld = false
            controller.spaceDidPan = false
            NSCursor.arrow.set()
        }
        return super.resignFirstResponder()
    }

    private func handleKey(_ event: NSEvent, controller: MapController) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let noModifiers = flags.isEmpty

        // While the relation menu is open, digits pick a relation and Esc closes it.
        if controller.relationPicker != nil {
            if noModifiers, let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }),
               controller.pickRelation(number: digit) {
                return true
            }
            if event.keyCode == 53 {
                controller.dismissRelationPicker()
                return true
            }
        }

        switch event.keyCode {
        case 48 where noModifiers: // Tab
            controller.addChild()
        case 48 where flags == .shift: // ⇧Tab
            controller.outdentSelection()
        case 36 where noModifiers, 76 where noModifiers: // Return, Enter
            if controller.selectedEdgeID != nil || controller.selectedFrameID != nil {
                controller.activateSelection()
            } else {
                controller.addSibling()
            }
        case 49 where noModifiers: // Space: pans while held, edits when tapped
            if !event.isARepeat { controller.spaceDown() }
        case 51, 117: // Delete, Forward Delete
            guard flags.isSubset(of: [.command]) else { return false }
            controller.deleteSelection()
        case 123, 124, 125, 126: // Arrows
            guard flags.isSubset(of: [.shift]) else { return false }
            let direction: SpatialNavigation.Direction = switch event.keyCode {
            case 123: .left
            case 124: .right
            case 125: .down
            default: .up
            }
            controller.navigate(direction, extending: flags.contains(.shift))
        case 53: // Escape
            if !controller.selection.isEmpty || controller.selectedEdgeID != nil || controller.selectedFrameID != nil {
                controller.clearSelection()
            } else if controller.isFocusMode {
                controller.isFocusMode = false
            }
        case 120 where noModifiers: // F2
            controller.activateSelection()
        default:
            // Typing a character starts editing the selected node, replacing its title.
            guard flags.isSubset(of: [.shift]), controller.selection.count == 1,
                  let characters = event.characters, let scalar = characters.unicodeScalars.first,
                  !CharacterSet.controlCharacters.contains(scalar), scalar.value < 0xF700 else { return false }
            controller.beginEditing(replacingWith: characters)
        }
        return true
    }

    // MARK: Edit menu (sent down the responder chain)

    @objc func copy(_ sender: Any?) {
        controller?.copySelection()
    }

    @objc func cut(_ sender: Any?) {
        controller?.cutSelection()
    }

    @objc func paste(_ sender: Any?) {
        controller?.paste()
    }

    @objc func delete(_ sender: Any?) {
        controller?.deleteSelection()
    }

    override func selectAll(_ sender: Any?) {
        controller?.selectAll()
    }

    override func cancelOperation(_ sender: Any?) {
        controller?.clearSelection()
    }
}

extension CanvasEventView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let controller else { return false }
        switch menuItem.action {
        case #selector(copy(_:)), #selector(cut(_:)):
            return controller.canCopy
        case #selector(paste(_:)):
            return controller.canPaste
        case #selector(delete(_:)):
            return !controller.selection.isEmpty || controller.selectedEdgeID != nil || controller.selectedFrameID != nil
        case #selector(selectAll(_:)):
            return !controller.visibleIDs.isEmpty
        default:
            return true
        }
    }
}
