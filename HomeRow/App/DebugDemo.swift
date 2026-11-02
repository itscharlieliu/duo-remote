#if DEBUG
import Foundation
import CryptoKit
import Citadel

/// Debug-only: opens real sessions against local test servers at launch so
/// the open-phone layouts can be checked in the simulator without tapping.
///   HOMEROW_DEMO_SSH = host:port:user:/path/to/openssh_ed25519_private_key
///   HOMEROW_DEMO_RFB = host:port:user:password
///   HOMEROW_DEMO_FOCUS = terminal | screen
@MainActor
enum DebugDemo {
    static func run(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        Task {
            if let spec = env["HOMEROW_DEMO_SSH"]?.split(separator: ":").map(String.init), spec.count == 4,
               let port = Int(spec[1]),
               let file = try? String(contentsOfFile: spec[3], encoding: .utf8),
               let key = try? Curve25519.Signing.PrivateKey(sshEd25519: file) {
                var mac = Mac(name: "Studio", host: spec[0], user: spec[2])
                mac.sshPort = port
                mac.hostKey = try? await SSHConnector.probeHostKey(host: spec[0], port: port)
                let session = TerminalSession(mac: mac)
                model.terminals.append(session)
                model.focus = .terminal(session.id)
                session.start(credential: .key(key))
                try? await Task.sleep(for: .seconds(1.5))
                session.send("clear; echo 'Last login: Sun Nov  1 08:12:04 on ttys002'; ls -la ~ | head -12\r")
            }
            if let spec = env["HOMEROW_DEMO_RFB"]?.split(separator: ":").map(String.init), spec.count == 4,
               let port = Int(spec[1]) {
                var mac = Mac(name: "Studio", host: spec[0], user: spec[2])
                mac.screenPort = port
                let screen = ScreenSession(mac: mac)
                model.screen = screen
                screen.start(password: spec[3])
                if env["HOMEROW_DEMO_FOCUS"] == "screen" || model.terminals.isEmpty { model.focus = .screen }
                model.showSessionWhileFolded = true
            }
        }
    }
}
#endif
