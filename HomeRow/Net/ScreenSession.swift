import Foundation
import UIKit
import Observation
import Citadel
import NIOCore
import NIOSSH

/// A live Screen Sharing session, plus the pointer state the input views
/// drive. Owned by `Sessions`; survives layout changes.
@MainActor
@Observable
final class ScreenSession: Identifiable {
    enum State: Equatable {
        case connecting
        case connected
        case closed(String?)
    }

    let id = UUID()
    let mac: Mac
    private(set) var state: State = .connecting
    private(set) var frame: CGImage?
    private(set) var cursorImage: CGImage?
    private(set) var cursorHotspot: CGPoint = .zero
    private(set) var screenSize = CGSize(width: 1, height: 1)
    private(set) var fps: Double = 0
    private(set) var latencyMs: Double = 0
    /// Remote pointer position, in remote pixels.
    var pointer = CGPoint(x: 400, y: 300)
    private(set) var buttons: UInt8 = 0

    @ObservationIgnored private var client: RFBClient?
    /// Translates deck keys into key events for this session.
    @ObservationIgnored private(set) lazy var keys = ScreenKeyTarget(session: self)
    @ObservationIgnored private var caffeinate: Task<Void, Never>?
    @ObservationIgnored private var lastClipboard: String?

    init(mac: Mac) {
        self.mac = mac
    }

    func start(password: String) {
        state = .connecting
        let mac = self.mac
        Task { [weak self] in
            do {
                let address = try await LANGuard.resolve(mac.host, port: mac.screenPort)
                guard let self else { return }
                let client = RFBClient(
                    host: address, port: mac.screenPort,
                    credentials: .init(username: mac.user, password: password),
                    quality: Preferences.shared.quality
                ) { [weak self] event in self?.handle(event) }
                self.client = client
                client.start()
            } catch {
                self?.state = .closed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func handle(_ event: RFBEvent) {
        switch event {
        case .connected(_, let w, let h):
            state = .connected
            screenSize = CGSize(width: w, height: h)
            pointer = CGPoint(x: w / 2, y: h / 2)
            MacStore.shared.update(mac.id) { $0.lastConnected = .now }
            startCaffeinateIfWanted()
        case .frame(let image):
            frame = image
        case .cursor(let image, let hotspot):
            cursorImage = image
            cursorHotspot = hotspot
        case .resized(let w, let h):
            screenSize = CGSize(width: w, height: h)
        case .stats(let fps, let latency):
            self.fps = fps
            self.latencyMs = latency
        case .clipboard(let text):
            lastClipboard = text
            UIPasteboard.general.string = text
        case .bell:
            Haptics.warn()
        case .failed(let error):
            stopCaffeinate()
            state = .closed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        case .closed:
            stopCaffeinate()
            if state != .closed(nil) { state = .closed(nil) }
        }
    }

    func close() {
        client?.stop()
        client = nil
        stopCaffeinate()
        state = .closed(nil)
    }

    // MARK: Pointer

    func movePointer(to point: CGPoint) {
        pointer = clamp(point)
        client?.pointer(x: Int(pointer.x), y: Int(pointer.y), buttons: buttons)
    }

    func movePointer(by delta: CGPoint) {
        movePointer(to: CGPoint(x: pointer.x + delta.x, y: pointer.y + delta.y))
    }

    func setButton(_ mask: UInt8, down: Bool) {
        buttons = down ? buttons | mask : buttons & ~mask
        client?.pointer(x: Int(pointer.x), y: Int(pointer.y), buttons: buttons)
    }

    func click(_ mask: UInt8 = 1, count: Int = 1) {
        for _ in 0..<count {
            setButton(mask, down: true)
            setButton(mask, down: false)
        }
    }

    /// Scroll by "lines". Positive dy scrolls content up (natural scrolling).
    func scroll(dx: Int, dy: Int) {
        func tick(_ mask: UInt8, times: Int) {
            for _ in 0..<min(times, 12) {
                client?.pointer(x: Int(pointer.x), y: Int(pointer.y), buttons: buttons | mask)
                client?.pointer(x: Int(pointer.x), y: Int(pointer.y), buttons: buttons)
            }
        }
        if dy > 0 { tick(8, times: dy) }       // button 4: up
        if dy < 0 { tick(16, times: -dy) }     // button 5: down
        if dx > 0 { tick(32, times: dx) }      // button 6: left
        if dx < 0 { tick(64, times: -dx) }     // button 7: right
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), screenSize.width - 1), y: min(max(0, p.y), screenSize.height - 1))
    }

    // MARK: Keys

    func key(_ keysym: UInt32, down: Bool) {
        client?.key(keysym, down: down)
    }

    /// Press a key with modifiers held, then release everything.
    func press(_ keysym: UInt32, modifiers: [UInt32] = []) {
        for m in modifiers { key(m, down: true) }
        key(keysym, down: true)
        key(keysym, down: false)
        for m in modifiers.reversed() { key(m, down: false) }
    }

    func type(_ text: String) {
        for c in text {
            guard let sym = Keysym.character(c) else { continue }
            let needsShift = c.isUppercase || "~!@#$%^&*()_+{}|:\"<>?".contains(c)
            press(sym, modifiers: needsShift ? [Keysym.shift] : [])
        }
    }

    /// Sends the phone's clipboard to the Mac, then ⌘V.
    func pasteFromPhone() {
        guard let text = UIPasteboard.general.string, text != lastClipboard else {
            press(UInt32(Character("v").asciiValue!), modifiers: [Keysym.command])
            return
        }
        client?.clipboard(text)
        lastClipboard = text
        press(UInt32(Character("v").asciiValue!), modifiers: [Keysym.command])
    }

    // MARK: Keep Mac awake

    /// Runs `caffeinate` over SSH for the length of the session. Closing the
    /// channel hangs up the PTY, which ends caffeinate.
    private func startCaffeinateIfWanted() {
        guard Preferences.shared.keepMacAwake, mac.hasSSH, mac.hostKey != nil else { return }
        let mac = self.mac
        caffeinate = Task {
            let credential: SSHCredential
            if mac.auth == .password, let saved = Keychain.password(for: mac.id) {
                credential = .password(saved)
            } else if mac.auth == .key, let key = try? await Task.detached(operation: {
                try SSHIdentity.load(reason: "Keep \(mac.name) awake while you share its screen")
            }).value {
                credential = .key(key)
            } else {
                return
            }
            guard let client = try? await SSHConnector.connect(to: mac, credential: credential) else { return }
            let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true, term: "dumb", terminalCharacterWidth: 80, terminalRowHeight: 24,
                terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:]))
            try? await client.withPTY(request) { inbound, outbound in
                try await outbound.write(ByteBuffer(string: "exec caffeinate -dimsu\n"))
                for try await _ in inbound where Task.isCancelled { break }
            }
            try? await client.close()
        }
    }

    private func stopCaffeinate() {
        caffeinate?.cancel()
        caffeinate = nil
    }
}
