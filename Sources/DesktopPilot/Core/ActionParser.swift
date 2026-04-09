import CoreGraphics
import Foundation

// MARK: - Parsed Action

/// A single parsed action from an action string.
enum ParsedAction: Sendable {
    case tap(target: String)
    case doubletap(target: String)
    case type(text: String)
    case press(key: String)
    case wait(ms: Int)
    case screenshot(path: String?)
    case scroll(direction: String, amount: Int)
    case menu(path: String)
    case close(target: String)
    case listApps
}

// MARK: - Action Parser

/// Parses action strings like "tap BUTTON:Save", "type hello", "wait 2000".
enum ActionParser {

    /// Parse a single action string into a `ParsedAction`.
    ///
    /// Supported formats:
    /// - `tap BUTTON:Save`       — tap an element by TYPE:Label ref
    /// - `type hello world`      — type text (everything after "type ")
    /// - `press RETURN`          — press a key (RETURN, TAB, ESCAPE, DELETE, SPACE, arrow keys)
    /// - `press CMD+A`           — press a hotkey combination
    /// - `wait 2000`             — wait N milliseconds
    /// - `screenshot`            — capture full screen (returns base64)
    /// - `screenshot /path.png`  — capture full screen to file
    /// - `scroll down 3`         — scroll direction + amount
    /// - `menu File > Save`      — activate menu item
    /// - `apps`                  — list running apps
    static func parse(_ input: String) -> ParsedAction? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let firstSpace = trimmed.firstIndex(of: " ")
        let verb = String(trimmed[trimmed.startIndex..<(firstSpace ?? trimmed.endIndex)]).lowercased()
        let rest = firstSpace.map { String(trimmed[trimmed.index(after: $0)...]) } ?? ""

        switch verb {
        case "tap", "click":
            guard !rest.isEmpty else { return nil }
            return .tap(target: rest)

        case "doubletap", "doubleclick", "dclick":
            guard !rest.isEmpty else { return nil }
            return .doubletap(target: rest)

        case "type":
            guard !rest.isEmpty else { return nil }
            return .type(text: rest)

        case "press":
            guard !rest.isEmpty else { return nil }
            return .press(key: rest.uppercased())

        case "wait":
            let ms = Int(rest) ?? 500
            return .wait(ms: ms)

        case "screenshot":
            if rest.isEmpty {
                return .screenshot(path: nil)
            }
            return .screenshot(path: rest)

        case "scroll":
            let parts = rest.split(separator: " ", maxSplits: 1)
            let direction = parts.first.map(String.init) ?? "down"
            let amount = parts.count > 1 ? (Int(parts[1]) ?? 3) : 3
            return .scroll(direction: direction, amount: amount)

        case "menu":
            guard !rest.isEmpty else { return nil }
            return .menu(path: rest)

        case "close":
            guard !rest.isEmpty else { return nil }
            return .close(target: rest)

        case "apps":
            return .listApps

        default:
            // Try to interpret as a tap target if it contains ":"
            if trimmed.contains(":") {
                return .tap(target: trimmed)
            }
            return nil
        }
    }

    /// Parse a JSON array of action strings or a single action string.
    static func parseActions(_ input: JSONValue?) -> [String]? {
        guard let input else { return nil }

        switch input {
        case .string(let single):
            return [single]
        case .array(let arr):
            return arr.compactMap { item in
                if case .string(let s) = item { return s }
                return nil
            }
        default:
            return nil
        }
    }

    // MARK: - Key Resolution

    /// Resolve a key name to a virtual key code and modifier flags.
    static func resolveKey(_ keyString: String) -> (keyCode: UInt16, flags: UInt64)? {
        let parts = keyString.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces).uppercased() }

        var flags: UInt64 = 0
        var keyName = ""

        for part in parts {
            switch part {
            case "CMD", "COMMAND":  flags |= CGEventFlags.maskCommand.rawValue
            case "SHIFT":           flags |= CGEventFlags.maskShift.rawValue
            case "ALT", "OPTION":   flags |= CGEventFlags.maskAlternate.rawValue
            case "CTRL", "CONTROL": flags |= CGEventFlags.maskControl.rawValue
            default:                keyName = part
            }
        }

        guard let code = keyNameToCode(keyName) else { return nil }
        return (code, flags)
    }

    private static func keyNameToCode(_ name: String) -> UInt16? {
        switch name {
        case "RETURN", "ENTER":     return UInt16(VirtualKeyCode.returnKey)
        case "TAB":                 return UInt16(VirtualKeyCode.tab)
        case "SPACE":               return UInt16(VirtualKeyCode.space)
        case "DELETE", "BACKSPACE": return UInt16(VirtualKeyCode.delete)
        case "ESCAPE", "ESC":       return UInt16(VirtualKeyCode.escape)
        case "UP":                  return UInt16(VirtualKeyCode.upArrow)
        case "DOWN":                return UInt16(VirtualKeyCode.downArrow)
        case "LEFT":                return UInt16(VirtualKeyCode.leftArrow)
        case "RIGHT":               return UInt16(VirtualKeyCode.rightArrow)
        case "HOME":                return UInt16(VirtualKeyCode.home)
        case "END":                 return UInt16(VirtualKeyCode.end)
        case "PAGEUP":              return UInt16(VirtualKeyCode.pageUp)
        case "PAGEDOWN":            return UInt16(VirtualKeyCode.pageDown)
        case "F1":  return UInt16(VirtualKeyCode.f1)
        case "F2":  return UInt16(VirtualKeyCode.f2)
        case "F3":  return UInt16(VirtualKeyCode.f3)
        case "F4":  return UInt16(VirtualKeyCode.f4)
        case "F5":  return UInt16(VirtualKeyCode.f5)
        case "F6":  return UInt16(VirtualKeyCode.f6)
        case "F7":  return UInt16(VirtualKeyCode.f7)
        case "F8":  return UInt16(VirtualKeyCode.f8)
        case "F9":  return UInt16(VirtualKeyCode.f9)
        case "F10": return UInt16(VirtualKeyCode.f10)
        case "F11": return UInt16(VirtualKeyCode.f11)
        case "F12": return UInt16(VirtualKeyCode.f12)
        case "A": return UInt16(VirtualKeyCode.a)
        case "C": return UInt16(VirtualKeyCode.c)
        case "V": return UInt16(VirtualKeyCode.v)
        case "X": return UInt16(VirtualKeyCode.x)
        case "Z": return UInt16(VirtualKeyCode.z)
        case "S": return UInt16(VirtualKeyCode.s)
        case "W": return UInt16(VirtualKeyCode.w)
        case "Q": return UInt16(VirtualKeyCode.q)
        case "N": return UInt16(VirtualKeyCode.n)
        case "T": return UInt16(VirtualKeyCode.t)
        default:  return nil
        }
    }
}
