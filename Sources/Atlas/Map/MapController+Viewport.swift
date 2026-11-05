import AppKit
import AtlasLayout
import CoreGraphics
import Foundation

/// Panning, zooming and scrolling to nodes.
extension MapController {

    func pan(by delta: CGSize) {
        autoFit = false
        viewportAnimator.stop()
        viewport.offset.x += delta.width
        viewport.offset.y += delta.height
    }

    func zoom(by factor: CGFloat, around anchor: CGPoint? = nil) {
        autoFit = false
        viewportAnimator.stop()
        let anchor = anchor ?? viewCenter
        let newZoom = (viewport.zoom * factor).clamped(to: Viewport.minZoom...Viewport.maxZoom)
        let world = worldPoint(anchor)
        viewport = Viewport(offset: CGPoint(x: anchor.x - world.x * newZoom, y: anchor.y - world.y * newZoom), zoom: newZoom)
    }

    func zoomIn() { animateZoom(to: viewport.zoom * 1.25) }
    func zoomOut() { animateZoom(to: viewport.zoom / 1.25) }
    func actualSize() { animateZoom(to: 1) }

    private func animateZoom(to zoom: CGFloat) {
        let z = zoom.clamped(to: Viewport.minZoom...Viewport.maxZoom)
        let world = worldPoint(viewCenter)
        setViewport(Viewport(offset: CGPoint(x: viewCenter.x - world.x * z, y: viewCenter.y - world.y * z), zoom: z),
                    animated: true)
    }

    func zoomToFit(animated: Bool = true) {
        guard canvasSize.width > 0 else { return }
        setViewport(fittingViewport(), animated: animated)
    }

    /// Fits the given nodes (focus mode: the focused part of the map).
    func zoom(toFit ids: [UUID]) {
        guard canvasSize.width > 0, let bounds = Geometry.union(ids.compactMap(targetRect)) else { return }
        setViewport(.fitting(bounds, in: canvasSize), animated: true)
    }

    /// The rectangle around every visible node, where the layout is taking it.
    var targetBounds: CGRect? {
        Geometry.union(visibleIDs.compactMap(targetRect))
    }

    /// Zooms to fit when part of the map (where nodes are headed) is out of view.
    func fitIfOutOfView() {
        guard canvasSize.width > 0, let bounds = targetBounds else { return }
        if !visibleWorldRect.insetBy(dx: 12 / viewport.zoom, dy: 12 / viewport.zoom).contains(bounds) { zoomToFit() }
    }

    /// The viewport that shows every visible node (or the origin at 100 % for an empty map).
    func fittingViewport() -> Viewport {
        guard let bounds = targetBounds else {
            return Viewport(offset: viewCenter, zoom: 1)
        }
        return .fitting(bounds, in: canvasSize)
    }

    /// Smart zoom (two-finger double tap): toggles between fitting the map and 100 %.
    func smartZoom(at point: CGPoint) {
        if abs(viewport.zoom - 1) < 0.05 {
            zoomToFit()
        } else {
            let world = worldPoint(point)
            setViewport(Viewport(offset: CGPoint(x: viewCenter.x - world.x, y: viewCenter.y - world.y), zoom: 1), animated: true)
        }
    }

    func centre(on id: UUID) {
        guard let rect = targetRect(id), canvasSize.width > 0 else { return }
        let zoom = max(viewport.zoom, 0.6)
        setViewport(Viewport(offset: CGPoint(x: viewCenter.x - rect.midX * zoom, y: viewCenter.y - rect.midY * zoom), zoom: zoom),
                    animated: true)
    }

    /// Centres the view on a point of the map, keeping the zoom (minimap clicks and drags).
    func centre(onWorld point: CGPoint, animated: Bool) {
        guard canvasSize.width > 0 else { return }
        let zoom = viewport.zoom
        setViewport(Viewport(offset: CGPoint(x: viewCenter.x - point.x * zoom, y: viewCenter.y - point.y * zoom), zoom: zoom),
                    animated: animated)
    }

    /// Scrolls just enough to bring a node fully into view.
    func ensureVisible(_ id: UUID) {
        guard let world = targetRect(id), canvasSize.width > 0 else { return }
        let rect = viewport.viewRect(world)
        let inset: CGFloat = 40
        let bounds = CGRect(origin: .zero, size: canvasSize).insetBy(dx: inset, dy: inset)
        guard !bounds.contains(rect) else { return }
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        if rect.width > bounds.width || rect.minX < bounds.minX { dx = bounds.minX - rect.minX }
        else if rect.maxX > bounds.maxX { dx = bounds.maxX - rect.maxX }
        if rect.height > bounds.height || rect.minY < bounds.minY { dy = bounds.minY - rect.minY }
        else if rect.maxY > bounds.maxY { dy = bounds.maxY - rect.maxY }
        var target = viewport
        target.offset.x += dx
        target.offset.y += dy
        setViewport(target, animated: true)
    }

    func setViewport(_ target: Viewport, animated: Bool) {
        autoFit = false
        guard animated, canvasSize.width > 0 else {
            viewportAnimator.stop()
            viewport = target
            return
        }
        viewportAnimator.animate(from: viewport, to: target, in: canvasSize) { [weak self] value in
            self?.viewport = value
        }
    }

    /// Below this zoom a large map draws its nodes as simple shapes in one canvas instead
    /// of as views: titles are unreadable there anyway, and it keeps panning smooth.
    static let overviewZoom: CGFloat = 0.35

    var isOverview: Bool {
        viewport.zoom < Self.overviewZoom && visibleIDs.count > Self.cullingThreshold && editingNodeID == nil
            && !Self.voiceOverIsOn
    }

    /// With VoiceOver on, every node stays a view so it can be read and navigated to.
    static var voiceOverIsOn: Bool { NSWorkspace.shared.isVoiceOverEnabled }

    /// Maps up to this size draw every node; larger ones draw only nodes near the view.
    static let cullingThreshold = 250

    /// Picks the nodes to draw as views. SwiftUI's cost per frame grows with the number of
    /// node views, even off-screen ones, so a large map draws the nodes within a screen's
    /// width or so of the view. Panning recomputes the set only when the view leaves that
    /// area, so most frames only move the layer. Selected and edited nodes always stay.
    func updateCulling(force: Bool = false) {
        guard visibleIDs.count > Self.cullingThreshold, canvasSize.width > 0, canvasSize.height > 0,
              !Self.voiceOverIsOn else {
            cullRect = nil
            if renderedIDs != visibleIDs { renderedIDs = visibleIDs }
            return
        }
        let view = visibleWorldRect
        if !force, let cull = cullRect, cull.contains(view),
           view.width * view.height * 16 > cull.width * cull.height {
            return
        }
        let area = view.insetBy(dx: -view.width * 0.6, dy: -view.height * 0.6)
        var keep = selection
        if let editingNodeID { keep.insert(editingNodeID) }
        let ids = visibleIDs.filter { id in
            if keep.contains(id) { return true }
            let size = nodeSize(id)
            if let center = displays[id]?.center, area.intersects(Geometry.rect(center: center, size: size)) { return true }
            if let target = targets[id], area.intersects(Geometry.rect(center: target, size: size)) { return true }
            return false
        }
        cullRect = area
        if ids != renderedIDs { renderedIDs = ids }
    }

    /// The part of the map currently in view, in map coordinates.
    var visibleWorldRect: CGRect {
        viewport.worldRect(CGRect(origin: .zero, size: canvasSize))
    }

    func scheduleViewportSave() {
        viewportSaveTask?.cancel()
        let mapID = self.mapID
        viewportSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            ViewportStore.save(self.viewport, for: mapID)
        }
    }
}
