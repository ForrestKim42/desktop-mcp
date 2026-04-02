import AppKit
import Foundation

// MARK: - Interaction Method

/// The layer used to interact with a macOS application.
enum InteractionMethod: Sendable {
    case accessibility
    case applescript
    case cgevent
    case screenshot
}

// MARK: - App Category

/// Classification of an app based on its technology stack and scripting support.
enum AppCategory: Sendable {
    /// Has an AppleScript dictionary (scriptable via `sdef`).
    case scriptable
    /// Chromium-based (Electron). Limited Accessibility support, no AppleScript.
    case electron
    /// Standard native macOS app with good Accessibility support.
    case nativeStandard
    /// Unknown technology stack.
    case unknown
}

// MARK: - Router

/// Routes operations to the best available interaction layer for a given
/// app and action.
///
/// Phase 2 implementation selects the optimal method based on:
/// - The action being performed (snapshot, click, type, menu, script, find)
/// - The target app's category (scriptable, Electron, native, unknown)
/// - Known bundle-ID lists for scriptable and Electron apps
final class Router: Sendable {

    // MARK: - Known Bundle IDs

    /// macOS apps that expose an AppleScript dictionary.
    private static let scriptableBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.Safari",
        "com.apple.mail",
        "com.apple.Notes",
        "com.apple.iWork.Keynote",
        "com.apple.iWork.Numbers",
        "com.apple.iWork.Pages",
        "com.apple.dt.Xcode",
        "com.apple.iMovie",
        "com.apple.garageband",
        "com.apple.MobileSMS",
        "com.apple.ical",
        "com.apple.reminders",
        "com.apple.Music",
    ]

    /// Electron / Chromium-based apps with limited AX and no AppleScript.
    private static let electronBundleIDs: Set<String> = [
        "com.hnc.Discord",
        "com.microsoft.VSCode",
        "com.tinyspeck.slackmacgap",
        "org.whispersystems.signal-desktop",
        "com.spotify.client",
    ]

    // MARK: - App Categorization

    /// Classify an app by its bundle ID, with optional `sdef` detection fallback.
    ///
    /// The lookup order is:
    /// 1. Check the static Electron set (these must never use AppleScript).
    /// 2. Check the static scriptable set.
    /// 3. Attempt dynamic `sdef` detection for unknown bundle IDs.
    /// 4. Fall back to `.nativeStandard` for Apple first-party apps,
    ///    `.unknown` otherwise.
    ///
    /// - Parameters:
    ///   - bundleID: The bundle identifier, if known.
    ///   - appName: The display name (used as a heuristic when bundle ID is nil).
    /// - Returns: The inferred `AppCategory`.
    func categorize(bundleID: String?, appName: String) -> AppCategory {
        guard let id = bundleID else {
            return .unknown
        }

        if Self.electronBundleIDs.contains(id) {
            return .electron
        }

        if Self.scriptableBundleIDs.contains(id) {
            return .scriptable
        }

        if hasSdefDictionary(bundleID: id) {
            return .scriptable
        }

        if id.hasPrefix("com.apple.") {
            return .nativeStandard
        }

        return .unknown
    }

    // MARK: - App-level Routing

    /// Determine the best general interaction method for an app.
    ///
    /// - Parameters:
    ///   - appName: The display name of the target application.
    ///   - bundleID: The bundle identifier, if known.
    /// - Returns: The recommended interaction method.
    func bestMethod(appName: String, bundleID: String?) -> InteractionMethod {
        let category = categorize(bundleID: bundleID, appName: appName)

        switch category {
        case .scriptable:
            return .applescript
        case .electron:
            return .accessibility
        case .nativeStandard:
            return .accessibility
        case .unknown:
            return .accessibility
        }
    }

    // MARK: - Action-level Routing

    /// Determine the best method for a specific operation on an app.
    ///
    /// Routing rules by action:
    /// - `snapshot` / `read` / `find` -- Accessibility (only method that reads UI state)
    /// - `click` -- Accessibility (AXPress is more precise than coordinate clicking)
    /// - `type` -- CGEvent for most apps (more reliable), Accessibility for Electron
    /// - `menu` -- Accessibility (menu bar traversal)
    /// - `script` -- AppleScript for scriptable apps, Accessibility otherwise
    ///
    /// - Parameters:
    ///   - action: The action being performed (e.g. "click", "type", "snapshot").
    ///   - appName: The display name of the target application.
    ///   - bundleID: The bundle identifier, if known.
    /// - Returns: The recommended interaction method.
    func bestMethodForAction(
        action: String,
        appName: String,
        bundleID: String?
    ) -> InteractionMethod {
        let normalized = action.lowercased()
        let category = categorize(bundleID: bundleID, appName: appName)

        switch normalized {
        case "snapshot", "read", "find":
            return .accessibility

        case "click":
            return .accessibility

        case "type":
            return routeTyping(category: category)

        case "menu":
            return .accessibility

        case "script":
            return routeScripting(category: category)

        default:
            return bestMethod(appName: appName, bundleID: bundleID)
        }
    }

    // MARK: - Capability Check

    /// Check whether a given method is available on this system.
    ///
    /// All methods are available in Phase 2.
    ///
    /// - Parameter method: The interaction method to check.
    /// - Returns: `true` if the method can be used.
    func isAvailable(_ method: InteractionMethod) -> Bool {
        return true
    }

    // MARK: - Private Helpers

    /// Pick the best method for typing text into the given app category.
    ///
    /// CGEvent is generally more reliable for keystroke injection, but
    /// Electron apps sometimes swallow raw key events, so Accessibility
    /// (AXSetValue) is safer there.
    private func routeTyping(category: AppCategory) -> InteractionMethod {
        switch category {
        case .electron:
            return .accessibility
        case .scriptable, .nativeStandard, .unknown:
            return .cgevent
        }
    }

    /// Pick the best method for executing a script against the given app category.
    ///
    /// Only apps with an AppleScript dictionary benefit from `.applescript`;
    /// everything else falls back to Accessibility.
    private func routeScripting(category: AppCategory) -> InteractionMethod {
        switch category {
        case .scriptable:
            return .applescript
        case .electron, .nativeStandard, .unknown:
            return .accessibility
        }
    }

    /// Detect whether an app has an AppleScript dictionary via `sdef`.
    ///
    /// Shells out to `/usr/bin/sdef` with the app's bundle path resolved
    /// through `NSWorkspace`. Returns `false` on any error or if the app
    /// cannot be found.
    private func hasSdefDictionary(bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleID
        ) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sdef")
        process.arguments = [url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
