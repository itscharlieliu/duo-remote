import SwiftUI

/// The terminal half: the SwiftTerm view plus a key row for keys a phone
/// keyboard doesn't have. The row is always visible (not a keyboard
/// accessory) so it works in both folded and unfolded layouts, and so
/// Ctrl-C / Esc / arrows are one tap even when the keyboard is hidden.
struct TerminalPane: View {
    @ObservedObject var session: SSHSession

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            TerminalViewWrapper(session: session)
                .background(Color.black)
            keyRow
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
            Button("Clear") {
                // SwiftTerm has no public clear API on the wrapper path;
                // sending a form-feed / reset sequence is the portable way.
                session.send(text: "\u{0C}")
            }
            .font(.caption)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
    }

    private var statusColor: Color {
        switch session.state {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .idle, .disconnected: return .gray
        }
    }

    private var statusText: String {
        switch session.state {
        case .idle: return "Terminal — not connected"
        case .connecting: return "Terminal — connecting…"
        case .connected: return "Terminal — connected"
        case .failed(let message): return "Terminal — \(message)"
        case .disconnected: return "Terminal — disconnected"
        }
    }

    private var keyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                keyButton("Esc") { session.send(bytes: [0x1B]) }
                keyButton("Tab") { session.send(bytes: [0x09]) }
                keyButton("Ctrl-C") { session.send(bytes: [0x03]) }
                keyButton("Ctrl-D") { session.send(bytes: [0x04]) }
                keyButton("Ctrl-L") { session.send(bytes: [0x0C]) }
                keyButton("Ctrl-Z") { session.send(bytes: [0x1A]) }
                keyButton("←") { session.send(text: "\u{1B}[D") }
                keyButton("→") { session.send(text: "\u{1B}[C") }
                keyButton("↑") { session.send(text: "\u{1B}[A") }
                keyButton("↓") { session.send(text: "\u{1B}[B") }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color(.secondarySystemBackground))
    }

    private func keyButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .font(.system(.subheadline, design: .monospaced))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
