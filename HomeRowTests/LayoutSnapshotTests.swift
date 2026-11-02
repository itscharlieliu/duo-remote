import XCTest
import SwiftUI
import CryptoKit
import Citadel
@testable import HomeRow

/// Renders the open-phone layouts at the iPhone Duo inner display size
/// (669×951 pt) with live sessions, writing PNGs to
/// TEST_RUNNER_HOMEROW_SNAPSHOT_DIR. Needs the same local servers as the
/// integration tests plus TEST_RUNNER_HOMEROW_SSH_CLIENT_KEY.
final class LayoutSnapshotTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    @MainActor
    func testRenderOpenLayouts() async throws {
        guard let dir = env["HOMEROW_SNAPSHOT_DIR"], let keyPath = env["HOMEROW_SSH_CLIENT_KEY"],
              let sshPort = env["HOMEROW_SSH_PORT"].flatMap(Int.init),
              let rfbPort = env["HOMEROW_RFB_PORT"].flatMap(Int.init) else {
            throw XCTSkip("snapshot env not configured")
        }
        let key = try Curve25519.Signing.PrivateKey(sshEd25519: String(contentsOfFile: keyPath, encoding: .utf8))
        let model = AppModel()

        var mac = Mac(name: "Studio", host: "127.0.0.1", user: env["HOMEROW_SSH_USER"] ?? "you")
        mac.sshPort = sshPort
        mac.screenPort = rfbPort
        mac.hostKey = try await SSHConnector.probeHostKey(host: "127.0.0.1", port: sshPort)

        let terminal = TerminalSession(mac: mac)
        let second = TerminalSession(mac: mac)
        model.terminals = [terminal, second]
        model.focus = .terminal(terminal.id)
        terminal.start(credential: .key(key))
        second.start(credential: .key(key))

        var screenMac = mac
        screenMac.user = "tester"
        let realScreen = ScreenSession(mac: screenMac)
        model.screen = realScreen
        realScreen.start(password: "s3cret")

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 669, height: 951)
        window.windowLevel = .alert + 1
        var current: UIView?
        func host(_ posture: Posture, size: CGSize, flatKeyboard: Bool = false) -> UIHostingController<AnyView> {
            let root = AnyView(
                ZStack {
                    Theme.background.ignoresSafeArea()
                    OpenWorkspace(posture: posture, flatKeyboard: flatKeyboard)
                }
                .environment(model)
                .environment(MacStore.shared)
                .environment(Discovery.shared)
                .environment(Preferences.shared)
                .environment(\.posture, posture)
                .preferredColorScheme(.dark))
            let controller = UIHostingController(rootView: root)
            let container = UIViewController()
            window.rootViewController = container
            window.makeKeyAndVisible()
            container.addChild(controller)
            controller.view.frame = CGRect(origin: .zero, size: size)
            container.view.addSubview(controller.view)
            controller.didMove(toParent: container)
            current = controller.view
            return controller
        }

        _ = host(.deck, size: CGSize(width: 669, height: 951))
        try await waitFor { terminal.state == .connected && realScreen.state == .connected }
        terminal.send("clear; printf 'Last login: Sun Nov  1 08:12:04 on ttys002\\n'; echo 'you@studio ~ % brew upgrade'; echo '==> Upgrading 3 outdated packages:'; echo 'node 22.9.0 -> 22.11.0'\r")
        try await Task.sleep(for: .seconds(1.5))
        try save(current!, to: dir, name: "05-terminal-deck")

        model.focus = .screen
        try await Task.sleep(for: .seconds(1))
        try save(current!, to: dir, name: "06-screen-trackpad")

        _ = host(.flat, size: CGSize(width: 951, height: 669))
        try await Task.sleep(for: .seconds(1))
        try save(current!, to: dir, name: "07-screen-flat")

        _ = host(.flat, size: CGSize(width: 951, height: 669), flatKeyboard: true)
        try await Task.sleep(for: .seconds(1))
        try save(current!, to: dir, name: "08-screen-flat-keyboard")

        terminal.close(); second.close(); realScreen.close()
    }

    @MainActor
    private func save(_ view: UIView, to dir: String, name: String) throws {
        view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        try image.pngData()!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    @MainActor
    private func waitFor(timeout: Double = 10, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
