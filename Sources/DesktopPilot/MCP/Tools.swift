import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Tool Registry

/// Registers the unified `desktop_do` tool and dispatches all actions.
public final class PilotToolHandler: ToolHandler, @unchecked Sendable {

    private let bridge: AXBridge
    private let store: ElementStore
    private let registry: AppRegistry
    private let snapshotBuilder: SnapshotBuilder
    private let cdpSnapshotBuilder: CDPSnapshotBuilder
    private let screenshotLayer: ScreenshotLayer
    private let cgEventLayer: CGEventLayer

    /// Active CDP connections keyed by app name.
    private var cdpConnections: [String: CDPBridge] = [:]

    public init(bridge: AXBridge, store: ElementStore) {
        self.bridge = bridge
        self.store = store
        self.registry = AppRegistry()
        self.snapshotBuilder = SnapshotBuilder(bridge: bridge)
        self.cdpSnapshotBuilder = CDPSnapshotBuilder()
        self.screenshotLayer = ScreenshotLayer(bridge: bridge, store: store)
        self.cgEventLayer = CGEventLayer(bridge: bridge, store: store)
    }

    public func listTools() -> [ToolDefinition] {
        [desktopDoTool]
    }

    public func callTool(name: String, arguments: JSONValue?) async throws -> MCPToolResult {
        switch name {
        case "desktop_do":
            return await handleDesktopDo(arguments)
        default:
            return .error("Unknown tool: \(name)")
        }
    }

    // MARK: - Tool Definition

    private var desktopDoTool: ToolDefinition {
        ToolDefinition(
            name: "desktop_do",
            description: """
                Control any macOS app via accessibility. Call without actions to read the screen. \
                Call with actions to execute them and get the updated screen state.

                Element IDs use App/TYPE:Label format (e.g. Arc/BUTTON:Save, Finder/IMAGE:data). \
                Duplicates get @N suffix (Arc/BUTTON:OK@1, Arc/BUTTON:OK@2). \
                You can omit the app prefix to target the default app.

                Cross-app batching: each action can target a different app by including the app prefix. \
                Example: ["tap Arc/BUTTON:New Tab", "tap Finder/IMAGE:data"]

                Actions (string or JSON array of strings):
                  tap Arc/BUTTON:Save      — click element (app prefix optional)
                  type hello world         — type text into focused element
                  type Arc/INPUT:URL test  — type into specific element in specific app
                  press RETURN             — press key (RETURN, TAB, ESCAPE, DELETE, SPACE, arrows)
                  press CMD+A              — hotkey combo (CMD/SHIFT/ALT/CTRL + key)
                  wait 2000                — pause N milliseconds
                  screenshot               — capture full screen (returns base64)
                  screenshot /path.png     — capture to file
                  scroll down 3            — scroll direction + pixel amount
                  menu File > Save         — activate menu item
                  apps                     — list running applications

                Examples:
                  desktop_do()                                     — read frontmost app
                  desktop_do(app: "Arc")                           — read Arc's screen
                  desktop_do(actions: "tap BUTTON:Save")           — single action on frontmost
                  desktop_do(actions: ["tap Arc/INPUT:URL", "type https://example.com", "press RETURN"])
                  desktop_do(actions: ["tap Arc/BUTTON:Copy", "tap 메모/BUTTON:붙여넣기"])  — cross-app
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Default app name or bundle ID. Omit for frontmost app. "
                            + "Individual actions can override with App/TYPE:Label prefix."
                        ),
                    ]),
                    "actions": .object([
                        "description": .string(
                            "Action string or JSON array of action strings. Omit to just read the screen."
                        ),
                        "oneOf": .array([
                            .object(["type": .string("string")]),
                            .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")])
                            ]),
                        ]),
                    ]),
                ]),
                "required": .array([]),
            ])
        )
    }

    // MARK: - Main Handler

    private func handleDesktopDo(_ arguments: JSONValue?) async -> MCPToolResult {
        guard bridge.isAccessibilityEnabled() else {
            return .error(
                "Accessibility permission not granted. "
                + "Go to System Settings > Privacy & Security > Accessibility "
                + "and add this application."
            )
        }

        let appName = arguments?.stringValue(forKey: "app")
        let actionsInput: JSONValue? = {
            guard case .object(let dict) = arguments else { return nil }
            return dict["actions"]
        }()

        guard let defaultApp = resolveApp(appName) else {
            return .error("Could not find app: \(appName ?? "frontmost"). Is it running?")
        }

        // Take initial snapshot of default app
        await takeSnapshot(app: defaultApp)

        // If no actions, just return the screen state
        guard let actionStrings = ActionParser.parseActions(actionsInput), !actionStrings.isEmpty else {
            let screenText = await formatScreen(app: defaultApp)
            return .success(screenText)
        }

        // Execute actions sequentially
        var output: [String] = []
        var currentDefaultApp = defaultApp

        for actionStr in actionStrings {
            guard let action = ActionParser.parse(actionStr) else {
                output.append("> \(actionStr)\n  ERROR: unrecognized action")
                continue
            }

            let result = await executeAction(
                action,
                rawString: actionStr,
                defaultApp: &currentDefaultApp
            )
            output.append(result)
        }

        // Take final snapshot and append screen state
        await takeSnapshot(app: currentDefaultApp)
        let screenState = await formatScreen(app: currentDefaultApp)

        output.append("---")
        output.append(screenState)

        return .success(output.joined(separator: "\n"))
    }

    // MARK: - Action Execution

    private func executeAction(
        _ action: ParsedAction,
        rawString: String,
        defaultApp: inout (name: String, pid: Int32)
    ) async -> String {
        switch action {
        case .tap(let target):
            return await executeTap(target: target, defaultApp: &defaultApp)

        case .type(let text):
            return await executeType(text: text, defaultApp: &defaultApp)

        case .press(let key):
            return executePress(key: key)

        case .wait(let ms):
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            return "> wait \(ms)"

        case .screenshot(let path):
            return executeScreenshot(path: path)

        case .scroll(let direction, let amount):
            return executeScroll(direction: direction, amount: amount)

        case .menu(let path):
            return await executeMenu(path: path, app: defaultApp)

        case .listApps:
            return executeListApps()
        }
    }

    /// Resolve the target app from an element ref like "Arc/BUTTON:Save".
    /// If the ref has an app prefix, switch to that app and snapshot it if needed.
    /// Returns the resolved (app, elementRef) tuple.
    private func resolveTargetApp(
        from target: String,
        defaultApp: inout (name: String, pid: Int32)
    ) async -> (app: (name: String, pid: Int32), elementRef: String)? {
        // Check if target has an app prefix
        if let appName = ElementStore.extractApp(from: target) {
            let elementRef = ElementStore.stripApp(from: target)

            // If this is a different app, resolve and snapshot it
            if let app = resolveApp(appName) {
                if !(await store.isSnapshotted(app.name)) {
                    await takeSnapshot(app: app)
                }
                return (app, elementRef)
            } else {
                return nil // App not found
            }
        }

        // No app prefix — use default app
        return (defaultApp, target)
    }

    private func executeTap(
        target: String,
        defaultApp: inout (name: String, pid: Int32)
    ) async -> String {
        guard let resolved = await resolveTargetApp(from: target, defaultApp: &defaultApp) else {
            return "> tap \(target)\n  ERROR: app not found"
        }

        guard let wrapper = await store.resolve(target, defaultApp: resolved.app.name) else {
            return "> tap \(target)\n  ERROR: element not found"
        }

        // Activate the target app first
        activateApp(pid: resolved.app.pid)

        // Check if this is a CDP element (DOM index based)
        let fullRef = target.contains("/") ? target : "\(resolved.app.name)/\(resolved.elementRef)"
        if let domIndex = await CDPElementHolder.shared.resolve(ref: fullRef),
           domIndex >= 0,
           let cdp = cdpConnections[resolved.app.name] {
            do {
                let script = CDPSnapshotBuilder.clickScript(index: domIndex)
                let result = try await cdp.sendCommand("Runtime.evaluate", params: [
                    "expression": script,
                    "returnByValue": true
                ])
                if let res = result["result"] as? [String: Any],
                   let val = res["value"] as? String,
                   val.contains("\"ok\":true") {
                    return "> tapped \(target) (CDP)"
                }
                return "> tap \(target)\n  ERROR: CDP click returned unexpected result"
            } catch {
                return "> tap \(target)\n  ERROR: CDP click failed: \(error)"
            }
        }

        // AXPress (semantic click)
        let success = bridge.performAction(wrapper.element, kAXPressAction)
        if success {
            return "> tapped \(target)"
        }

        // Fallback: CGEvent coordinate click
        if let bounds = bridge.getBounds(wrapper.element) {
            cgEventLayer.clickElement(bounds: bounds)
            return "> tapped \(target) (via coordinates)"
        }

        return "> tap \(target)\n  ERROR: click failed"
    }

    private func executeType(
        text: String,
        defaultApp: inout (name: String, pid: Int32)
    ) async -> String {
        // Try to split "ref actualText" — ref may contain spaces (e.g. "Slack/INPUT:김선태(Forrest Kim) hello")
        // Strategy: try matching against known refs in the store, longest match first
        if let (possibleRef, actualText) = await splitRefAndText(text, defaultApp: defaultApp) {
            if let resolved = await resolveTargetApp(from: possibleRef, defaultApp: &defaultApp) {
                activateApp(pid: resolved.app.pid)

                // Check CDP path first
                let fullRef = possibleRef.contains("/") ? possibleRef : "\(resolved.app.name)/\(possibleRef)"
                if let domIndex = await CDPElementHolder.shared.resolve(ref: fullRef),
                   domIndex >= 0,
                   let cdp = cdpConnections[resolved.app.name] {
                    do {
                        let setScript = CDPSnapshotBuilder.setValueScript(index: domIndex, value: actualText)
                        let setResult = try await cdp.sendCommand("Runtime.evaluate", params: [
                            "expression": setScript,
                            "returnByValue": true
                        ])

                        if let res = setResult["result"] as? [String: Any],
                           let val = res["value"] as? String,
                           val.contains("\"contenteditable\":true") {
                            _ = try await cdp.sendCommand("Input.insertText", params: [
                                "text": actualText
                            ])
                        }

                        return "> typed \"\(actualText)\" into \(possibleRef) (CDP)"
                    } catch {
                        return "> type \(possibleRef)\n  ERROR: CDP type failed: \(error)"
                    }
                }

                // AX path
                if let wrapper = await store.resolve(possibleRef, defaultApp: resolved.app.name) {
                    _ = bridge.setAttribute(wrapper.element, kAXFocusedAttribute, true as CFTypeRef)

                    let success = bridge.setAttribute(
                        wrapper.element, kAXValueAttribute, actualText as CFTypeRef
                    )
                    if success {
                        return "> typed \"\(actualText)\" into \(possibleRef)"
                    }

                    cgEventLayer.typeString(actualText)
                    return "> typed \"\(actualText)\" into \(possibleRef) (via keyboard)"
                }
            }
        }

        // Plain text — type into whatever is focused
        cgEventLayer.typeString(text)
        return "> typed \"\(text)\""
    }

    private func executePress(key: String) -> String {
        guard let resolved = ActionParser.resolveKey(key) else {
            return "> press \(key)\n  ERROR: unknown key"
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: resolved.keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: resolved.keyCode, keyDown: false)

        let flags = CGEventFlags(rawValue: resolved.flags)
        keyDown?.flags = flags
        keyUp?.flags = flags

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        return "> pressed \(key)"
    }

    private func executeScreenshot(path: String?) -> String {
        guard let data = screenshotLayer.captureFullScreen() else {
            return "> screenshot\n  ERROR: capture failed (check Screen Recording permission)"
        }

        if let path {
            let url = URL(fileURLWithPath: path)
            do {
                try data.write(to: url)
                return "> screenshot saved to \(path)"
            } catch {
                return "> screenshot\n  ERROR: failed to save to \(path): \(error)"
            }
        }

        let base64 = data.base64EncodedString()
        let preview = String(base64.prefix(100))
        return "> screenshot captured (\(data.count) bytes, base64: \(preview)...)"
    }

    private func executeScroll(direction: String, amount: Int) -> String {
        let (deltaY, deltaX): (Int32, Int32) = {
            switch direction.lowercased() {
            case "up":    return (Int32(amount), 0)
            case "down":  return (Int32(-amount), 0)
            case "left":  return (0, Int32(amount))
            case "right": return (0, Int32(-amount))
            default:      return (Int32(-amount), 0)
            }
        }()

        cgEventLayer.scroll(deltaY: deltaY, deltaX: deltaX)
        return "> scrolled \(direction) \(amount)"
    }

    private func executeMenu(path: String, app: (name: String, pid: Int32)) async -> String {
        let pathComponents = path
            .components(separatedBy: " > ")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        activateApp(pid: app.pid)
        let appElement = bridge.appElement(pid: app.pid)
        let success = bridge.navigateMenu(appElement, path: pathComponents)

        if success {
            return "> menu \(path)"
        }
        return "> menu \(path)\n  ERROR: menu item not found"
    }

    private func executeListApps() -> String {
        var apps = registry.listApps()
        if bridge.isAccessibilityEnabled() {
            apps = apps.map { registry.enrichWithWindowCount($0, bridge: bridge) }
        }

        var lines = ["> Running apps:"]
        for app in apps {
            let bid = app.bundleID ?? "?"
            lines.append("  \(app.name) (\(bid)) pid=\(app.pid) windows=\(app.windowCount)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Snapshot & Formatting

    @discardableResult
    private func takeSnapshot(app: (name: String, pid: Int32)) async -> AppSnapshot {
        let appInfo = registry.findApp(pid: app.pid)
        let bundleID = appInfo?.bundleID

        // Check if this is an Electron app with CDP available
        if CDPBridge.isElectronApp(bundleID: bundleID, pid: app.pid) {
            if let cdp = cdpConnections[app.name] {
                // Already connected — use CDP
                return await takeCDPSnapshot(cdp: cdp, app: app, bundleID: bundleID)
            }

            // Try to find and connect to CDP
            if let port = await CDPBridge.findCDPPort(for: bundleID, pid: app.pid) {
                let cdp = CDPBridge(port: port)
                do {
                    try await cdp.connect()
                    cdpConnections[app.name] = cdp
                    Log.info("CDP connected to \(app.name) on port \(port)")
                    return await takeCDPSnapshot(cdp: cdp, app: app, bundleID: bundleID)
                } catch {
                    Log.info("CDP connection failed for \(app.name): \(error). Falling back to AX.")
                }
            }
        }

        // Default: macOS AX API
        let appElement = bridge.appElement(pid: app.pid)
        return await snapshotBuilder.buildSnapshot(
            appElement: appElement,
            appName: app.name,
            bundleID: bundleID,
            pid: app.pid,
            store: store,
            maxDepth: 100
        )
    }

    private func takeCDPSnapshot(
        cdp: CDPBridge,
        app: (name: String, pid: Int32),
        bundleID: String?
    ) async -> AppSnapshot {
        do {
            return try await cdpSnapshotBuilder.buildSnapshot(
                cdp: cdp,
                appName: app.name,
                bundleID: bundleID,
                pid: app.pid,
                store: store
            )
        } catch {
            Log.error("CDP DOM snapshot failed: \(error). Falling back to AX.")
            let appElement = bridge.appElement(pid: app.pid)
            return await snapshotBuilder.buildSnapshot(
                appElement: appElement,
                appName: app.name,
                bundleID: bundleID,
                pid: app.pid,
                store: store,
                maxDepth: 100
            )
        }
    }

    /// Format screen state. For CDP apps, returns the smart summary.
    /// For native AX apps, returns the flat element list.
    private func formatScreen(app: (name: String, pid: Int32)) async -> String {
        // CDP apps: use pre-built summary
        if let summary = await CDPElementHolder.shared.getSummary(appName: app.name) {
            return "[\(app.name)]\n\(summary)"
        }

        // AX apps: flat list
        let refs = await store.refsForApp(app.name)
        if refs.isEmpty {
            return "[\(app.name)] No accessible elements found."
        }

        var lines = ["[\(app.name)] \(refs.count) elements:"]
        for ref in refs {
            lines.append("  \(ref)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - App Resolution & Activation

    private func resolveApp(_ appName: String?) -> (name: String, pid: Int32)? {
        if let appName = appName {
            if let info = registry.findApp(name: appName) {
                return (info.name, info.pid)
            }
            return nil
        }
        if let info = registry.frontmostApp() {
            return (info.name, info.pid)
        }
        return nil
    }

    /// Bring an app to the foreground.
    private func activateApp(pid: Int32) {
        let app = NSRunningApplication(processIdentifier: pid)
        app?.activate()
    }

    /// Split "ref text" where ref may contain spaces.
    /// Matches against known refs in the store to find the boundary.
    private func splitRefAndText(
        _ input: String,
        defaultApp: (name: String, pid: Int32)
    ) async -> (ref: String, text: String)? {
        // Must contain ":" to be a ref
        guard input.contains(":") else { return nil }

        let allRefs = await store.allRefs()

        // Try matching against known refs (longest match wins)
        for ref in allRefs {
            if input.hasPrefix(ref + " ") {
                let textStart = input.index(input.startIndex, offsetBy: ref.count + 1)
                return (ref, String(input[textStart...]))
            }
        }

        // Try without app prefix: match "TYPE:Label text" against store
        let defaultPrefix = defaultApp.name + "/"
        for ref in allRefs {
            if ref.hasPrefix(defaultPrefix) {
                let shortRef = String(ref.dropFirst(defaultPrefix.count))
                if input.hasPrefix(shortRef + " ") {
                    let textStart = input.index(input.startIndex, offsetBy: shortRef.count + 1)
                    return (shortRef, String(input[textStart...]))
                }
            }
        }

        // Fallback: simple first-space split, but only if first token contains ":"
        let parts = input.split(separator: " ", maxSplits: 1)
        if parts.count == 2 {
            let possibleRef = String(parts[0])
            if possibleRef.contains(":") {
                return (possibleRef, String(parts[1]))
            }
        }

        return nil
    }
}
