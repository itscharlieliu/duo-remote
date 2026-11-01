import Foundation

/// X11 keysyms sent in RFB KeyEvent messages. Only the set a phone needs:
/// printable ASCII (keysym == Unicode scalar), plus the named special keys.
enum VNCKeys {
    static let backspace: UInt32 = 0xFF08
    static let tab: UInt32 = 0xFF09
    static let `return`: UInt32 = 0xFF0D
    static let escape: UInt32 = 0xFF1B
    static let delete: UInt32 = 0xFFFF
    static let home: UInt32 = 0xFF50
    static let left: UInt32 = 0xFF51
    static let up: UInt32 = 0xFF52
    static let right: UInt32 = 0xFF53
    static let down: UInt32 = 0xFF54
    static let pageUp: UInt32 = 0xFF55
    static let pageDown: UInt32 = 0xFF56
    static let end: UInt32 = 0xFF57

    // Modifiers — macOS reads these as the physical keys they are.
    static let shiftLeft: UInt32 = 0xFFE1
    static let controlLeft: UInt32 = 0xFFE3
    static let altLeft: UInt32 = 0xFFE9      // Option on a Mac keyboard
    static let superLeft: UInt32 = 0xFFEB    // Command on a Mac keyboard
    static let f1: UInt32 = 0xFFBE

    /// Map one typed character to a keysym. Returns nil for characters
    /// with no direct ASCII keysym (emoji, etc.) — those are simply not sent.
    static func keysym(for character: Character) -> UInt32? {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1,
              scalar.value < 128 else { return nil }
        return scalar.value
    }

    /// Special keys by the label shown on the on-screen key row.
    static func keysym(forLabel label: String) -> UInt32? {
        switch label {
        case "Esc": return escape
        case "Tab": return tab
        case "⌫": return backspace
        case "⏎": return `return`
        case "←": return left
        case "→": return right
        case "↑": return up
        case "↓": return down
        default: return nil
        }
    }
}
