import UIKit

/// Deck keys → bytes for an SSH terminal, matching what Terminal.app sends.
@MainActor
final class TerminalKeyTarget: KeyTarget {
    weak var session: TerminalSession?
    var onToggle: ((DeckKeyKind) -> Void)?

    init(session: TerminalSession?) { self.session = session }

    func press(_ press: KeyPress) {
        guard let session else { return }
        let mods = press.modifiers
        let ctrl = mods.contains(.control)
        let meta = mods.contains(.option) && Preferences.shared.optionAsMeta
        let shift = mods.contains(.shift)
        let fn = mods.contains(.fn)
        let esc: [UInt8] = [0x1B]

        if mods.contains(.command) {
            command(press.kind, session: session)
            return
        }

        var out: [UInt8] = []
        switch press.kind {
        case .char(let lower, let upper):
            let isLetter = lower.isLetter
            var c = (shift != (press.capsLock && isLetter)) ? upper : lower
            if shift && !isLetter { c = upper }
            if ctrl, let control = controlByte(c) {
                out = [control]
            } else {
                out = Array(String(c).utf8)
            }
            if meta { out = esc + out }
        case .space:
            out = ctrl ? [0] : [0x20]
            if meta { out = esc + out }
        case .returnKey: out = meta ? esc + [0x0D] : [0x0D]
        case .tab: out = shift ? Array("\u{1B}[Z".utf8) : [0x09]
        case .delete:
            if fn { out = Array("\u{1B}[3~".utf8) }
            else if meta || ctrl { out = [0x17] } // delete word, like ⌥⌫ in Terminal
            else { out = [0x7F] }
        case .escape: out = esc
        case .function(let n): out = Array(functionKey(n).utf8)
        case .arrow(let arrow): out = Array(arrowSequence(arrow, fn: fn, meta: meta, session: session).utf8)
        case .modifier, .capsLock, .power, .missionControl, .toggleTouch:
            return
        case .toggleKeyboard:
            onToggle?(press.kind)
            return
        }
        session.send(out)
    }

    private func command(_ kind: DeckKeyKind, session: TerminalSession) {
        guard case .char(let lower, _) = kind else { return }
        let view = session.terminalView
        switch lower {
        case "c": view.copy(nil)
        case "v": view.paste(nil)
        case "a": view.selectAll(nil)
        case "k": session.send([0x0C]) // ⌘K: clear (sends ^L)
        default: break
        }
    }

    private func controlByte(_ c: Character) -> UInt8? {
        guard let ascii = c.asciiValue else { return nil }
        switch c {
        case "a"..."z": return ascii - 0x60
        case "A"..."Z": return ascii - 0x40
        case "@", " ", "2": return 0x00
        case "[", "3": return 0x1B
        case "\\", "4": return 0x1C
        case "]", "5": return 0x1D
        case "^", "6": return 0x1E
        case "_", "-", "7": return 0x1F
        case "/": return 0x1F
        case "8", "?": return 0x7F
        default: return nil
        }
    }

    private func functionKey(_ n: Int) -> String {
        switch n {
        case 1: "\u{1B}OP"
        case 2: "\u{1B}OQ"
        case 3: "\u{1B}OR"
        case 4: "\u{1B}OS"
        default:
            "\u{1B}[\([5: 15, 6: 17, 7: 18, 8: 19, 9: 20, 10: 21, 11: 23, 12: 24][n] ?? 15)~"
        }
    }

    private func arrowSequence(_ arrow: Arrow, fn: Bool, meta: Bool, session: TerminalSession) -> String {
        if fn {
            switch arrow {
            case .up: return "\u{1B}[5~"     // page up
            case .down: return "\u{1B}[6~"   // page down
            case .left: return "\u{1B}[H"    // home
            case .right: return "\u{1B}[F"   // end
            }
        }
        if meta {
            switch arrow {
            case .left: return "\u{1B}b"     // word back, like ⌥← in Terminal
            case .right: return "\u{1B}f"
            default: break
            }
        }
        let letter: String = switch arrow {
        case .up: "A"
        case .down: "B"
        case .right: "C"
        case .left: "D"
        }
        return (session.applicationCursor ? "\u{1B}O" : "\u{1B}[") + letter
    }
}

/// Deck keys → RFB key events for the remote Mac. Modifiers are sent as
/// real key-downs around the key, so ⌘-shortcuts behave natively.
@MainActor
final class ScreenKeyTarget: KeyTarget {
    weak var session: ScreenSession?
    var onToggle: ((DeckKeyKind) -> Void)?

    init(session: ScreenSession?) { self.session = session }

    func press(_ press: KeyPress) {
        guard let session else { return }
        let mods = press.modifiers
        var held: [UInt32] = []
        if mods.contains(.control) { held.append(Keysym.control) }
        if mods.contains(.option) { held.append(Keysym.option) }
        if mods.contains(.command) { held.append(Keysym.command) }
        let fn = mods.contains(.fn)

        let keysym: UInt32
        switch press.kind {
        case .char(let lower, let upper):
            let shifted = mods.contains(.shift) || (press.capsLock && lower.isLetter)
            if shifted { held.append(Keysym.shift) }
            guard let sym = Keysym.character(shifted ? upper : lower) else { return }
            if mods.contains(.command) && lower.isLetter, lower == "v" {
                session.pasteFromPhone()
                return
            }
            keysym = sym
        case .space: keysym = 0x20
        case .returnKey: keysym = Keysym.returnKey
        case .tab: keysym = Keysym.tab
        case .delete: keysym = fn ? Keysym.forwardDelete : Keysym.backspace
        case .escape: keysym = Keysym.escape
        case .function(let n): keysym = Keysym.function(n)
        case .arrow(let arrow):
            if mods.contains(.shift) { held.append(Keysym.shift) }
            switch arrow {
            case .up: keysym = fn ? Keysym.pageUp : Keysym.up
            case .down: keysym = fn ? Keysym.pageDown : Keysym.down
            case .left: keysym = fn ? Keysym.home : Keysym.left
            case .right: keysym = fn ? Keysym.end : Keysym.right
            }
        case .power:
            session.press(UInt32(Character("q").asciiValue!), modifiers: [Keysym.control, Keysym.command])
            return
        case .missionControl:
            session.press(Keysym.up, modifiers: [Keysym.control])
            return
        case .capsLock, .modifier:
            // Caps lock is applied locally (letters are sent shifted), so
            // the Mac's own caps-lock state is never toggled behind your back.
            return
        case .toggleKeyboard, .toggleTouch:
            onToggle?(press.kind)
            return
        }
        session.press(keysym, modifiers: held)
    }
}
