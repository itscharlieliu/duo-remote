import Foundation
import UIKit
import Observation
import Citadel
import NIOCore
import NIOSSH
import SwiftTerm

/// One terminal tab: an SSH PTY feeding a SwiftTerm view.
///
/// The `TerminalView` lives here, not in SwiftUI, so scrollback and state
/// survive the layout changing under it (folding, rotating, switching tabs).
@MainActor
@Observable
final class TerminalSession: Identifiable {
    enum State: Equatable {
        case connecting
        case connected
        case closed(String?)
    }

    let id = UUID()
    let mac: Mac
    private(set) var state: State = .connecting
    private(set) var title: String
    private(set) var cols = 80
    private(set) var rows = 24
    /// DECCKM. SwiftTerm doesn't expose it, so we watch the output stream for
    /// `ESC[?1h` / `ESC[?1l` so the deck's arrow keys match the hardware path.
    private(set) var applicationCursor = false

    @ObservationIgnored let terminalView: TerminalView
    /// Translates deck keys into bytes for this session.
    @ObservationIgnored private(set) lazy var keys = TerminalKeyTarget(session: self)
    @ObservationIgnored private var bridge: Bridge?
    @ObservationIgnored private var client: SSHClient?
    @ObservationIgnored private var writer: TTYStdinWriter?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var input: AsyncStream<[UInt8]>.Continuation?
    @ObservationIgnored private var escapeTail: [UInt8] = []
    /// Raw output observer (used by tests).
    @ObservationIgnored var outputTap: (([UInt8]) -> Void)?

    init(mac: Mac) {
        self.mac = mac
        self.title = "\(mac.name.lowercased()) — zsh"
        terminalView = TerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        configureView()
    }

    private func configureView() {
        let prefs = Preferences.shared
        terminalView.font = UIFont.monospacedSystemFont(ofSize: prefs.fontSize, weight: .regular)
        terminalView.optionAsMetaKey = prefs.optionAsMeta
        terminalView.nativeBackgroundColor = UIColor(red: 0x14 / 255, green: 0x14 / 255, blue: 0x16 / 255, alpha: 1)
        terminalView.nativeForegroundColor = UIColor(red: 0xD9 / 255, green: 0xDA / 255, blue: 0xDE / 255, alpha: 1)
        terminalView.backgroundColor = terminalView.nativeBackgroundColor
        let bridge = Bridge(session: self)
        self.bridge = bridge
        terminalView.terminalDelegate = bridge
    }

    func applyPreferences() {
        let prefs = Preferences.shared
        let font = UIFont.monospacedSystemFont(ofSize: prefs.fontSize, weight: .regular)
        if terminalView.font.pointSize != font.pointSize { terminalView.font = font }
        terminalView.optionAsMetaKey = prefs.optionAsMeta
    }

    /// When the deck keyboard is showing, the system keyboard must not be:
    /// an empty input view keeps the terminal first responder (so a hardware
    /// keyboard still works) without the on-screen keyboard.
    func setUsesDeckKeyboard(_ deck: Bool) {
        if deck {
            terminalView.inputView = UIView(frame: .zero)
            terminalView.inputAccessoryView = nil
        } else {
            terminalView.inputView = nil
            // SwiftTerm installs its own accessory bar (esc, ctrl, arrows)
            // when the accessory view is unset.
        }
        if terminalView.isFirstResponder {
            terminalView.reloadInputViews()
        }
    }

    func start(credential: SSHCredential) {
        task?.cancel()
        state = .connecting
        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
        input = continuation
        let mac = self.mac

        task = Task { [weak self] in
            do {
                let client = try await SSHConnector.connect(to: mac, credential: credential)
                guard let self else { return }
                self.client = client
                if mac.macAddress == nil {
                    Task {
                        if let address = await SSHConnector.fetchMACAddress(using: client) {
                            MacStore.shared.update(mac.id) { $0.macAddress = address }
                        }
                    }
                }
                let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: self.cols,
                    terminalRowHeight: self.rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: .init([:])
                )
                let env = [SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: "LANG", value: "en_US.UTF-8")]
                try await client.withPTY(request, environment: env) { inbound, outbound in
                    await MainActor.run {
                        self.writer = outbound
                        self.state = .connected
                    }
                    let pump = Task {
                        for await bytes in stream {
                            try? await outbound.write(ByteBuffer(bytes: bytes))
                        }
                    }
                    defer { pump.cancel() }
                    for try await chunk in inbound {
                        let buffer: ByteBuffer
                        switch chunk {
                        case .stdout(let b): buffer = b
                        case .stderr(let b): buffer = b
                        }
                        let bytes = Array(buffer.readableBytesView)
                        await MainActor.run { self.receive(bytes) }
                    }
                }
                await MainActor.run { self.finish(nil) }
            } catch is CancellationError {
                await MainActor.run { self?.finish(nil) }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { self?.finish(message) }
            }
        }
    }

    private func finish(_ error: String?) {
        writer = nil
        input?.finish()
        input = nil
        if let client {
            Task { try? await client.close() }
        }
        client = nil
        if case .closed = state { return }
        state = .closed(error)
        if error == nil {
            terminalView.feed(text: "\r\n\u{1B}[2m[session ended]\u{1B}[0m\r\n")
        }
    }

    private func receive(_ bytes: [UInt8]) {
        trackCursorMode(bytes)
        outputTap?(bytes)
        terminalView.feed(byteArray: bytes[...])
    }

    private func trackCursorMode(_ bytes: [UInt8]) {
        // Look for ESC [ ? 1 h / l, including across chunk boundaries.
        let scan = escapeTail + bytes
        let pattern: [UInt8] = [0x1B, 0x5B, 0x3F, 0x31]
        var i = 0
        while i + 4 < scan.count {
            if scan[i] == 0x1B, Array(scan[i..<(i + 4)]) == pattern {
                if scan[i + 4] == UInt8(ascii: "h") { applicationCursor = true }
                if scan[i + 4] == UInt8(ascii: "l") { applicationCursor = false }
            }
            i += 1
        }
        escapeTail = Array(scan.suffix(4))
    }

    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        input?.yield(bytes)
    }

    func send(_ text: String) { send(Array(text.utf8)) }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        guard let writer else { return }
        Task { try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0) }
    }

    func close() {
        task?.cancel()
        task = nil
        finish(nil)
    }

    fileprivate func updateTitle(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // zsh sets titles like "you@studio:~"; keep the design's "studio — zsh" shape.
        let program = trimmed.split(separator: ":").first.map(String.init) ?? trimmed
        let host = mac.name.lowercased()
        if program.contains("@") {
            title = "\(host) — zsh"
        } else {
            title = "\(host) — \(program.split(separator: " ").first.map(String.init) ?? program)"
        }
    }

    /// SwiftTerm's delegate. A separate object so the session needn't be NSObject.
    private final class Bridge: NSObject, TerminalViewDelegate {
        weak var session: TerminalSession?
        init(session: TerminalSession) { self.session = session }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated { session?.send(Array(data)) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { session?.resize(cols: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            MainActor.assumeIsolated { session?.updateTitle(title) }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            MainActor.assumeIsolated { UIApplication.shared.open(url) }
        }
        func bell(source: TerminalView) {
            MainActor.assumeIsolated { Haptics.warn() }
        }
        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                MainActor.assumeIsolated { UIPasteboard.general.string = text }
            }
        }
        func clipboardRead(source: TerminalView) -> Data? {
            MainActor.assumeIsolated { UIPasteboard.general.string.map { Data($0.utf8) } }
        }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    }
}
