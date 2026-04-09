import Foundation

/// Executes JavaScript in browser tabs via AppleScript.
/// Supports Arc, Chrome, Safari, Edge, Brave — no CDP connection needed.
/// Runs in background without stealing focus.
final class BrowserBridge: @unchecked Sendable {

    // MARK: - Browser Detection

    private static let browserBundleIDs: [String: BrowserType] = [
        "company.thebrowser.Browser": .arc,
        "com.google.Chrome": .chrome,
        "com.google.Chrome.canary": .chrome,
        "com.apple.Safari": .safari,
        "com.microsoft.edgemac": .chrome,     // Edge uses Chrome syntax
        "com.brave.Browser": .chrome,          // Brave uses Chrome syntax
    ]

    enum BrowserType {
        case arc
        case chrome
        case safari
    }

    static func browserType(bundleID: String?) -> BrowserType? {
        guard let bid = bundleID else { return nil }
        return browserBundleIDs[bid]
    }

    static func isBrowser(bundleID: String?) -> Bool {
        browserType(bundleID: bundleID) != nil
    }

    // MARK: - JavaScript Execution

    /// Execute JavaScript in the active tab of a browser.
    /// Returns the JS result as a string, or nil on failure.
    static func executeJS(appName: String, bundleID: String?, script: String) -> String? {
        guard let type = browserType(bundleID: bundleID) else { return nil }

        let escapedScript = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let appleScript: String
        switch type {
        case .arc:
            appleScript = """
                tell application "\(appName)"
                    tell front window
                        tell active tab
                            set jsResult to execute javascript "\(escapedScript)"
                        end tell
                    end tell
                end tell
                return jsResult
                """
        case .chrome:
            appleScript = """
                tell application "\(appName)"
                    tell active tab of front window
                        set jsResult to execute javascript "\(escapedScript)"
                    end tell
                end tell
                return jsResult
                """
        case .safari:
            appleScript = """
                tell application "\(appName)"
                    set jsResult to do JavaScript "\(escapedScript)" in current tab of front window
                end tell
                return jsResult
                """
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return output
        } catch {
            return nil
        }
    }

    // MARK: - Click by AX Ref

    /// Click a web element by matching its AX label to DOM textContent.
    /// Maps AX short roles to CSS selectors for precise matching.
    static func clickByRef(
        appName: String,
        bundleID: String?,
        refRole: String,
        label: String
    ) -> Bool {
        let escapedLabel = label
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\\", with: "\\\\")

        // Map AX short role to CSS selector
        let selector: String
        switch refRole {
        case "LINK":    selector = "a"
        case "BUTTON":  selector = "button, [role='button']"
        case "INPUT":   selector = "input"
        case "TEXTAREA": selector = "textarea"
        case "HEADING": selector = "h1, h2, h3, h4, h5, h6"
        case "CHECKBOX": selector = "input[type='checkbox']"
        case "SELECT":  selector = "select"
        default:        selector = "*"
        }

        let script = """
            (function() {
                const els = document.querySelectorAll('\(selector)');
                for (const el of els) {
                    const text = el.textContent.trim();
                    if (text === '\(escapedLabel)') {
                        el.click();
                        return 'clicked';
                    }
                }
                // Fallback: partial match
                for (const el of els) {
                    const text = el.textContent.trim();
                    if (text.includes('\(escapedLabel)')) {
                        el.click();
                        return 'clicked-partial';
                    }
                }
                return 'not-found';
            })()
            """

        let result = executeJS(appName: appName, bundleID: bundleID, script: script)
        return result?.contains("clicked") == true
    }
}
