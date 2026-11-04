import SwiftUI

/// The inner display with sessions open.
///
/// Deck (half-folded, portrait): the session sits above the crease; below it,
/// the MacBook deck — full keyboard for terminals, strip + trackpad for
/// screens. Flat (landscape): screen sessions go full-bleed with direct
/// touch and a floating key strip.
struct OpenWorkspace: View {
    let posture: Posture
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @State private var modifiers = ModifierState()
    @State private var lowerMode: LowerMode?
    @State private var flatTouch = true
    @State private var flatKeyboard: Bool

    init(posture: Posture, flatKeyboard: Bool = false) {
        self.posture = posture
        _flatKeyboard = State(initialValue: flatKeyboard)
    }

    enum LowerMode { case trackpad, keyboard }

    var body: some View {
        GeometryReader { geo in
            let safeTop = geo.safeAreaInsets.top
            let full = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            if posture == .flat, model.focus == .screen, let screen = model.screen {
                flatScreen(screen, safeTop: safeTop, height: full)
            } else {
                VStack(spacing: 0) {
                    upper(safeTop: safeTop)
                        .frame(height: full / 2 - 4)
                    Crease()
                    lower
                        .padding(.horizontal, 8)
                        .padding(.top, 10)
                        .padding(.bottom, max(16, geo.safeAreaInsets.bottom))
                        .frame(height: full / 2 - 4)
                }
                .ignoresSafeArea()
            }
        }
        .onChange(of: model.focus) { _, _ in modifiers = ModifierState() }
    }

    // MARK: Upper half

    private func upper(safeTop: CGFloat) -> some View {
        VStack(spacing: 0) {
            SessionTabs()
                .padding(.horizontal, 14)
                .padding(.top, safeTop + 4)
                .padding(.bottom, 8)
            Group {
                if let terminal = model.focusedTerminal {
                    TerminalPane(session: terminal, deckKeyboard: true)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                } else if model.focus == .screen, let screen = model.screen {
                    ScreenPane(session: screen, mode: .direct)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(model.focus == .screen ? Theme.remoteBlack : Theme.screenBlack)
    }

    // MARK: Lower half (the deck)

    @ViewBuilder
    private var lower: some View {
        if let terminal = model.focusedTerminal {
            Well(radius: 12, padding: 8, color: Theme.deckWell) {
                DeckKeyboard(target: terminalTarget(terminal), modifiers: modifiers)
            }
        } else if let screen = model.screen, model.focus == .screen {
            screenDeck(screen)
        }
    }

    private func screenDeck(_ screen: ScreenSession) -> some View {
        let mode = lowerMode ?? (prefs.screenInput == .trackpad ? .trackpad : .keyboard)
        let target = screenTarget(screen)
        return VStack(spacing: 14) {
            Well(radius: 10, padding: 7, color: Theme.deckWell) {
                KeyStrip(keys: DeckLayout.strip(flat: false), target: target, modifiers: modifiers,
                         keyboardOn: mode == .keyboard, touchOn: false)
                    .frame(height: 38)
            }
            HStack(spacing: 6) {
                ModeKey(title: "trackpad", on: mode == .trackpad) { lowerMode = .trackpad }
                ModeKey(title: "direct touch", on: mode == .keyboard) { lowerMode = .keyboard }
                Button { model.closeScreen() } label: {
                    Text("disconnect").frame(maxWidth: .infinity, alignment: .trailing)
                }
                .buttonStyle(KeyButtonStyle(radius: 7, corner: .bottomTrailing))
                .frame(width: 96)
            }
            .frame(height: 34)
            if mode == .trackpad {
                Trackpad(session: screen)
            } else {
                Well(radius: 12, padding: 8, color: Theme.deckWell) {
                    DeckKeyboard(target: target, modifiers: modifiers, showFunctionRow: false)
                }
            }
        }
        .padding(.horizontal, 6)
    }

    // MARK: Flat (landscape) screen

    private func flatScreen(_ screen: ScreenSession, safeTop: CGFloat, height: CGFloat) -> some View {
        // Header, screen and strip each get their own band so nothing sits
        // on top of the Mac's screen (its Dock, menu bar, login field…).
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Text("\(screen.mac.shortHost) · \(Int(screen.fps)) fps · \(Int(screen.latencyMs)) ms")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.tertiary)
                Button { model.closeScreen() } label: { Text("disconnect") }
                    .buttonStyle(KeyButtonStyle(radius: 6, corner: .center))
                    .frame(width: 96, height: 28)
            }
            .padding(.top, max(6, safeTop))
            .padding(.bottom, 6)
            .padding(.horizontal, 24)
            ZStack {
                ScreenPane(session: screen, mode: flatTouch ? .direct : .relative, rounded: false)
                // Always first responder so a hardware keyboard works, but
                // never summons the iOS keyboard: typing on glass uses the
                // deck keyboard below.
                KeyCapture(session: screen, active: .constant(true), softwareKeyboard: false)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
            }
            .frame(maxHeight: .infinity)
            if flatKeyboard {
                // The deck keyboard docked under the screen, MacBook-style.
                VStack(spacing: 8) {
                    flatStrip(screen)
                        .frame(maxWidth: 600)
                    Well(radius: 12, padding: 8, color: Theme.deckWell) {
                        DeckKeyboard(target: flatTarget(screen), modifiers: modifiers, showFunctionRow: false)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .frame(height: height * 0.5)
                .background(Theme.background)
                .transition(.move(edge: .bottom))
            } else {
                flatStrip(screen)
                    .padding(7)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(hex: 0x28292C, alpha: 0.88))
                    )
                    .frame(maxWidth: 600)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
            }
        }
        .background(Theme.remoteBlack)
        .ignoresSafeArea()
        // Landscape reports no top inset, so the system status icons would
        // sit on the header's disconnect button. The Mac shows its own clock.
        .statusBarHidden(true)
        .animation(.snappy(duration: 0.22), value: flatKeyboard)
    }

    private func flatStrip(_ screen: ScreenSession) -> some View {
        KeyStrip(keys: DeckLayout.strip(flat: true), target: flatTarget(screen), modifiers: modifiers,
                 keyboardOn: flatKeyboard, touchOn: flatTouch)
            .frame(height: 38)
    }

    // MARK: Targets

    private func terminalTarget(_ session: TerminalSession) -> TerminalKeyTarget {
        session.keys
    }

    private func screenTarget(_ session: ScreenSession) -> ScreenKeyTarget {
        let t = session.keys
        t.onToggle = { kind in
            if case .toggleKeyboard = kind {
                let current = lowerMode ?? (prefs.screenInput == .trackpad ? .trackpad : .keyboard)
                lowerMode = current == .keyboard ? .trackpad : .keyboard
            }
        }
        return t
    }

    private func flatTarget(_ session: ScreenSession) -> ScreenKeyTarget {
        let t = session.keys
        t.onToggle = { kind in
            switch kind {
            case .toggleKeyboard: flatKeyboard.toggle()
            case .toggleTouch: flatTouch.toggle()
            default: break
            }
        }
        return t
    }
}

/// The hinge's shadow line between the halves.
struct Crease: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: .black.opacity(0.45), location: 0),
            .init(color: .white.opacity(0.05), location: 0.5),
            .init(color: .black.opacity(0.25), location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

struct ModeKey: View {
    var title: String
    var on: Bool
    var action: () -> Void

    var body: some View {
        Button {
            action()
            Haptics.tap()
        } label: {
            HStack(spacing: 8) {
                LED(on: on)
                Text(title)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(KeyButtonStyle(radius: 7, lit: on, corner: .center))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// One row of keys (the screen strip).
struct KeyStrip: View {
    let keys: [DeckKey]
    let target: KeyTarget
    let modifiers: ModifierState
    var keyboardOn: Bool
    var touchOn: Bool

    var body: some View {
        GeometryReader { geo in
            WeightedRow(spacing: 5) {
                ForEach(keys) { key in
                    KeyCap(key: key, height: geo.size.height, scale: 0.75, target: target,
                           modifiers: modifiers, radius: 5, lit: lit(key))
                        .overlay(alignment: .topLeading) {
                            if case .toggleTouch = key.kind {
                                LED(on: touchOn).padding(.top, 6).padding(.leading, 7)
                            }
                        }
                        .layoutValue(key: KeyWeight.self, value: key.width)
                }
            }
        }
    }

    private func lit(_ key: DeckKey) -> Bool {
        switch key.kind {
        case .toggleKeyboard: keyboardOn
        case .toggleTouch: touchOn
        default: false
        }
    }
}
