import SwiftUI
import UIKit
import AVFoundation

/// The Mac's screen.
///
/// `.direct`: tap where you want to click, drag to drag, long-press or
/// two-finger tap to right-click. `.relative`: the whole surface is a
/// trackpad (flat posture with touch off). In both, pinch zooms; two-finger
/// drag scrolls the Mac at 1×, and pans the view when zoomed in.
struct RemoteScreen: UIViewRepresentable {
    enum Mode { case direct, relative }

    let session: ScreenSession
    var mode: Mode

    func makeUIView(context: Context) -> RemoteScreenView {
        let view = RemoteScreenView()
        view.session = session
        return view
    }

    func updateUIView(_ view: RemoteScreenView, context: Context) {
        view.session = session
        view.mode = mode
        view.update(frame: session.frame, size: session.screenSize,
                    cursor: session.cursorImage, hotspot: session.cursorHotspot, pointer: session.pointer)
    }
}

final class RemoteScreenView: UIView, UIGestureRecognizerDelegate {
    weak var session: ScreenSession?
    var mode: RemoteScreen.Mode = .direct

    private let imageLayer = CALayer()
    private let cursorLayer = CALayer()
    private let ripple = CAShapeLayer()
    private var remoteSize = CGSize(width: 1, height: 1)
    private var zoom: CGFloat = 1
    private var pan = CGPoint.zero
    private var scrollRemainder = CGPoint.zero
    private var dragging = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0x0E / 255, green: 0x0E / 255, blue: 0x10 / 255, alpha: 1)
        clipsToBounds = true
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        imageLayer.cornerRadius = 6
        imageLayer.masksToBounds = true
        layer.addSublayer(imageLayer)
        cursorLayer.contentsGravity = .resize
        cursorLayer.zPosition = 10
        layer.addSublayer(cursorLayer)
        ripple.fillColor = UIColor.white.withAlphaComponent(0.12).cgColor
        ripple.strokeColor = UIColor.white.withAlphaComponent(0.7).cgColor
        ripple.lineWidth = 2
        ripple.opacity = 0
        layer.addSublayer(ripple)
        installGestures()
        isAccessibilityElement = true
        accessibilityLabel = "Mac screen"
        accessibilityTraits = .allowsDirectInteraction
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(frame: CGImage?, size: CGSize, cursor: CGImage?, hotspot: CGPoint, pointer: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let frame { imageLayer.contents = frame }
        remoteSize = size
        cursorLayer.contents = cursor
        cursorLayer.isHidden = cursor == nil
        layoutImage()
        placeCursor(pointer: pointer, hotspot: hotspot, cursor: cursor)
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutImage()
        if let session {
            placeCursor(pointer: session.pointer, hotspot: session.cursorHotspot, cursor: session.cursorImage)
        }
        CATransaction.commit()
    }

    // MARK: Geometry

    /// Where the remote screen is drawn, after aspect-fit, zoom and pan.
    private var contentRect: CGRect {
        let fit = AVMakeRect(aspectRatio: remoteSize, insideRect: bounds.insetBy(dx: 0, dy: 0))
        let w = fit.width * zoom, h = fit.height * zoom
        return CGRect(x: fit.midX - w / 2 + pan.x, y: fit.midY - h / 2 + pan.y, width: w, height: h)
    }

    private var pointsPerPixel: CGFloat { contentRect.width / max(1, remoteSize.width) }

    private func layoutImage() { imageLayer.frame = contentRect }

    private func placeCursor(pointer: CGPoint, hotspot: CGPoint, cursor: CGImage?) {
        guard let cursor else { return }
        let scale = pointsPerPixel
        let p = toView(pointer)
        cursorLayer.frame = CGRect(
            x: p.x - hotspot.x * scale, y: p.y - hotspot.y * scale,
            width: CGFloat(cursor.width) * scale, height: CGFloat(cursor.height) * scale)
    }

    private func toRemote(_ p: CGPoint) -> CGPoint {
        let r = contentRect
        return CGPoint(x: (p.x - r.minX) / r.width * remoteSize.width,
                       y: (p.y - r.minY) / r.height * remoteSize.height)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let r = contentRect
        return CGPoint(x: r.minX + p.x / remoteSize.width * r.width,
                       y: r.minY + p.y / remoteSize.height * r.height)
    }

    private func clampPan() {
        let fit = AVMakeRect(aspectRatio: remoteSize, insideRect: bounds)
        let maxX = max(0, (fit.width * zoom - bounds.width) / 2)
        let maxY = max(0, (fit.height * zoom - bounds.height) / 2)
        pan.x = min(maxX, max(-maxX, pan.x))
        pan.y = min(maxY, max(-maxY, pan.y))
    }

    /// Keeps the pointer on screen while zoomed (trackpad mode).
    private func follow(_ pointer: CGPoint) {
        guard zoom > 1.01 else { return }
        let p = toView(pointer)
        let margin: CGFloat = 40
        if p.x < margin { pan.x += margin - p.x }
        if p.x > bounds.width - margin { pan.x -= p.x - (bounds.width - margin) }
        if p.y < margin { pan.y += margin - p.y }
        if p.y > bounds.height - margin { pan.y -= p.y - (bounds.height - margin) }
        clampPan()
        setNeedsLayout()
    }

    // MARK: Gestures

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        let twoTap = UITapGestureRecognizer(target: self, action: #selector(onTwoFingerTap(_:)))
        twoTap.numberOfTouchesRequired = 2
        let long = UILongPressGestureRecognizer(target: self, action: #selector(onLongPress(_:)))
        long.minimumPressDuration = 0.45
        let drag = UIPanGestureRecognizer(target: self, action: #selector(onDrag(_:)))
        drag.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.allowedScrollTypesMask = .all
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        for g in [tap, twoTap, long, drag, scroll, pinch] as [UIGestureRecognizer] {
            g.delegate = self
            addGestureRecognizer(g)
        }
        // Pointer hover from a trackpad/mouse attached to the phone.
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:))))
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
            || (other is UIPinchGestureRecognizer && g is UIPanGestureRecognizer)
    }

    @MainActor @objc private func onTap(_ g: UITapGestureRecognizer) {
        guard let session else { return }
        if mode == .direct {
            let point = g.location(in: self)
            session.movePointer(to: toRemote(point))
            showRipple(at: point)
        }
        session.click()
        Haptics.tap()
    }

    @MainActor @objc private func onTwoFingerTap(_ g: UITapGestureRecognizer) {
        guard let session else { return }
        if mode == .direct { session.movePointer(to: toRemote(g.location(in: self))) }
        session.click(4)
        Haptics.tap()
    }

    @MainActor @objc private func onLongPress(_ g: UILongPressGestureRecognizer) {
        guard let session, g.state == .began, !dragging else { return }
        if mode == .direct {
            session.movePointer(to: toRemote(g.location(in: self)))
            session.click(4)
            Haptics.tap()
        }
    }

    @MainActor @objc private func onDrag(_ g: UIPanGestureRecognizer) {
        guard let session else { return }
        switch mode {
        case .direct:
            let point = g.location(in: self)
            switch g.state {
            case .began:
                // Start from where the finger first landed, not where the pan
                // was recognized.
                let start = CGPoint(x: point.x - g.translation(in: self).x, y: point.y - g.translation(in: self).y)
                session.movePointer(to: toRemote(start))
                session.setButton(1, down: true)
                session.movePointer(to: toRemote(point))
                dragging = true
            case .changed:
                session.movePointer(to: toRemote(point))
            default:
                session.setButton(1, down: false)
                dragging = false
            }
        case .relative:
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            let v = g.velocity(in: self)
            let speed = hypot(v.x, v.y)
            let accel = min(3.2, max(1, speed / 700))
            let factor = accel * max(1.2, remoteSize.width / max(1, bounds.width))
            session.movePointer(by: CGPoint(x: t.x * factor, y: t.y * factor))
            follow(session.pointer)
        }
    }

    @MainActor @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        guard let session else { return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        if zoom > 1.01 {
            pan.x += t.x
            pan.y += t.y
            clampPan()
            setNeedsLayout()
            return
        }
        scrollRemainder.x += t.x
        scrollRemainder.y += t.y
        let step: CGFloat = 12
        let dy = Int(scrollRemainder.y / step)
        let dx = Int(scrollRemainder.x / step)
        if dy != 0 || dx != 0 {
            session.scroll(dx: dx, dy: dy)
            scrollRemainder.x -= CGFloat(dx) * step
            scrollRemainder.y -= CGFloat(dy) * step
        }
        if g.state == .ended { scrollRemainder = .zero }
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        let anchor = g.location(in: self)
        let before = toRemote(anchor)
        zoom = min(6, max(1, zoom * g.scale))
        g.scale = 1
        // Keep the remote point under the fingers fixed while zooming.
        let after = toView(before)
        pan.x += anchor.x - after.x
        pan.y += anchor.y - after.y
        if zoom <= 1.001 { pan = .zero }
        clampPan()
        setNeedsLayout()
    }

    @MainActor @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        guard let session, mode == .direct, g.state == .changed else { return }
        session.movePointer(to: toRemote(g.location(in: self)))
    }

    private func showRipple(at point: CGPoint) {
        ripple.path = UIBezierPath(ovalIn: CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)).cgPath
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.35
        ripple.add(fade, forKey: "fade")
    }
}

/// The lower half in trackpad mode: relative pointer, tap to click,
/// two-finger tap to right-click, two-finger drag to scroll, press-and-hold
/// then move to drag. Shows finger halos like the design.
struct Trackpad: UIViewRepresentable {
    let session: ScreenSession

    func makeUIView(context: Context) -> TrackpadView {
        let view = TrackpadView()
        view.session = session
        return view
    }

    func updateUIView(_ view: TrackpadView, context: Context) { view.session = session }
}

final class TrackpadView: UIView, UIGestureRecognizerDelegate {
    weak var session: ScreenSession?
    private var halos: [UITouch: CALayer] = [:]
    private var scrollRemainder = CGPoint.zero
    private var holdingDrag = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        let gradient = CAGradientLayer()
        gradient.colors = [UIColor(red: 0x3C / 255, green: 0x3D / 255, blue: 0x40 / 255, alpha: 1).cgColor,
                           UIColor(red: 0x35 / 255, green: 0x36 / 255, blue: 0x3A / 255, alpha: 1).cgColor]
        gradient.cornerRadius = 14
        gradient.borderColor = UIColor.black.withAlphaComponent(0.45).cgColor
        gradient.borderWidth = 1
        layer.insertSublayer(gradient, at: 0)
        background = gradient

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap))
        let twoTap = UITapGestureRecognizer(target: self, action: #selector(onTwoTap))
        twoTap.numberOfTouchesRequired = 2
        let move = UIPanGestureRecognizer(target: self, action: #selector(onMove(_:)))
        move.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(onHold(_:)))
        // Rest a finger still for a moment, then move: drag. Moving right
        // away is an ordinary pointer move.
        hold.minimumPressDuration = 0.4
        hold.allowableMovement = 8
        for g in [tap, twoTap, move, scroll, hold] as [UIGestureRecognizer] {
            g.delegate = self
            addGestureRecognizer(g)
        }
        isAccessibilityElement = true
        accessibilityLabel = "Trackpad"
        accessibilityTraits = .allowsDirectInteraction
    }

    private var background: CAGradientLayer?
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        background?.frame = bounds
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g is UILongPressGestureRecognizer || other is UILongPressGestureRecognizer
    }

    private var pointerFactor: CGFloat {
        let width = session?.screenSize.width ?? 1440
        return max(1.4, width / 900)
    }

    @MainActor @objc private func onTap() { session?.click(); Haptics.tap() }
    @MainActor @objc private func onTwoTap() { session?.click(4); Haptics.tap() }

    @MainActor @objc private func onMove(_ g: UIPanGestureRecognizer) {
        guard !holdingDrag else { return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        let v = g.velocity(in: self)
        let accel = min(3.5, max(1, hypot(v.x, v.y) / 600))
        session?.movePointer(by: CGPoint(x: t.x * accel * pointerFactor, y: t.y * accel * pointerFactor))
    }

    @MainActor @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        scrollRemainder.x += t.x
        scrollRemainder.y += t.y
        let step: CGFloat = 10
        let dy = Int(scrollRemainder.y / step), dx = Int(scrollRemainder.x / step)
        if dx != 0 || dy != 0 {
            session?.scroll(dx: dx, dy: dy)
            scrollRemainder.x -= CGFloat(dx) * step
            scrollRemainder.y -= CGFloat(dy) * step
        }
        if g.state == .ended { scrollRemainder = .zero }
    }

    private var lastHold = CGPoint.zero

    @MainActor @objc private func onHold(_ g: UILongPressGestureRecognizer) {
        guard let session, g.numberOfTouches <= 1 else { return }
        let p = g.location(in: self)
        switch g.state {
        case .began:
            holdingDrag = true
            lastHold = p
            session.setButton(1, down: true)
            Haptics.tap()
        case .changed:
            session.movePointer(by: CGPoint(x: (p.x - lastHold.x) * pointerFactor, y: (p.y - lastHold.y) * pointerFactor))
            lastHold = p
        default:
            if holdingDrag { session.setButton(1, down: false) }
            holdingDrag = false
        }
    }

    // Finger halos.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        for t in touches {
            let halo = CALayer()
            halo.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
            halo.cornerRadius = 22
            halo.backgroundColor = UIColor.white.withAlphaComponent(0.07).cgColor
            halo.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
            halo.borderWidth = 1
            halo.position = t.location(in: self)
            layer.addSublayer(halo)
            halos[t] = halo
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for t in touches { halos[t]?.position = t.location(in: self) }
        CATransaction.commit()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        for t in touches { halos.removeValue(forKey: t)?.removeFromSuperlayer() }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        for t in touches { halos.removeValue(forKey: t)?.removeFromSuperlayer() }
    }
}

