import XCTest
import CryptoKit
import NIOSSH
import NIOCore
import Citadel
@testable import HomeRow

/// Runs only when pointed at a real sshd (skipped otherwise):
///   TEST_RUNNER_HOMEROW_SSH_HOST, _PORT, _USER, _AUTHKEYS (writable
///   authorized_keys path the server reads), _HOSTKEY_FP (expected
///   fingerprint from `ssh-keygen -lf`).
final class SSHIntegrationTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    @MainActor
    func testProbePinConnectPTYAndResize() async throws {
        guard let host = env["HOMEROW_SSH_HOST"], let port = env["HOMEROW_SSH_PORT"].flatMap(Int.init),
              let user = env["HOMEROW_SSH_USER"], let authKeys = env["HOMEROW_SSH_AUTHKEYS"],
              let expectedFP = env["HOMEROW_SSH_HOSTKEY_FP"] else {
            throw XCTSkip("No test sshd configured")
        }

        // 1. Probe: the fingerprint we'd show on the Pair screen.
        let hostKey = try await SSHConnector.probeHostKey(host: host, port: port)
        XCTAssertEqual(HostKeyTrust.fingerprint(ofOpenSSHKey: hostKey), expectedFP)

        // 2. Key sign-in with a fresh ED25519 key the server trusts.
        let key = Curve25519.Signing.PrivateKey()
        let line = String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey) + " home-row-test"
        try (line + "\n").write(toFile: authKeys, atomically: true, encoding: .utf8)

        var mac = Mac(name: "Test", host: host, user: user)
        mac.sshPort = port
        mac.hostKey = hostKey
        let client = try await SSHConnector.connect(to: mac, credential: .key(key))

        // 3. installPublicKey is idempotent.
        let second = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExample0 other"
        try await SSHConnector.installPublicKey(second, using: client)
        try await SSHConnector.installPublicKey(second, using: client)
        let contents = try String(contentsOfFile: authKeys, encoding: .utf8)
        XCTAssertEqual(contents.components(separatedBy: second).count - 1, 1)
        XCTAssertTrue(contents.contains(line))
        try? await client.close()

        // 4. A pinned-key mismatch is refused with hostKeyChanged.
        var wrong = mac
        wrong.hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILRMbVi2lxMcLzIGTzyemea9c/1i0/LDf1YzYzbxbr7B"
        do {
            _ = try await SSHConnector.connect(to: wrong, credential: .key(key))
            XCTFail("connected despite a different host key")
        } catch SSHFailure.hostKeyChanged {
        } catch {
            XCTFail("expected hostKeyChanged, got \(error)")
        }

        // 5. A wrong key is reported as an auth failure (drives the
        //    "install this phone's key" prompt).
        do {
            _ = try await SSHConnector.connect(to: mac, credential: .key(Curve25519.Signing.PrivateKey()))
            XCTFail("connected with an unknown key")
        } catch SSHFailure.authFailed {
        } catch {
            XCTFail("expected authFailed, got \(error)")
        }

        // 6. A real terminal session: PTY, output, live resize.
        let session = TerminalSession(mac: mac)
        var transcript = ""
        session.outputTap = { transcript += String(decoding: $0, as: UTF8.self) }
        session.start(credential: .key(key))
        try await waitUntil { session.state == .connected }
        session.resize(cols: 97, rows: 31)
        try await Task.sleep(for: .milliseconds(300))
        session.send("stty size; echo HOMEROW_$((6*7))\r")
        try await waitUntil(timeout: 8) {
            transcript.contains("31 97") && transcript.contains("HOMEROW_42")
        }
        session.close()
    }

    @MainActor
    private func waitUntil(timeout: Double = 10, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

