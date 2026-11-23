import Foundation

/// Text typed on the Apple TV (on the keyboard or by dictation), as the Windows key presses
/// a US keyboard would make for it, so it can be typed into a game or a launcher on the rig.
public enum KeyText {
    public struct Key: Equatable {
        /// Windows virtual-key code.
        public let code: UInt16
        public let shift: Bool
        public init(_ code: UInt16, shift: Bool = false) {
            self.code = code
            self.shift = shift
        }
    }

    public static let enter = Key(0x0D)
    public static let backspace = Key(0x08)
    public static let tab = Key(0x09)
    public static let escape = Key(0x1B)
    /// The modifier bit the stream's key packets carry for Shift.
    public static let shiftBit: UInt16 = 0x01

    /// The keys for `text`, in order. Characters a US keyboard can't type are left out.
    public static func keys(_ text: String) -> [Key] {
        text.compactMap(key)
    }

    public static func key(_ c: Character) -> Key? {
        if c == "\n" || c == "\r" { return enter }
        if c == "\t" { return tab }
        guard let a = c.asciiValue else {
            // Dictation and the keyboard can produce curly quotes and dashes.
            switch c {
            case "\u{2018}", "\u{2019}": return Key(0xDE)
            case "\u{201C}", "\u{201D}": return Key(0xDE, shift: true)
            case "\u{2013}", "\u{2014}": return Key(0xBD)
            case "\u{00A0}": return Key(0x20)
            default: return nil
            }
        }
        switch a {
        case 0x61...0x7A: return Key(UInt16(a - 0x20))
        case 0x41...0x5A: return Key(UInt16(a), shift: true)
        case 0x30...0x39: return Key(UInt16(a))
        case 0x20: return Key(0x20)
        default: break
        }
        let table: [Character: Key] = [
            "-": Key(0xBD), "_": Key(0xBD, shift: true),
            "=": Key(0xBB), "+": Key(0xBB, shift: true),
            "[": Key(0xDB), "{": Key(0xDB, shift: true),
            "]": Key(0xDD), "}": Key(0xDD, shift: true),
            "\\": Key(0xDC), "|": Key(0xDC, shift: true),
            ";": Key(0xBA), ":": Key(0xBA, shift: true),
            "'": Key(0xDE), "\"": Key(0xDE, shift: true),
            ",": Key(0xBC), "<": Key(0xBC, shift: true),
            ".": Key(0xBE), ">": Key(0xBE, shift: true),
            "/": Key(0xBF), "?": Key(0xBF, shift: true),
            "`": Key(0xC0), "~": Key(0xC0, shift: true),
            "!": Key(0x31, shift: true), "@": Key(0x32, shift: true), "#": Key(0x33, shift: true),
            "$": Key(0x34, shift: true), "%": Key(0x35, shift: true), "^": Key(0x36, shift: true),
            "&": Key(0x37, shift: true), "*": Key(0x38, shift: true), "(": Key(0x39, shift: true),
            ")": Key(0x30, shift: true),
        ]
        return table[c]
    }
}
