import SwiftUI
import SwiftTerm

/// SwiftTerm's UIKit terminal view, bridged into SwiftUI.
///
/// Data flow:
/// - Remote bytes arrive via `SSHSession.onOutput` and are fed to the view.
/// - Keystrokes leave via `TerminalViewDelegate.send(source:data:)` and go
///   back into the SSH session.
/// - Resizes report through `sizeChanged`, which updates the session's
///   stored size (used on the next connect; live PTY resize is a known
///   v1 limitation — see README).
struct TerminalViewWrapper: UIViewRepresentable {
    let session: SSHSession

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.backgroundColor = .black
        session.onOutput = { [weak view] bytes in
            // Feed in chunks so a large burst (e.g. `ls` of a big dir)
            // doesn't block the main thread in one call.
            for chunk in bytes.chunked(into: 1024) {
                view?.feed(byteArray: chunk)
            }
        }
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: SSHSession

        init(session: SSHSession) {
            self.session = session
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            session.send(Array(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            session.cols = newCols
            session.rows = newRows
        }

        func scrolled(source: TerminalView, position: Double) {}

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdated(source: TerminalView) {}
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}
