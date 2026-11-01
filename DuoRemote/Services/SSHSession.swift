import Foundation
import Citadel
import NIOCore

/// Interactive SSH shell, backed by Citadel (pure-Swift NIO SSH).
///
/// Security notes, stated plainly rather than buried:
/// - LAN-only: the caller must already have passed `LANValidation`.
/// - Passwords come from the Keychain via the caller; they are never logged.
/// - Host-key validation in this v1 is `.acceptAnything()`, which is only
///   acceptable because the app refuses non-LAN hosts. Do not remove the LAN
///   check without adding trust-on-first-use host-key pinning first.
///   (That is the first hardening item in README.md.)
@MainActor
final class SSHSession: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
        case disconnected
    }

    @Published private(set) var state: State = .idle

    /// Raw PTY bytes from the remote shell, delivered on the main actor.
    var onOutput: (([UInt8]) -> Void)?

    var cols: Int = 80
    var rows: Int = 24

    private var client: SSHClient?
    private var sessionTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<Data>.Continuation?

    func connect(profile: HostProfile, password: String) {
        disconnect()
        state = .connecting

        let (inputStream, inputContinuation) = AsyncStream<Data>.makeStream()
        self.inputContinuation = inputContinuation

        sessionTask = Task {
            do {
                let settings = SSHClientSettings(
                    host: profile.host,
                    port: profile.sshPort,
                    authenticationMethod: {
                        .passwordBased(username: profile.sshUsername, password: password)
                    },
                    // LAN-only v1 tradeoff — see the header comment.
                    hostKeyValidator: .acceptAnything()
                )
                let client = try await SSHClient.connect(to: settings)
                self.client = client

                try await client.withPTY(
                    SSHChannelRequestEvent.PseudoTerminalRequest(
                        wantReply: true,
                        term: "xterm-256color",
                        terminalCharacterWidth: cols,
                        terminalRowHeight: rows,
                        terminalPixelWidth: 0,
                        terminalPixelHeight: 0,
                        terminalModes: .init([.ECHO: 1])
                    )
                ) { ttyOutput, ttyStdinWriter in
                    // The PTY is up: this is the honest "connected" moment.
                    await MainActor.run { self.state = .connected }
                    // Keystrokes from the UI -> remote shell.
                    Task {
                        for await data in inputStream {
                            try? await ttyStdinWriter.write(ByteBuffer(bytes: data))
                        }
                    }
                    // Remote shell -> terminal view, in order.
                    for try await buffer in ttyOutput {
                        var mutable = buffer
                        if let bytes = mutable.readBytes(length: mutable.readableBytes),
                           !bytes.isEmpty {
                            await MainActor.run { self.onOutput?(bytes) }
                        }
                    }
                }
                // withPTY returned: the remote shell exited.
                await MainActor.run {
                    if self.state == .connected { self.state = .disconnected }
                }
            } catch {
                await MainActor.run {
                    if !Task.isCancelled {
                        self.state = .failed(Self.friendlyError(error))
                    }
                }
            }
        }

    }

    /// Bytes typed in the terminal (including control keys and pastes).
    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        inputContinuation?.yield(Data(bytes))
    }

    func send(text: String) {
        send(Array(text.utf8))
    }

    func disconnect() {
        inputContinuation?.finish()
        inputContinuation = nil
        sessionTask?.cancel()
        sessionTask = nil
        let client = self.client
        self.client = nil
        Task {
            try? await client?.close()
        }
        if state == .connecting || state == .connected {
            state = .disconnected
        }
    }

    private static func friendlyError(_ error: Error) -> String {
        let message = error.localizedDescription
        if message.isEmpty { return "SSH connection failed." }
        return message
    }
}
