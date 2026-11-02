import Foundation

/// X11 keysyms, which RFB uses for every key. macOS Screen Sharing maps
/// Super to ⌘ Command and Alt to ⌥ Option.
enum Keysym {
    static let backspace: UInt32 = 0xFF08
    static let tab: UInt32 = 0xFF09
    static let returnKey: UInt32 = 0xFF0D
    static let escape: UInt32 = 0xFF1B
    static let forwardDelete: UInt32 = 0xFFFF
    static let home: UInt32 = 0xFF50
    static let left: UInt32 = 0xFF51
    static let up: UInt32 = 0xFF52
    static let right: UInt32 = 0xFF53
    static let down: UInt32 = 0xFF54
    static let pageUp: UInt32 = 0xFF55
    static let pageDown: UInt32 = 0xFF56
    static let end: UInt32 = 0xFF57
    static let shift: UInt32 = 0xFFE1
    static let control: UInt32 = 0xFFE3
    static let capsLock: UInt32 = 0xFFE5
    static let option: UInt32 = 0xFFE9   // Alt_L
    static let command: UInt32 = 0xFFEB  // Super_L
    static func function(_ n: Int) -> UInt32 { 0xFFBE + UInt32(n - 1) }

    /// Keysym for a printable character. Latin-1 maps directly; everything
    /// else uses the Unicode keysym range.
    static func character(_ c: Character) -> UInt32? {
        guard let scalar = c.unicodeScalars.first else { return nil }
        if c == "\n" || c == "\r" { return returnKey }
        if c == "\t" { return tab }
        let v = scalar.value
        if (0x20...0x7E).contains(v) || (0xA0...0xFF).contains(v) { return v }
        return 0x0100_0000 | v
    }
}
