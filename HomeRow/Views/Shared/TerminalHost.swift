import SwiftUI
import SwiftTerm

/// Hosts a session's long-lived `TerminalView` in SwiftUI. The terminal view
/// is re-parented, never recreated, so scrollback survives layout changes.
struct TerminalHost: UIViewRepresentable {
    let session: TerminalSession
    /// True when the deck keyboard is showing (suppress the system keyboard).
    var deckKeyboard: Bool
    var focus = true

    func makeUIView(context: Context) -> Container {
        Container()
    }

    func updateUIView(_ container: Container, context: Context) {
        container.attach(session.terminalView)
        session.applyPreferences()
        session.setUsesDeckKeyboard(deckKeyboard)
        if focus {
            DispatchQueue.main.async {
                if container.window != nil, !session.terminalView.isFirstResponder {
                    _ = session.terminalView.becomeFirstResponder()
                }
            }
        }
    }

    static func dismantleUIView(_ container: Container, coordinator: ()) {
        container.detach()
    }

    final class Container: UIView {
        private weak var hosted: UIView?

        func attach(_ view: UIView) {
            guard view.superview !== self else { return }
            view.removeFromSuperview()
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
            hosted = view
        }

        func detach() {
            if let hosted, hosted.superview === self { hosted.removeFromSuperview() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            hosted?.frame = bounds
        }
    }
}

/// A hidden first responder that sends the system keyboard's typing to the
/// Mac (folded and flat screen sessions, where there's no deck).
struct KeyCapture: UIViewRepresentable {
    let session: ScreenSession
    @Binding var active: Bool

    func makeUIView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.session = session
        return view
    }

    func updateUIView(_ view: CaptureView, context: Context) {
        view.session = session
        DispatchQueue.main.async {
            if active, !view.isFirstResponder { view.becomeFirstResponder() }
            if !active, view.isFirstResponder { view.resignFirstResponder() }
        }
    }

    final class CaptureView: UIView, UIKeyInput {
        weak var session: ScreenSession?
        override var canBecomeFirstResponder: Bool { true }
        var hasText: Bool { true }
        var autocorrectionType: UITextAutocorrectionType = .no
        var autocapitalizationType: UITextAutocapitalizationType = .none
        var spellCheckingType: UITextSpellCheckingType = .no
        var smartQuotesType: UITextSmartQuotesType = .no
        var smartDashesType: UITextSmartDashesType = .no
        var keyboardType: UIKeyboardType = .asciiCapable

        func insertText(_ text: String) {
            MainActor.assumeIsolated {
                guard let session else { return }
                if text == "\n" { session.press(Keysym.returnKey) } else { session.type(text) }
            }
        }

        func deleteBackward() {
            MainActor.assumeIsolated { session?.press(Keysym.backspace) }
        }

        // Hardware keyboard: pass ⌘/⌥/⌃ chords and special keys through.
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var handled = false
            for press in presses {
                guard let key = press.key else { continue }
                handled = MainActor.assumeIsolated { sendHardware(key) } || handled
            }
            if !handled { super.pressesBegan(presses, with: event) }
        }

        @MainActor
        private func sendHardware(_ key: UIKey) -> Bool {
            guard let session else { return false }
            var mods: [UInt32] = []
            if key.modifierFlags.contains(.control) { mods.append(Keysym.control) }
            if key.modifierFlags.contains(.alternate) { mods.append(Keysym.option) }
            if key.modifierFlags.contains(.command) { mods.append(Keysym.command) }
            let special: [UIKeyboardHIDUsage: UInt32] = [
                .keyboardUpArrow: Keysym.up, .keyboardDownArrow: Keysym.down,
                .keyboardLeftArrow: Keysym.left, .keyboardRightArrow: Keysym.right,
                .keyboardEscape: Keysym.escape, .keyboardTab: Keysym.tab,
                .keyboardDeleteOrBackspace: Keysym.backspace, .keyboardReturnOrEnter: Keysym.returnKey,
                .keyboardPageUp: Keysym.pageUp, .keyboardPageDown: Keysym.pageDown,
                .keyboardHome: Keysym.home, .keyboardEnd: Keysym.end,
                .keyboardDeleteForward: Keysym.forwardDelete,
            ]
            if let sym = special[key.keyCode] {
                if key.modifierFlags.contains(.shift) { mods.append(Keysym.shift) }
                session.press(sym, modifiers: mods)
                return true
            }
            guard !mods.isEmpty, let c = key.charactersIgnoringModifiers.first,
                  let sym = Keysym.character(c) else { return false }
            if key.modifierFlags.contains(.shift) { mods.append(Keysym.shift) }
            session.press(sym, modifiers: mods)
            return true
        }
    }
}
