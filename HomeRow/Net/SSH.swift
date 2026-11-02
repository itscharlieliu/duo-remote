import Foundation
import CryptoKit
import Citadel
import NIOCore
import NIOSSH

// MARK: - Host key trust (TOFU pinning)

enum HostKeyTrust {
    /// "SHA256:…" in the same format as `ssh-keygen -lf`, so it can be
    /// compared character-for-character with what the Mac prints.
    static func fingerprint(ofOpenSSHKey line: String) -> String? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        let digest = SHA256.hash(data: blob)
        let b64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:" + b64
    }

    /// "ED25519", "ECDSA", "RSA" — the label above the fingerprint.
    static func algorithmLabel(ofOpenSSHKey line: String) -> String {
        let type = line.split(separator: " ").first.map(String.init) ?? ""
        switch type {
        case "ssh-ed25519": return "ED25519"
        case let t where t.hasPrefix("ecdsa"): return "ECDSA"
        case "ssh-rsa": return "RSA"
        default: return type.uppercased()
        }
    }

    /// The command that prints the matching fingerprint on the Mac.
    static func verifyCommand(forOpenSSHKey line: String) -> String {
        let file: String
        switch algorithmLabel(ofOpenSSHKey: line) {
        case "ED25519": file = "ssh_host_ed25519_key.pub"
        case "ECDSA": file = "ssh_host_ecdsa_key.pub"
        default: file = "ssh_host_rsa_key.pub"
        }
        return "ssh-keygen -lf /etc/ssh/\(file)"
    }

    static func canonical(_ key: NIOSSHPublicKey) -> String {
        String(openSSHPublicKey: key)
    }

    static func sameKey(_ a: String, _ b: String) -> Bool {
        a.split(separator: " ").prefix(2) == b.split(separator: " ").prefix(2)
    }
}

enum SSHFailure: LocalizedError {
    case hostKeyChanged(expected: String, presented: String)
    case authFailed
    case noRemoteLogin(String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .hostKeyChanged:
            "This Mac’s host key has changed since you paired it. That happens after reinstalling macOS — or when something is impersonating the Mac. Home Row refused to connect. If you expected this, forget the key on the Hosts screen and pair again."
        case .authFailed:
            "The Mac didn’t accept the sign-in."
        case .noRemoteLogin(let name):
            "\(name) isn’t accepting SSH. Turn on System Settings → General → Sharing → Remote Login."
        case .other(let message):
            message
        }
    }
}

/// Records whatever host key the server presents. Thread-safe: NIO calls the
/// validator on its event loop.
final class HostKeyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _key: String?
    var key: String? { lock.withLock { _key } }
    func record(_ key: String) { lock.withLock { _key = key } }
}

/// Validator: with `expected == nil` it records the key and refuses (used to
/// fetch the fingerprint for the Pair screen); otherwise it accepts only the
/// pinned key.
struct PinnedHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    let expected: String?
    let recorder: HostKeyRecorder

    struct ProbeOnly: Error {}
    struct Mismatch: Error {}

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = HostKeyTrust.canonical(hostKey)
        recorder.record(presented)
        guard let expected else {
            validationCompletePromise.fail(ProbeOnly())
            return
        }
        if HostKeyTrust.sameKey(presented, expected) {
            validationCompletePromise.succeed(())
        } else {
            validationCompletePromise.fail(Mismatch())
        }
    }
}

// MARK: - Credentials & connecting

enum SSHCredential {
    case key(Curve25519.Signing.PrivateKey)
    case password(String)
}

enum SSHConnector {
    /// Fetches the host key the Mac presents, without authenticating.
    static func probeHostKey(host: String, port: Int, fallback: String? = nil) async throws -> String {
        let address = try await LANGuard.resolve(host, port: port, fallback: fallback)
        let recorder = HostKeyRecorder()
        do {
            let client = try await SSHClient.connect(to: SSHClientSettings(
                host: address,
                port: port,
                authenticationMethod: { .passwordBased(username: "probe", password: "") },
                hostKeyValidator: .custom(PinnedHostKeyValidator(expected: nil, recorder: recorder))
            ))
            try? await client.close()
        } catch {
            if let key = recorder.key { return key }
            throw mapConnectError(error, name: host)
        }
        if let key = recorder.key { return key }
        throw SSHFailure.other("The Mac didn’t present a host key.")
    }

    static func connect(to mac: Mac, credential: SSHCredential) async throws -> SSHClient {
        guard let pinned = mac.hostKey else {
            throw SSHFailure.other("\(mac.name) hasn’t been paired yet.")
        }
        let address = try await LANGuard.resolve(mac.host, port: mac.sshPort, fallback: mac.lastAddress)
        let recorder = HostKeyRecorder()
        let user = mac.user
        let auth: @Sendable () -> SSHAuthenticationMethod
        switch credential {
        case .key(let key):
            auth = { .ed25519(username: user, privateKey: key) }
        case .password(let password):
            auth = { .passwordBased(username: user, password: password) }
        }
        do {
            let client = try await SSHClient.connect(to: SSHClientSettings(
                host: address,
                port: mac.sshPort,
                authenticationMethod: auth,
                hostKeyValidator: .custom(PinnedHostKeyValidator(expected: pinned, recorder: recorder))
            ))
            await MainActor.run {
                MacStore.shared.update(mac.id) {
                    $0.lastAddress = address
                    $0.lastConnected = .now
                }
            }
            return client
        } catch {
            if let presented = recorder.key, !HostKeyTrust.sameKey(presented, pinned) {
                throw SSHFailure.hostKeyChanged(expected: pinned, presented: presented)
            }
            throw mapConnectError(error, name: mac.name)
        }
    }

    static func mapConnectError(_ error: Error, name: String) -> Error {
        if error is LANGuard.Failure || error is SSHFailure { return error }
        if let e = error as? SSHClientError, case .allAuthenticationOptionsFailed = e {
            return SSHFailure.authFailed
        }
        if error is AuthenticationFailed { return SSHFailure.authFailed }
        if let e = error as? CitadelError, case .unauthorized = e { return SSHFailure.authFailed }
        let text = String(describing: error)
        if text.contains("connectionRefused") || text.contains("Connection refused") {
            return SSHFailure.noRemoteLogin(name)
        }
        if text.contains("connectTimeout") || text.contains("timeout") {
            return SSHFailure.other("Timed out reaching \(name). Is it awake and on this Wi-Fi?")
        }
        if text.lowercased().contains("auth") { return SSHFailure.authFailed }
        return SSHFailure.other("SSH failed: \(error.localizedDescription)")
    }

    /// Appends the phone's public key to ~/.ssh/authorized_keys on the Mac.
    /// Idempotent: does nothing if the key is already there.
    static func installPublicKey(_ line: String, using client: SSHClient) async throws {
        let quoted = "'" + line.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = """
        umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && \
        (grep -qxF \(quoted) ~/.ssh/authorized_keys || printf '%s\\n' \(quoted) >> ~/.ssh/authorized_keys)
        """
        _ = try await client.executeCommand(command)
    }

    /// Learns the Mac's Wi-Fi/Ethernet hardware address for Wake-on-LAN.
    static func fetchMACAddress(using client: SSHClient) async -> String? {
        let command = "route -n get default 2>/dev/null | awk '/interface:/{print $2}' | xargs -I{} ifconfig {} | awk '/ether/{print $2; exit}'"
        guard var buffer = try? await client.executeCommand(command),
              let text = buffer.readString(length: buffer.readableBytes) else { return nil }
        let mac = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return mac.split(separator: ":").count == 6 ? mac : nil
    }
}

// MARK: - Credential resolution

/// Gathers the right credential for a Mac, prompting when needed.
@MainActor
enum CredentialBroker {
    static func sshCredential(for mac: Mac, prompt: PasswordPrompter) async throws -> SSHCredential {
        switch mac.auth {
        case .key:
            let key = try await Task.detached {
                try SSHIdentity.load(reason: "Sign in to \(mac.name)")
            }.value
            return .key(key)
        case .password:
            if let saved = Keychain.password(for: mac.id) { return .password(saved) }
            guard let entered = await prompt.ask(.init(
                title: "Password for \(mac.user)@\(mac.name)",
                message: "Your macOS account password.",
                offerRemember: true, macID: mac.id)) else {
                throw CancellationError()
            }
            return .password(entered)
        }
    }

    static func screenPassword(for mac: Mac, prompt: PasswordPrompter) async -> String? {
        if let saved = Keychain.password(for: mac.id) { return saved }
        return await prompt.ask(.init(
            title: "Screen Sharing on \(mac.name)",
            message: "Sign in as \(mac.user) with your macOS account password.",
            offerRemember: true, macID: mac.id))
    }
}

/// A one-shot password sheet, presented by the root view.
@MainActor
@Observable
final class PasswordPrompter {
    struct Request: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        var offerRemember: Bool
        var macID: UUID?
    }

    var current: Request?
    private var continuation: CheckedContinuation<String?, Never>?

    func ask(_ request: Request) async -> String? {
        continuation?.resume(returning: nil)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.current = request
        }
    }

    func finish(_ password: String?, remember: Bool) {
        if let password, remember, let id = current?.macID {
            Keychain.setPassword(password, for: id)
        }
        current = nil
        continuation?.resume(returning: password)
        continuation = nil
    }
}
