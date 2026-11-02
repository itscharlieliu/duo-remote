import SwiftUI

/// "studio — zsh  studio — htop  +   96×22" — the tab row above a session.
struct SessionTabs: View {
    @Environment(AppModel.self) private var model
    @Environment(MacStore.self) private var store
    var showsInfo = true

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.terminals) { terminal in
                        tab(title: terminal.title,
                            selected: model.focus == .terminal(terminal.id),
                            live: terminal.state == .connected) {
                            model.focus = .terminal(terminal.id)
                        } close: {
                            model.close(terminal: terminal)
                        }
                    }
                    if let screen = model.screen {
                        tab(title: "\(screen.mac.name.lowercased()) — screen",
                            selected: model.focus == .screen,
                            live: screen.state == .connected) {
                            model.focus = .screen
                        } close: {
                            model.closeScreen()
                        }
                    }
                    addMenu
                }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            if showsInfo {
                Text(info)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(height: 28)
    }

    private var info: String {
        if let terminal = model.focusedTerminal { return "\(terminal.cols)×\(terminal.rows)" }
        if let screen = model.screen, model.focus == .screen {
            return "\(screen.mac.shortHost) · \(Int(screen.fps)) fps · \(Int(screen.latencyMs)) ms"
        }
        return ""
    }

    private func tab(title: String, selected: Bool, live: Bool,
                     select: @escaping () -> Void, close: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Button(action: { select(); Haptics.tap() }) {
                HStack(spacing: 7) {
                    LED(on: selected && live)
                    Text(title).lineLimit(1)
                }
                .padding(.leading, 12)
                .padding(.trailing, selected ? 4 : 12)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The selected tab gets a visible close key; others close from
            // their context menu (long-press).
            if selected {
                Button {
                    Haptics.tap()
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(title)")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(selected ? Theme.text : Theme.secondary)
        .background(KeycapBackground(radius: 6, lit: selected))
        .contextMenu {
            Button(role: .destructive, action: close) { Label("Close", systemImage: "xmark") }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Close", close)
    }

    private var addMenu: some View {
        Menu {
            if let current = currentMac, current.hasSSH {
                Button { Task { await model.openTerminal(current) } } label: {
                    Label("New tab on \(current.name)", systemImage: "terminal")
                }
            }
            ForEach(store.macs) { mac in
                Menu(mac.name) {
                    if mac.hasSSH {
                        Button { Task { await model.openTerminal(mac) } } label: { Label("Terminal", systemImage: "terminal") }
                    }
                    Button { Task { await model.openScreen(mac) } } label: { Label("Screen", systemImage: "display") }
                }
            }
        } label: {
            Text("+")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
                .frame(width: 28, height: 28)
                .background(KeycapBackground(radius: 6))
        }
        .accessibilityLabel("New session")
    }

    private var currentMac: Mac? {
        model.focusedTerminal?.mac ?? model.screen?.mac
    }
}

/// A terminal with its connection state overlaid when not live.
struct TerminalPane: View {
    let session: TerminalSession
    var deckKeyboard: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        TerminalHost(session: session, deckKeyboard: deckKeyboard)
            .overlay {
                switch session.state {
                case .connecting:
                    StatusCard(title: "Connecting to \(session.mac.name)…", message: nil, busy: true)
                case .closed(let message?):
                    StatusCard(title: "Disconnected", message: message) {
                        Task { await model.reconnect(session) }
                    } close: {
                        model.close(terminal: session)
                    }
                case .closed(nil):
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Button("reconnect") { Task { await model.reconnect(session) } }
                                .buttonStyle(KeyButtonStyle(radius: 7, lit: true, corner: .center))
                            Button("close tab") { model.close(terminal: session) }
                                .buttonStyle(KeyButtonStyle(radius: 7, corner: .center))
                        }
                        .frame(width: 260, height: 36)
                        .padding(.bottom, 12)
                    }
                case .connected:
                    EmptyView()
                }
            }
    }
}

/// The remote screen with a connection overlay.
struct ScreenPane: View {
    let session: ScreenSession
    var mode: RemoteScreen.Mode
    var rounded = true
    @Environment(AppModel.self) private var model

    var body: some View {
        RemoteScreen(session: session, mode: mode)
            .clipShape(RoundedRectangle(cornerRadius: rounded ? 6 : 0, style: .continuous))
            .overlay {
                switch session.state {
                case .connecting:
                    StatusCard(title: "Sharing \(session.mac.name)’s screen…", message: nil, busy: true)
                case .closed(let message):
                    StatusCard(title: "Screen Sharing ended", message: message) {
                        let mac = session.mac
                        model.closeScreen()
                        Task { await model.openScreen(mac) }
                    } close: {
                        model.closeScreen()
                    }
                case .connected:
                    EmptyView()
                }
            }
    }
}

struct StatusCard: View {
    var title: String
    var message: String?
    var busy = false
    var retry: (() -> Void)?
    var close: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if busy { ProgressView().controlSize(.small) } else { LED(on: true, size: 6, color: Theme.danger) }
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            }
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if retry != nil || close != nil {
                HStack(spacing: 8) {
                    if let retry {
                        Button("retry", action: retry).buttonStyle(KeyButtonStyle(radius: 7, lit: true, corner: .center))
                    }
                    if let close {
                        Button("close", action: close).buttonStyle(KeyButtonStyle(radius: 7, corner: .center))
                    }
                }
                .frame(height: 36)
            }
        }
        .padding(16)
        .frame(maxWidth: 360, alignment: .leading)
        .background(Well(radius: 14) { Color.clear })
        .background(Theme.backgroundBottom.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
        .padding(20)
    }
}

/// Sessions on the outer display: system keyboard, direct touch.
struct FoldedSessionView: View {
    @Environment(AppModel.self) private var model
    @State private var typing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                EscKey { model.showSessionWhileFolded = false }
                SessionTabs(showsInfo: false)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if let terminal = model.focusedTerminal {
                TerminalPane(session: terminal, deckKeyboard: false)
            } else if let screen = model.screen, model.focus == .screen {
                ScreenPane(session: screen, mode: .direct, rounded: false)
                    .background(KeyCapture(session: screen, active: $typing).frame(width: 1, height: 1).opacity(0.01))
                KeyStrip(keys: DeckLayout.strip(flat: false), target: foldedTarget(screen),
                         modifiers: modifiers, keyboardOn: typing, touchOn: true)
                    .frame(height: 36)
                    .padding(7)
            } else {
                Spacer()
            }
        }
        .background(Theme.screenBlack.ignoresSafeArea())
        .onChange(of: model.hasSessions) { _, has in if !has { model.showSessionWhileFolded = false } }
    }

    @State private var modifiers = ModifierState()

    private func foldedTarget(_ screen: ScreenSession) -> ScreenKeyTarget {
        let t = screen.keys
        t.onToggle = { kind in if case .toggleKeyboard = kind { typing.toggle() } }
        return t
    }
}
