import Foundation

/// A key press that types a character of the US keyboard layout, for text that the app types on a device.
package struct TypedKey: Equatable, Sendable {
    /// The Mac's virtual key code of the key, which names its place on an ANSI keyboard.
    package var keyCode: UInt16
    /// Whether Shift is held for the key.
    package var shift: Bool

    package init(keyCode: UInt16, shift: Bool = false) {
        self.keyCode = keyCode
        self.shift = shift
    }

    /// The keys that type `text` on a keyboard that a device reads with the US layout. A line feed is Return.
    ///
    /// Throws for a character that the layout does not type, without naming it: the text can be a password.
    package static func keys(typing text: String) throws -> [TypedKey] {
        try text.map { character in
            if let keyCode = unshifted[character] { return TypedKey(keyCode: keyCode) }
            if let keyCode = shifted[character] { return TypedKey(keyCode: keyCode, shift: true) }
            throw SimulatorError.invalidArguments(
                "The text has a character that the US keyboard layout does not type.")
        }
    }

    /// The rows of an ANSI keyboard: each key's virtual key code with what it types alone and with Shift.
    private static let layout: [(keyCode: UInt16, plain: Character, shifted: Character)] = [
        (50, "`", "~"), (18, "1", "!"), (19, "2", "@"), (20, "3", "#"), (21, "4", "$"), (23, "5", "%"),
        (22, "6", "^"), (26, "7", "&"), (28, "8", "*"), (25, "9", "("), (29, "0", ")"), (27, "-", "_"),
        (24, "=", "+"),
        (12, "q", "Q"), (13, "w", "W"), (14, "e", "E"), (15, "r", "R"), (17, "t", "T"), (16, "y", "Y"),
        (32, "u", "U"), (34, "i", "I"), (31, "o", "O"), (35, "p", "P"), (33, "[", "{"), (30, "]", "}"),
        (42, "\\", "|"),
        (0, "a", "A"), (1, "s", "S"), (2, "d", "D"), (3, "f", "F"), (5, "g", "G"), (4, "h", "H"),
        (38, "j", "J"), (40, "k", "K"), (37, "l", "L"), (41, ";", ":"), (39, "'", "\""),
        (6, "z", "Z"), (7, "x", "X"), (8, "c", "C"), (9, "v", "V"), (11, "b", "B"), (45, "n", "N"),
        (46, "m", "M"), (43, ",", "<"), (47, ".", ">"), (44, "/", "?"),
    ]

    private static let unshifted: [Character: UInt16] = {
        var keys = Dictionary(uniqueKeysWithValues: layout.map { ($0.plain, $0.keyCode) })
        keys[" "] = 49
        keys["\n"] = 36
        return keys
    }()

    private static let shifted = Dictionary(uniqueKeysWithValues: layout.map { ($0.shifted, $0.keyCode) })
}
