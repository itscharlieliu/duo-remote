import UIKit

/// The desktop surface: renders the latest framebuffer image and turns
/// touches + keyboard input into RFB pointer/key events.
///
/// Two mouse modes:
/// - Direct (default on the Duo's big inner screen): touch at a point and
///   the Mac cursor goes there. Tap = click, drag = drag, long-press = right-click.
/// - Trackpad: finger movement moves the cursor relatively, like a trackpad.
///   Better when zoomed in or for precise clicks.
///
/// Keyboard: tapping the view summons the iOS keyboard; typed characters go
/// to the Mac. Hardware keyboards work the same way through UIKeyInput.
/// Modifier toggles (Ctrl / Cmd / Opt / Shift) are handled by the SwiftUI
/// toolbar, which calls `setModifier(_:down:)` here via the view's owner.
final class DesktopInputView: UIView, UIKeyInput {
    var onPointer: ((Int, Int, UInt8) -> Void)?
    var onKey: ((Bool, UInt32) -> Void)?
    var onTapToFocus: (() -> Void)?

    var trackpadMode = false

    private let imageView = UIImageView()
    private var cursor = CGPoint.zero
    private var hasCursor = false
    private var dragButtons: UInt8 = 0
    private var lastPanPoint: CGPoint?
    private var imageRect: CGRect = .zero

    // MARK: - Setup

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        addGestureRecognizer(tap)
        addGestureRecognizer(longPress)
        addGestureRecognizer(pan)
        addGestureRecognizer(twoFingerPan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setImage(_ image: UIImage?, remoteSize: CGSize) {
        imageView.image = image
        // Recompute the fitted rect so touches map to remote pixels.
        if let image {
            let fitted = fittedRect(for: image.size, in: bounds)
            imageRect = fitted
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let image = imageView.image {
            imageRect = fittedRect(for: image.size, in: bounds)
        }
    }

    private func fittedRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width, height: size.height)
    }

    /// Map a point in this view to remote desktop pixels, or nil if the
    /// touch landed on the black letterbox around the desktop.
    private func remotePoint(for point: CGPoint) -> CGPoint? {
        guard imageRect.width > 0, imageRect.height > 0,
              let imageSize = imageView.image?.size, imageSize.width > 0 else { return nil }
        guard imageRect.contains(point) else { return nil }
        let scaleX = imageSize.width / imageRect.width
        let scaleY = imageSize.height / imageRect.height
        return CGPoint(x: (point.x - imageRect.minX) * scaleX, y: (point.y - imageRect.minY) * scaleY)
    }

    // MARK: - Gestures

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        onTapToFocus?()
        becomeFirstResponder()
        guard let point = remotePoint(for: gesture.location(in: self)) else { return }
        cursor = point
        hasCursor = true
        if trackpadMode {
            // In trackpad mode a tap is a click at the current cursor.
            sendPointer(buttons: 1)
            sendPointer(buttons: 0)
        } else {
            sendPointer(buttons: 1)
            sendPointer(buttons: 0)
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began,
              let point = remotePoint(for: gesture.location(in: self)) else { return }
        cursor = point
        hasCursor = true
        // Button 3 = right-click.
        sendPointer(buttons: 4)
        sendPointer(buttons: 0)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            if trackpadMode {
                lastPanPoint = location
            } else if let point = remotePoint(for: location) {
                cursor = point
                hasCursor = true
                dragButtons = 1
                sendPointer(buttons: 1)
            }
        case .changed:
            if trackpadMode {
                if let last = lastPanPoint, hasCursor {
                    cursor.x += location.x - last.x
                    cursor.y += location.y - last.y
                    // Clamp to the desktop, not the view.
                    if let size = imageView.image?.size {
                        cursor.x = min(max(cursor.x, 0), size.width - 1)
                        cursor.y = min(max(cursor.y, 0), size.height - 1)
                    }
                    sendPointer(buttons: dragButtons)
                }
                lastPanPoint = location
            } else if let point = remotePoint(for: location) {
                cursor = point
                sendPointer(buttons: dragButtons)
            }
        case .ended, .cancelled:
            dragButtons = 0
            lastPanPoint = nil
            sendPointer(buttons: 0)
        default:
            break
        }
    }

    @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        // Two-finger drag = scroll wheel: RFB buttons 4 (up) and 5 (down).
        // One click per ~24pt of vertical travel, which feels like a trackpad.
        guard gesture.state == .changed, hasCursor else { return }
        let translation = gesture.translation(in: self)
        let steps = Int(translation.y / 24)
        guard steps != 0 else { return }
        gesture.setTranslation(.zero, in: self)
        let button: UInt8 = steps < 0 ? 8 : 16 // RFB scroll-up / scroll-down bits
        for _ in 0..<abs(steps) {
            sendPointer(buttons: button)
            sendPointer(buttons: 0)
        }
    }

    private func sendPointer(buttons: UInt8) {
        onPointer?(Int(cursor.x), Int(cursor.y), buttons)
    }

    // MARK: - Keyboard (UIKeyInput)

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { false }

    func insertText(_ text: String) {
        for character in text {
            if character == "\n" {
                onKey?(true, VNCKeys.return)
                onKey?(false, VNCKeys.return)
            } else if let keysym = VNCKeys.keysym(for: character) {
                onKey?(true, keysym)
                onKey?(false, keysym)
            }
        }
    }

    func deleteBackward() {
        onKey?(true, VNCKeys.backspace)
        onKey?(false, VNCKeys.backspace)
    }

    /// Called by the SwiftUI toolbar when a modifier toggle changes.
    func setModifier(_ keysym: UInt32, down: Bool) {
        onKey?(down, keysym)
    }
}
