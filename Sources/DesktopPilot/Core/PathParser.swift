import CoreGraphics
import Foundation

// MARK: - Path Grammar
//
// A path is a `/`-joined sequence of segments, optionally ended by a terminator
// marker that decides whether the path produces a view dump, a silent ok, or
// an assertion.
//
//   Slack                                    — read Slack root
//   Slack/Dialog                             — focus subregion
//   Slack/message_container@2                — focus a ref
//   Slack/find:닫기/tap                      — find + act
//   Slack/Input:message_input/type:hello/press:RETURN?   — batched action with dump
//
// Terminators:
//   ?  → dump the current view at the end of the path
//   !  → assertion mode: return only ok/fail, never a dump
//   (nothing) → silent ok on success, error-with-context on failure
//
// The full philosophy lives in docs/PATH_API.md.

public enum PathSegment: Sendable, Equatable {
    /// First segment naming the target app. Only legal at position 0.
    case app(String)
    /// A ref like `BUTTON:Save`, `BUTTON:Save@2`, `message_container`, `Dialog`.
    /// Refs accumulate as the "current focus" for subsequent verbs.
    case ref(String)
    /// A verb like `tap`, `type:hello`, `find:닫기`, `press:RETURN`.
    case verb(name: String, args: String?)
}

public enum PathTerminator: Sendable, Equatable {
    case silent   // no marker — return "ok" on success
    case dump     // `?` — dump the end-state view
    case assert   // `!` — assertion-only, never dump
}

public struct ParsedPath: Sendable {
    public let raw: String
    public let segments: [PathSegment]
    public let terminator: PathTerminator
}

// MARK: - Parser

public enum PathParser {

    /// Verbs that the path grammar recognizes. Case-insensitive at parse time.
    public static let verbs: Set<String> = [
        "tap", "click",
        "doubletap", "dclick", "doubleclick",
        "type", "press",
        "scroll", "wait",
        "find", "inspect", "focus", "expect",
        "screenshot", "menu", "close", "apps",
    ]

    /// Uppercase element types that unambiguously mark a `TYPE:Label` ref.
    /// Unknown uppercase tokens before `:` are also treated as refs (CDP snapshots
    /// emit custom types like `channel-sidebar-channel:alpha-room`, which we keep
    /// verbatim).
    public static let knownTypes: Set<String> = [
        "BUTTON", "INPUT", "TEXTAREA", "TEXT", "CHECKBOX", "RADIO",
        "SELECT", "MENUBUTTON", "MENUITEM", "MENU", "IMAGE", "WINDOW",
        "GROUP", "SLIDER", "LINK", "TABGROUP", "TAB", "SCROLL",
        "TOOLBAR", "LIST", "TABLE", "ROW", "CELL", "COMBO",
        "DISCLOSURE", "PROGRESS", "SPLIT", "OUTLINE", "WEB", "HEADING",
        "VALUEINDICATOR", "SCROLLBAR", "SPLITTER", "UNKNOWN",
    ]

    /// Parse a raw path string into a `ParsedPath`.
    public static func parse(_ raw: String) -> ParsedPath {
        let stripped = raw.trimmingCharacters(in: .whitespaces)

        // 1. Detect trailing terminator marker.
        var body = stripped
        var terminator: PathTerminator = .silent
        if let last = body.last {
            if last == "?" { terminator = .dump; body.removeLast() }
            else if last == "!" { terminator = .assert; body.removeLast() }
        }

        // 2. Split the body on `/`, respecting `\/` escapes.
        let parts = splitPath(body)

        // 3. Classify each part into an app / ref / verb segment.
        var segments: [PathSegment] = []
        for (i, part) in parts.enumerated() {
            segments.append(classify(part, isFirst: i == 0))
        }

        return ParsedPath(raw: raw, segments: segments, terminator: terminator)
    }

    /// Split a path body on `/`, treating `\/` as a literal slash and trimming
    /// whitespace around each part.
    private static func splitPath(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\\", s.index(after: i) < s.endIndex {
                current.append(s[s.index(after: i)])
                i = s.index(i, offsetBy: 2)
                continue
            }
            if c == "/" {
                parts.append(current)
                current = ""
                i = s.index(after: i)
                continue
            }
            current.append(c)
            i = s.index(after: i)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Classify a single segment.
    ///
    /// Precedence:
    /// 1. Starts with a known verb keyword → `.verb`.
    /// 2. Contains `:` with an uppercase prefix (or a known type) → `.ref`.
    /// 3. First position without a `:` → `.app`.
    /// 4. Otherwise → `.ref` (covers region names, group labels, raw refs).
    private static func classify(_ part: String, isFirst: Bool) -> PathSegment {
        let colonIdx = part.firstIndex(of: ":")
        let headRaw = colonIdx.map { String(part[..<$0]) } ?? part
        let argsRaw = colonIdx.map { String(part[part.index(after: $0)...]) }
        let headLower = headRaw.lowercased()

        // Verb match: head is exactly a known verb keyword.
        if verbs.contains(headLower) {
            return .verb(name: headLower, args: argsRaw)
        }

        // Ref match: has a `:` and the head looks like a type (uppercase or known).
        if colonIdx != nil {
            let upper = headRaw.uppercased()
            if knownTypes.contains(upper) || headRaw == upper || headRaw.contains("-") {
                return .ref(part)
            }
        }

        // First segment with no `:` → app name.
        if isFirst && colonIdx == nil {
            return .app(part)
        }

        // Default: treat as ref (regions, group names, labels with `:` in them).
        return .ref(part)
    }
}

// MARK: - Key Resolution
//
// Key-name ↔ virtual-keycode table used by the `press:` verb. Moved here from
// the retired `ActionParser.swift` so the path layer is a single entrypoint.

public enum KeyResolver {

    public static func resolve(_ keyString: String) -> (keyCode: UInt16, flags: UInt64)? {
        let parts = keyString
            .split(separator: "+")
            .map { String($0).trimmingCharacters(in: .whitespaces).uppercased() }

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
