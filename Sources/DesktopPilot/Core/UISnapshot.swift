import Foundation

// MARK: - Element Kind
//
// Normalized element classification shared by every Collector (CDP, AX, ...).
// Adding a new source means: emit refs whose TYPE prefix matches one of these
// raw values. All compression / diff / formatting logic depends only on this
// enum, not on where the element came from.

public enum ElementKind: String, Sendable {
    case button = "BUTTON"
    case link = "LINK"
    case input = "INPUT"
    case textArea = "TEXTAREA"
    case checkbox = "CHECKBOX"
    case radio = "RADIO"
    case select = "SELECT"
    case menuButton = "MENUBUTTON"
    case menuItem = "MENUITEM"
    case menu = "MENU"
    case image = "IMAGE"
    case window = "WINDOW"
    case group = "GROUP"
    case slider = "SLIDER"
    case tabGroup = "TABGROUP"
    case tab = "TAB"
    case scroll = "SCROLL"
    case toolbar = "TOOLBAR"
    case list = "LIST"
    case table = "TABLE"
    case row = "ROW"
    case cell = "CELL"
    case combo = "COMBO"
    case disclosure = "DISCLOSURE"
    case progress = "PROGRESS"
    case split = "SPLIT"
    case outline = "OUTLINE"
    case web = "WEB"
    case heading = "HEADING"
    case text = "TEXT"
    case valueIndicator = "VALUEINDICATOR"
    case scrollbar = "SCROLLBAR"
    case splitter = "SPLITTER"
    case treeitem = "TREEITEM"
    case dialog = "DIALOG"
    case `switch` = "SWITCH"
    case unknown = "UNKNOWN"

    public static func parse(_ raw: String) -> ElementKind {
        ElementKind(rawValue: raw.uppercased()) ?? .unknown
    }
}

// MARK: - Parsed Ref
//
// Refs use the canonical format `AppName/TYPE:Label[@N]`. Parsing is the only
// place that knows the format — every other layer works on ParsedRef values.

public struct ParsedRef: Sendable, Equatable {
    public let appName: String?
    public let kind: ElementKind
    public let labelBase: String
    public let index: Int?

    public static func parse(_ ref: String) -> ParsedRef? {
        var working = ref
        var appName: String? = nil

        if let slashIdx = working.firstIndex(of: "/") {
            let candidate = String(working[working.startIndex..<slashIdx])
            // Reject "App" candidates that are actually a TYPE prefix.
            if ElementKind(rawValue: candidate.uppercased()) == nil {
                appName = candidate
                working = String(working[working.index(after: slashIdx)...])
            }
        }

        guard let colonIdx = working.firstIndex(of: ":") else { return nil }
        let typeStr = String(working[working.startIndex..<colonIdx])
        let kind = ElementKind.parse(typeStr)

        var labelPart = String(working[working.index(after: colonIdx)...])
        var index: Int? = nil

        // Strip trailing @N. The label itself may contain '@', so anchor to last.
        if let atIdx = labelPart.lastIndex(of: "@") {
            let afterAt = labelPart[labelPart.index(after: atIdx)...]
            if let n = Int(afterAt) {
                index = n
                labelPart = String(labelPart[labelPart.startIndex..<atIdx])
            }
        }

        return ParsedRef(
            appName: appName, kind: kind, labelBase: labelPart, index: index
        )
    }
}

// MARK: - Compressed Snapshot

public struct RefGroup: Sendable {
    /// (kind, labelBase) — the unique grouping key.
    public let kind: ElementKind
    public let labelBase: String

    /// Indices encountered for this group (e.g. [1, 2, 3] from @1 @2 @3).
    /// Empty when there is exactly one element with no @N suffix.
    public let indices: [Int]

    /// True when the original ref was a single un-suffixed entry.
    public let singleton: Bool
}

public struct CompressedSnapshot: Sendable {
    public let appName: String
    public let totalRefs: Int
    public let groups: [RefGroup]
    public let summary: String?
    /// Pagination info — nil means all refs shown (no pagination).
    public let pageInfo: PageInfo?
}

public struct PageInfo: Sendable {
    public let page: Int       // 0-indexed
    public let pageSize: Int
    public let totalRefs: Int
    public let totalPages: Int
}

// MARK: - Compressor
//
// Run-length / set compression of refs by (kind, labelBase). Lossless: every
// original ref can still be reconstructed and looked up by callers.

public enum UISnapshotCompressor {
    public static func compress(
        appName: String,
        refs: [String],
        summary: String?,
        pageInfo: PageInfo? = nil
    ) -> CompressedSnapshot {
        var orderedKeys: [String] = []
        var byKey: [String: (kind: ElementKind, label: String, indices: [Int], singleton: Bool)] = [:]

        for ref in refs {
            guard let parsed = ParsedRef.parse(ref) else { continue }
            let key = "\(parsed.kind.rawValue)\u{1F}\(parsed.labelBase)"

            if byKey[key] == nil {
                orderedKeys.append(key)
                byKey[key] = (
                    kind: parsed.kind,
                    label: parsed.labelBase,
                    indices: [],
                    singleton: parsed.index == nil
                )
            }
            if let idx = parsed.index {
                byKey[key]!.indices.append(idx)
                byKey[key]!.singleton = false
            }
        }

        let groups: [RefGroup] = orderedKeys.map { key in
            let g = byKey[key]!
            return RefGroup(
                kind: g.kind,
                labelBase: g.label,
                indices: g.indices.sorted(),
                singleton: g.singleton && g.indices.isEmpty
            )
        }

        return CompressedSnapshot(
            appName: appName,
            totalRefs: pageInfo?.totalRefs ?? refs.count,
            groups: groups,
            summary: summary,
            pageInfo: pageInfo
        )
    }
}

// MARK: - Diff

public struct SnapshotChange: Sendable {
    public let added: [String]
    public let removed: [String]

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
}

public actor UISnapshotCache {
    private var lastRefsByApp: [String: [String]] = [:]

    public init() {}

    public func recordAndDiff(
        appName: String,
        currentRefs: [String]
    ) -> SnapshotChange? {
        let prev = lastRefsByApp[appName]
        lastRefsByApp[appName] = currentRefs
        guard let prev else { return nil }

        let prevSet = Set(prev)
        let currSet = Set(currentRefs)
        return SnapshotChange(
            added: Array(currSet.subtracting(prevSet)),
            removed: Array(prevSet.subtracting(currSet))
        )
    }

    public func reset(appName: String) {
        lastRefsByApp.removeValue(forKey: appName)
    }

    public func resetAll() {
        lastRefsByApp.removeAll()
    }
}

// MARK: - Formatter
//
// Sole owner of the human-/LLM-readable output format. Both CDP and AX
// snapshots flow through this single path.

public enum UISnapshotFormatter {
    public static func format(
        _ snapshot: CompressedSnapshot,
        change: SnapshotChange? = nil
    ) -> String {
        var lines: [String] = ["[\(snapshot.appName)]"]

        if let s = snapshot.summary, !s.isEmpty {
            lines.append(s)
        }

        if let c = change, !c.isEmpty {
            lines.append("")
            lines.append("Changes since last call: +\(c.added.count) -\(c.removed.count)")
        }

        if snapshot.groups.isEmpty {
            if snapshot.summary == nil {
                lines.append("(no elements)")
            }
            return lines.joined(separator: "\n")
        }

        lines.append("")
        if let pi = snapshot.pageInfo {
            let from = pi.page * pi.pageSize + 1
            let to = min(from + pi.pageSize - 1, pi.totalRefs)
            lines.append("=== Refs \(from)-\(to) of \(pi.totalRefs) (page \(pi.page + 1)/\(pi.totalPages)) ===")
        } else {
            lines.append("=== Refs (\(snapshot.totalRefs)) ===")
        }
        for g in snapshot.groups {
            lines.append("  " + formatGroup(g))
        }

        return lines.joined(separator: "\n")
    }

    private static func formatGroup(_ g: RefGroup) -> String {
        let prefix = "\(g.kind.rawValue):\(g.labelBase)"

        if g.singleton {
            return prefix
        }
        if g.indices.isEmpty {
            return prefix
        }
        if g.indices.count == 1 {
            return "\(prefix)@\(g.indices[0])"
        }

        let first = g.indices.first!
        let last = g.indices.last!
        let isContiguous = (last - first) == (g.indices.count - 1)

        if isContiguous {
            return "\(prefix)@\(first)..@\(last) (\(g.indices.count))"
        }

        // Non-contiguous: show first 8 + count.
        let head = g.indices.prefix(8).map { "@\($0)" }.joined(separator: ",")
        let suffix = g.indices.count > 8 ? ",... (\(g.indices.count) total)" : " (\(g.indices.count))"
        return "\(prefix)\(head)\(suffix)"
    }
}
