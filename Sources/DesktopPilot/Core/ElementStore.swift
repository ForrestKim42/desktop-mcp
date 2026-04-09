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
    /// Truncation metadata: ref → (totalChildren, visibleChildren)
    private var truncationMeta: [String: (total: Int, visible: Int)] = [:]

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
        let metaKeysToRemove = truncationMeta.keys.filter { $0.hasPrefix(prefix) }
        for key in metaKeysToRemove {
            truncationMeta.removeValue(forKey: key)
        }
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

        // Whether `ref` already carries an app prefix. Labels may contain `/`
        // so we cannot use `contains("/")` as a proxy.
        let hasAppPrefix = (Self.extractApp(from: ref) != nil)

        // Pass 2: if ref has no app prefix, try adding defaultApp
        if !hasAppPrefix, let app = defaultApp {
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
        if !hasAppPrefix {
            for key in orderedRefs {
                if let appPart = Self.extractApp(from: key) {
                    let elementPart = String(key.dropFirst(appPart.count + 1))
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
    ///
    /// Refs use the canonical format `AppName/TYPE:Label[@N]`. Labels can
    /// contain literal slashes (e.g. `TEXTAREA:foo/bar/baz`), so we cannot
    /// blindly take everything before the first `/` as the app name. Two
    /// disqualifiers tell us the candidate is part of a TYPE:Label, not an
    /// app prefix:
    ///
    ///   1. The candidate contains `:` (TYPE:Label delimiter).
    ///   2. The candidate is a known TYPE prefix (e.g. `BUTTON`, `TEXTAREA`).
    ///
    /// App names never contain `:` and never collide with TYPE prefixes.
    public static func extractApp(from ref: String) -> String? {
        guard let slashIdx = ref.firstIndex(of: "/") else { return nil }
        let candidate = String(ref[ref.startIndex..<slashIdx])
        // App names never contain ":". A leading "TYPE:Label" segment with a
        // slash inside the label would otherwise be misread as an app name.
        if candidate.contains(":") { return nil }
        // Defensive: also reject known TYPE prefixes used without a colon.
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

    /// Find refs whose full ref string contains `query` (case-insensitive),
    /// scoped to one app. Used by the `find:` path verb.
    public func findByLabel(_ appName: String, query: String) -> [String] {
        let prefix = appName + "/"
        let q = query.lowercased()
        return orderedRefs.filter {
            $0.hasPrefix(prefix) && $0.lowercased().contains(q)
        }
    }

    /// Return a page of refs for a specific app (0-indexed page).
    public func refsForApp(_ appName: String, page: Int, pageSize: Int) -> (refs: [String], total: Int) {
        let all = refsForApp(appName)
        let start = page * pageSize
        guard start < all.count else { return ([], all.count) }
        let end = min(start + pageSize, all.count)
        return (Array(all[start..<end]), all.count)
    }

    /// Record truncation metadata for a ref (element has more children than shown).
    public func setTruncation(ref: String, total: Int, visible: Int) {
        truncationMeta[ref] = (total: total, visible: visible)
    }

    /// Get truncation annotations for an app, formatted for display.
    public func truncationAnnotations(appName: String) -> [String] {
        let prefix = appName + "/"
        var annotations: [String] = []
        for (ref, meta) in truncationMeta where ref.hasPrefix(prefix) {
            let shortRef = String(ref[ref.index(after: ref.firstIndex(of: "/")!)...])
            annotations.append("  \(shortRef) [\(meta.total) items, \(meta.visible) visible]")
        }
        return annotations.sorted()
    }

    /// Return total ref count for a specific app.
    public func refCountForApp(_ appName: String) -> Int {
        let prefix = appName + "/"
        return orderedRefs.count { $0.hasPrefix(prefix) }
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
