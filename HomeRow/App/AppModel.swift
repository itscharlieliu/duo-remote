import SwiftUI
import Observation

/// Folded / half-open / flat, from the iOS 27.1 hinge API plus the window
/// size.
///
/// - `.folded`: the 5.4″ outer display. Finding, pairing, picking a Mac.
/// - `.deck`: the 7.6″ inner display, portrait. The lower half becomes the
///   MacBook deck (keyboard / trackpad) — the crease sits at the midpoint.
/// - `.flat`: the inner display in landscape. Screen sessions go full-bleed
///   with direct touch.
///
/// The inner display's crease runs across it in portrait and down it in
/// landscape, so the deck split only makes sense in portrait. A closed
/// hinge always means the outer display; an unknown hinge falls back to
/// the window size.
enum Posture: Equatable {
    case folded, deck, flat

    static func from(size: CGSize, hinge: UIHinge.Status?) -> Posture {
        let innerSized = min(size.width, size.height) >= 500
        guard hinge != .closed, innerSized else { return .folded }
        return size.width > size.height ? .flat : .deck
    }
}

@MainActor
@Observable
final class AppModel {
    enum FoldedTab: Hashable { case hosts, discover, settings }

    enum Focus: Hashable {
        case terminal(UUID)
        case screen
    }

    var foldedTab: FoldedTab = .hosts
    var hinge: UIHinge.Status?
    var terminals: [TerminalSession] = []
    var screen: ScreenSession?
    var focus: Focus?
    /// On the folded display, sessions are presented over the host list.
    var showSessionWhileFolded = false
    var banner: String?

    var prompter = PasswordPrompter()

    var focusedTerminal: TerminalSession? {
        if case .terminal(let id) = focus { return terminals.first { $0.id == id } }
        return nil
    }

    var hasSessions: Bool { !terminals.isEmpty || screen != nil }

    func sessionCount(for mac: Mac) -> Int {
        terminals.filter { $0.mac.id == mac.id }.count + (screen?.mac.id == mac.id ? 1 : 0)
    }

    // MARK: Opening sessions

    func openTerminal(_ mac: Mac) async {
        guard mac.hasSSH, mac.hostKey != nil else {
            banner = "\(mac.name) has Remote Login off, so only its screen is available."
            return
        }
        do {
            let credential = try await CredentialBroker.sshCredential(for: mac, prompt: prompter)
            let session = TerminalSession(mac: mac)
            terminals.append(session)
            focus = .terminal(session.id)
            showSessionWhileFolded = true
            session.start(credential: credential)
        } catch is CancellationError {
        } catch {
            banner = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func openScreen(_ mac: Mac) async {
        if let screen, screen.mac.id == mac.id, screen.state != .closed(nil) {
            focus = .screen
            showSessionWhileFolded = true
            return
        }
        guard let password = await CredentialBroker.screenPassword(for: mac, prompt: prompter) else { return }
        screen?.close()
        let session = ScreenSession(mac: mac)
        screen = session
        focus = .screen
        showSessionWhileFolded = true
        session.start(password: password)
    }

    func close(terminal: TerminalSession) {
        terminal.close()
        terminals.removeAll { $0.id == terminal.id }
        if focus == .terminal(terminal.id) {
            focus = terminals.last.map { .terminal($0.id) } ?? (screen != nil ? .screen : nil)
        }
        if !hasSessions { showSessionWhileFolded = false }
    }

    func closeScreen() {
        screen?.close()
        screen = nil
        if focus == .screen { focus = terminals.last.map { .terminal($0.id) } }
        if !hasSessions { showSessionWhileFolded = false }
    }

    /// Restarts a closed terminal tab in place.
    func reconnect(_ terminal: TerminalSession) async {
        do {
            let credential = try await CredentialBroker.sshCredential(for: terminal.mac, prompt: prompter)
            terminal.start(credential: credential)
        } catch is CancellationError {
        } catch {
            banner = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
