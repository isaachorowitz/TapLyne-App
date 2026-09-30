import TaplyneServer

/// Maps text and named keys to HID keyboard reports for a US layout.
enum KeyMap {
    struct Stroke: Equatable {
        let key: Keycode
        let shift: Bool
    }

    /// The stroke that types `character` on a US keyboard, or nil when it has none.
    static func stroke(for character: Character) -> Stroke? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
              scalar.isASCII else { return nil }
        let c = Character(scalar)
        if let lower = letters[c.lowercased().first ?? c], c.isLetter {
            return Stroke(key: lower, shift: c.isUppercase)
        }
        if let key = plain[c] { return Stroke(key: key, shift: false) }
        if let key = shifted[c] { return Stroke(key: key, shift: true) }
        return nil
    }

    static func canType(_ text: String) -> Bool {
        text.allSatisfy { stroke(for: $0) != nil }
    }

    static func keycode(for key: KeyName) -> Keycode {
        switch key {
        case .enter: .return
        case .escape: .escape
        case .backspace: .backspace
        case .tab: .tab
        case .space: .space
        case .arrowUp: .upArrow
        case .arrowDown: .downArrow
        case .arrowLeft: .leftArrow
        case .arrowRight: .rightArrow
        }
    }

    static func modifiers(_ list: [Modifier]) -> KeyboardModifiers {
        list.reduce(into: KeyboardModifiers()) { result, modifier in
            switch modifier {
            case .control: result.insert(.leftCtrl)
            case .shift: result.insert(.leftShift)
            case .alternate: result.insert(.leftAlt)
            case .command: result.insert(.leftGUI)
            }
        }
    }

    private static let letters: [Character: Keycode] = {
        let keys: [Keycode] = [.a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
                               .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z]
        return Dictionary(uniqueKeysWithValues: zip("abcdefghijklmnopqrstuvwxyz", keys))
    }()

    private static let plain: [Character: Keycode] = [
        "1": .digit1, "2": .digit2, "3": .digit3, "4": .digit4, "5": .digit5,
        "6": .digit6, "7": .digit7, "8": .digit8, "9": .digit9, "0": .digit0,
        " ": .space, "\n": .return, "\t": .tab,
        "-": .minus, "=": .equal, "[": .leftBracket, "]": .rightBracket, "\\": .backslash,
        ";": .semicolon, "'": .quote, "`": .grave, ",": .comma, ".": .period, "/": .slash
    ]

    private static let shifted: [Character: Keycode] = [
        "!": .digit1, "@": .digit2, "#": .digit3, "$": .digit4, "%": .digit5,
        "^": .digit6, "&": .digit7, "*": .digit8, "(": .digit9, ")": .digit0,
        "_": .minus, "+": .equal, "{": .leftBracket, "}": .rightBracket, "|": .backslash,
        ":": .semicolon, "\"": .quote, "~": .grave, "<": .comma, ">": .period, "?": .slash
    ]
}
