import SwiftUI

/// The desktop half: the VNC surface plus a small toolbar.
///
/// Toolbar, in order: connection status, mouse-mode toggle, keyboard button
/// (summons the iOS keyboard for the Mac), modifier latches, and special keys.
/// Modifiers latch: tap Cmd once and it stays down for the next key, then
/// releases — the way remote-desktop apps on phones have to work, since
/// there is no physical key to hold.
struct DesktopPane: View {
    @ObservedObject var client: VNCClient

    @State private var trackpadMode = false
    @State private var keyboardVisible = false
    @State private var latchedModifiers: Set<UInt32> = []

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            DesktopViewRepresentable(
                client: client,
                trackpadMode: trackpadMode,
                keyboardVisible: $keyboardVisible,
                latchedModifiers: $latchedModifiers)
            toolbar
        }
    }

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if client.remoteSize != .zero {
                Text("\(Int(client.remoteSize.width))×\(Int(client.remoteSize.height))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
    }

    private var statusColor: Color {
        switch client.state {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .idle, .disconnected: return .gray
        }
    }

    private var statusText: String {
        switch client.state {
        case .idle: return "Desktop — not connected"
        case .connecting: return "Desktop — connecting…"
        case .connected: return "Desktop — connected"
        case .failed(let message): return "Desktop — \(message)"
        case .disconnected: return "Desktop — disconnected"
        }
    }

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button(trackpadMode ? "Direct touch" : "Trackpad") {
                    trackpadMode.toggle()
                }
                .buttonStyle(.bordered)
                .font(.caption)

                Button(keyboardVisible ? "Hide keyboard" : "Keyboard") {
                    keyboardVisible.toggle()
                }
                .buttonStyle(.bordered)
                .font(.caption)

                Divider()

                modifierButton("Ctrl", VNCKeys.controlLeft)
                modifierButton("Cmd", VNCKeys.superLeft)
                modifierButton("Opt", VNCKeys.altLeft)
                modifierButton("Shift", VNCKeys.shiftLeft)

                Divider()

                ForEach(["Esc", "Tab", "⌫", "⏎", "←", "→", "↑", "↓"], id: \.self) { label in
                    Button(label) {
                        if let keysym = VNCKeys.keysym(forLabel: label) {
                            client.tapKey(keysym)
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color(.secondarySystemBackground))
    }

    private func modifierButton(_ label: String, _ keysym: UInt32) -> some View {
        let active = latchedModifiers.contains(keysym)
        return Button(label) {
            if active {
                client.sendKey(down: false, keysym: keysym)
                latchedModifiers.remove(keysym)
            } else {
                client.sendKey(down: true, keysym: keysym)
                latchedModifiers.insert(keysym)
            }
        }
        .buttonStyle(.bordered)
        .font(.caption)
        .tint(active ? .blue : nil)
    }
}

/// Bridges DesktopInputView into SwiftUI and wires it to the VNC client.
/// Modifier latching lives here: when a non-modifier key is typed while
/// modifiers are latched, the modifiers are released right after it.
private struct DesktopViewRepresentable: UIViewRepresentable {
    let client: VNCClient
    let trackpadMode: Bool
    @Binding var keyboardVisible: Bool
    @Binding var latchedModifiers: Set<UInt32>

    func makeUIView(context: Context) -> DesktopInputView {
        let view = DesktopInputView()
        view.onPointer = { [weak client] x, y, buttons in
            client?.sendPointer(x: x, y: y, buttons: buttons)
        }
        let modifiersBinding = $latchedModifiers
        view.onKey = { [weak client] down, keysym in
            client?.sendKey(down: down, keysym: keysym)
            if !down, !Self.isModifier(keysym) {
                // Release latched modifiers after the next real key.
                DispatchQueue.main.async {
                    let latched = modifiersBinding.wrappedValue
                    for modifier in latched {
                        client?.sendKey(down: false, keysym: modifier)
                    }
                    modifiersBinding.wrappedValue.removeAll()
                }
            }
        }
        view.onTapToFocus = {}
        return view
    }

    func updateUIView(_ uiView: DesktopInputView, context: Context) {
        uiView.trackpadMode = trackpadMode
        uiView.setImage(client.image, remoteSize: client.remoteSize)
        if keyboardVisible {
            uiView.becomeFirstResponder()
        } else {
            uiView.resignFirstResponder()
        }
    }

    private static func isModifier(_ keysym: UInt32) -> Bool {
        [VNCKeys.shiftLeft, VNCKeys.controlLeft, VNCKeys.altLeft, VNCKeys.superLeft].contains(keysym)
    }
}
