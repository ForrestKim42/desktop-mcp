import ApplicationServices
import Foundation

// MARK: - Element Store

/// Stores the mapping between `App/TYPE:Label` ref strings and AXUIElement objects.
///
/// Refs use the format `AppName/TYPE:Label` (e.g. `Arc/BUTTON:Save`, `Finder/IMAGE:data`).
/// When duplicate labels appear, `@N` suffixes disambiguate: `Arc/BUTTON:OK@2`.
///
/// Supports multi-app element storage — snapshots from different apps coexist.
/// Uses `actor` isolation to guarantee thread safety.
public actor ElementStore {
    /// All elements keyed by full ref (App/TYPE:Label)
    private var elements: [String: AXElementWrapper] = [:]
    /// Ordered refs for display
    private var orderedRefs: [String] = []
    /// Tracks duplicate counts per app: "AppName/TYPE:Label" -> count
    private var labelCounts: [String: Int] = [:]
    /// Which apps have been snapshotted
    private var snapshotApps: Set<String> = []

    public init() {}

    // MARK: - Lifecycle

    /// Reset the entire store.
    public func reset() {
        elements = [:]
        orderedRefs = []
        labelCounts = [:]
        snapshotApps = []
    }

    /// Reset only elements for a specific app (before re-snapshotting it).
    public func resetApp(_ appName: String) {
        let prefix = appName + "/"
        let toRemove = elements.keys.filter { $0.hasPrefix(prefix) }
        for key in toRemove {
            elements.removeValue(forKey: key)
        }
        orderedRefs.removeAll { $0.hasPrefix(prefix) }
        let countKeysToRemove = labelCounts.keys.filter { $0.hasPrefix(prefix) }
        for key in countKeysToRemove {
            labelCounts.removeValue(forKey: key)
        }
        snapshotApps.remove(appName)
    }

    /// Mark an app as snapshotted.
    public func markSnapshotted(_ appName: String) {
        snapshotApps.insert(appName)
    }

    /// Check if an app has been snapshotted in this session.
    public func isSnapshotted(_ appName: String) -> Bool {
        snapshotApps.contains(appName)
    }

    // MARK: - Role Mapping

    static func shortRole(_ axRole: String?) -> String {
        guard let role = axRole else { return "UNKNOWN" }
        switch role {
        case "AXButton":        return "BUTTON"
        case "AXTextField":     return "INPUT"
        case "AXTextArea":      return "TEXTAREA"
        case "AXStaticText":    return "TEXT"
        case "AXCheckBox":      return "CHECKBOX"
        case "AXRadioButton":   return "RADIO"
        case "AXPopUpButton":   return "SELECT"
        case "AXMenuButton":    return "MENUBUTTON"
        case "AXMenuItem":      return "MENUITEM"
        case "AXMenu":          return "MENU"
        case "AXImage":         return "IMAGE"
        case "AXWindow":        return "WINDOW"
        case "AXGroup":         return "GROUP"
        case "AXSlider":        return "SLIDER"
        case "AXLink":          return "LINK"
        case "AXTabGroup":      return "TABGROUP"
        case "AXTab":           return "TAB"
        case "AXScrollArea":    return "SCROLL"
        case "AXToolbar":       return "TOOLBAR"
        case "AXList":          return "LIST"
        case "AXTable":         return "TABLE"
        case "AXRow":           return "ROW"
        case "AXCell":          return "CELL"
        case "AXComboBox":      return "COMBO"
        case "AXDisclosureTriangle": return "DISCLOSURE"
        case "AXProgressIndicator":  return "PROGRESS"
        case "AXSplitGroup":    return "SPLIT"
        case "AXOutline":       return "OUTLINE"
        case "AXWebArea":       return "WEB"
        case "AXHeading":       return "HEADING"
        default:
            if role.hasPrefix("AX") {
                return String(role.dropFirst(2)).uppercased()
            }
            return role.uppercased()
        }
    }

    // MARK: - Label Selection

    static func bestLabel(
        role: String?,
        title: String?,
        description: String?,
        value: String?
    ) -> String {
        let isInput = role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox"

        func isClean(_ s: String?) -> String? {
            guard let s, !s.isEmpty else { return nil }
            if s.contains("<AXValue 0x") || s.contains("{value = ") { return nil }
            return s
        }

        if let t = isClean(title) { return t }
        if let d = isClean(description) { return d }
        if let v = isClean(value), !v.isEmpty {
            if v.count > 80 {
                return String(v.prefix(77)) + "..."
            }
            return v
        }
        return "unlabeled"
    }

    // MARK: - Registration

    /// Register an element and return its `App/TYPE:Label` ref.
    func register(
        _ wrapper: AXElementWrapper,
        appName: String,
        role: String?,
        title: String?,
        description: String?,
        value: String?
    ) -> String {
        let shortRole = Self.shortRole(role)
        let label = Self.bestLabel(role: role, title: title, description: description, value: value)
        let baseID = "\(appName)/\(shortRole):\(label)"

        let count = (labelCounts[baseID] ?? 0) + 1
        labelCounts[baseID] = count

        let ref: String
        if count == 1 {
            ref = baseID
        } else {
            ref = "\(baseID)@\(count)"
            if count == 2, let firstWrapper = elements[baseID] {
                elements.removeValue(forKey: baseID)
                let renamed = "\(baseID)@1"
                elements[renamed] = firstWrapper
                if let idx = orderedRefs.firstIndex(of: baseID) {
                    orderedRefs[idx] = renamed
                }
            }
        }

        elements[ref] = wrapper
        orderedRefs.append(ref)
        return ref
    }

    // MARK: - Lookup

    /// Resolve a ref string back to its AXElementWrapper.
    ///
    /// Accepts both full refs (`Arc/BUTTON:Save`) and short refs (`BUTTON:Save`).
    /// Short refs search the default app first, then all apps.
    public func resolve(_ ref: String, defaultApp: String? = nil) -> AXElementWrapper? {
        // Pass 1: exact match
        if let wrapper = elements[ref] { return wrapper }

        // Pass 2: if ref has no app prefix, try adding defaultApp
        if !ref.contains("/"), let app = defaultApp {
            let fullRef = "\(app)/\(ref)"
            if let wrapper = elements[fullRef] { return wrapper }
        }

        // Pass 3: case-insensitive exact
        let lower = ref.lowercased()
        for key in orderedRefs {
            if key.lowercased() == lower {
                return elements[key]
            }
        }

        // Pass 4: if ref has no app prefix, try matching just the element part
        if !ref.contains("/") {
            for key in orderedRefs {
                if let slashIdx = key.firstIndex(of: "/") {
                    let elementPart = String(key[key.index(after: slashIdx)...])
                    if elementPart.lowercased() == lower {
                        return elements[key]
                    }
                }
            }
        }

        // Pass 5: contains match (last resort)
        for key in orderedRefs {
            if key.lowercased().contains(lower) {
                return elements[key]
            }
        }

        return nil
    }

    /// Extract the app name from a ref like "Arc/BUTTON:Save".
    /// Returns nil if no app prefix.
    public static func extractApp(from ref: String) -> String? {
        guard let slashIdx = ref.firstIndex(of: "/") else { return nil }
        let candidate = String(ref[ref.startIndex..<slashIdx])
        // Make sure it's not a TYPE: prefix (types don't contain spaces and are uppercase)
        // App names can contain spaces, mixed case, Korean, etc.
        // Types are always uppercase single words like BUTTON, INPUT, TEXT
        let knownTypes = Set(["BUTTON", "INPUT", "TEXTAREA", "TEXT", "CHECKBOX", "RADIO",
                              "SELECT", "MENUBUTTON", "MENUITEM", "MENU", "IMAGE", "WINDOW",
                              "GROUP", "SLIDER", "LINK", "TABGROUP", "TAB", "SCROLL",
                              "TOOLBAR", "LIST", "TABLE", "ROW", "CELL", "COMBO",
                              "DISCLOSURE", "PROGRESS", "SPLIT", "OUTLINE", "WEB", "HEADING",
                              "UNKNOWN", "VALUEINDICATOR", "SCROLLBAR", "SPLITTER"])
        if knownTypes.contains(candidate.uppercased()) { return nil }
        return candidate
    }

    /// Strip the app prefix from a ref, returning just the element part.
    public static func stripApp(from ref: String) -> String {
        guard let slashIdx = ref.firstIndex(of: "/"),
              extractApp(from: ref) != nil else { return ref }
        return String(ref[ref.index(after: slashIdx)...])
    }

    // MARK: - Listing

    /// Return all refs in tree traversal order.
    public func allRefs() -> [String] {
        return orderedRefs
    }

    /// Return refs for a specific app only.
    public func refsForApp(_ appName: String) -> [String] {
        let prefix = appName + "/"
        return orderedRefs.filter { $0.hasPrefix(prefix) }
    }

    /// Return all snapshotted app names.
    public func allApps() -> [String] {
        return Array(snapshotApps).sorted()
    }

    // MARK: - Diagnostics

    public func count() -> Int {
        return elements.count
    }
}
