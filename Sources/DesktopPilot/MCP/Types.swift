import Foundation

// MARK: - UI Element Types

/// A UI element in the accessibility tree.
struct PilotElement: Codable, Sendable {
    let ref: String
    let role: String
    let title: String?
    let value: String?
    let description: String?
    let enabled: Bool
    let focused: Bool
    let bounds: ElementBounds?
    let children: [PilotElement]?

    /// Total number of children at this level (set when list was truncated).
    var totalChildren: Int? = nil
    /// Number of visible/collected children (set when list was truncated).
    var visibleChildren: Int? = nil
}

/// Screen position and size of a UI element.
struct ElementBounds: Codable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

// MARK: - App Snapshot

/// Snapshot of an app's full UI tree at a point in time.
struct AppSnapshot: Codable, Sendable {
    let app: String
    let bundleID: String?
    let pid: Int32
    let timestamp: String
    let elementCount: Int
    let elements: [PilotElement]
}

// MARK: - Action Result

/// Result of performing an action on a UI element.
struct ActionResult: Codable, Sendable {
    let success: Bool
    let message: String
    let ref: String?
}

// MARK: - App Info

/// Summary info about a running application.
struct AppInfo: Codable, Sendable {
    let name: String
    let bundleID: String?
    let pid: Int32
    let isScriptable: Bool
    let windowCount: Int
}

// MARK: - Tool Input Types

struct SnapshotInput: Codable, Sendable {
    let app: String?
    let maxDepth: Int?
}

struct ClickInput: Codable, Sendable {
    let ref: String
}

struct TypeInput: Codable, Sendable {
    let ref: String
    let text: String
}

struct ReadInput: Codable, Sendable {
    let ref: String
}

struct FindInput: Codable, Sendable {
    let role: String?
    let title: String?
    let value: String?
    let app: String?
}

struct MenuInput: Codable, Sendable {
    let path: String
    let app: String?
}

struct ScriptInput: Codable, Sendable {
    let app: String
    let code: String
    let language: String?
}

struct ScreenshotInput: Codable, Sendable {
    let ref: String?
}

struct BatchAction: Codable, Sendable {
    let tool: String
    let params: [String: String]
}

struct BatchInput: Codable, Sendable {
    let actions: [BatchAction]
}
