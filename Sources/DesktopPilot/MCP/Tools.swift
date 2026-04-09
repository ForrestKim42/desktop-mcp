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

    /// Next CDP port to allocate when restarting an Electron app.
    /// Each Electron app gets its own port to avoid collisions.
    private var nextCDPPort: Int = 9222

    /// Apps where CDP restart was already attempted (success or fail).
    /// Prevents repeated restart loops within a single session.
    private var cdpRestartAttempted: Set<String> = []

    /// Per-app snapshot cache for diff computation.
    private let snapshotCache = UISnapshotCache()

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
                Control any macOS app via accessibility using a path grammar.

                A path is a `/`-joined sequence of segments. Segments are either
                an app name, a ref (TYPE:Label[@N]), or a verb (tap, type:<text>,
                press:<key>, find:<query>, expect:<name>, wait:<ms>, scroll:<dir>).

                A trailing `?` dumps the end-state view for that path; a trailing `!`
                returns assert-only; no marker means silent ok-or-error. Input is a
                JSON array of paths, output is one result block per path.

                Examples:
                  desktop_do(paths: ["Slack?"])                          — read Slack
                  desktop_do(paths: ["Slack/message_container@2?"])      — focus one message
                  desktop_do(paths: ["Slack/find:닫기/tap"])              — search and act
                  desktop_do(paths: [
                    "Slack/channel-sidebar-channel:alpha-room/tap",
                    "Slack/Input:message_input/type:안녕/press:RETURN?"
                  ])                                                     — batched flow

                The full grammar and design rationale lives in docs/PATH_API.md.
                Duplicates get @N suffix (Arc/BUTTON:OK@1, Arc/BUTTON:OK@2).
                Omitting the app prefix targets the default app (see `app` param).
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Default app name or bundle ID. Omit for frontmost app. "
                            + "A path's first segment can override this per-path."
                        ),
                    ]),
                    "window": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Target window title. When set, only this window gets a full-depth snapshot "
                            + "and interactions target it — even if it's behind other windows. "
                            + "Other windows are listed by title only. Enables background interaction."
                        ),
                    ]),
                    "paths": .object([
                        "description": .string(
                            "Array of path strings. Each path is evaluated independently and returns "
                            + "one view. Omit to read the default app at its root."
                        ),
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([]),
            ])
        )
    }

    // MARK: - Main Handler
    //
    // The single tool entrypoint. A batch of paths in, an array of view blocks
    // out. Path grammar lives in `PathParser.swift`; per-verb execution below.

    private func handleDesktopDo(_ arguments: JSONValue?) async -> MCPToolResult {
        guard bridge.isAccessibilityEnabled() else {
            return .error(
                "Accessibility permission not granted. "
                + "Go to System Settings > Privacy & Security > Accessibility "
                + "and add this application."
            )
        }

        let defaultAppName = arguments?.stringValue(forKey: "app")
        let windowName = arguments?.stringValue(forKey: "window")
        let pathStrings = arguments?.stringArrayValue(forKey: "paths") ?? []

        var currentDefault: (name: String, pid: Int32)? = resolveApp(defaultAppName)

        // Take the initial snapshot up front so a bare read call stays cheap.
        if let app = currentDefault {
            await takeSnapshot(app: app, focusWindowTitle: windowName)
        }

        // Empty `paths` → behave like a read of the default app's root.
        if pathStrings.isEmpty {
            guard let app = currentDefault else {
                return .error(
                    "Could not find app: \(defaultAppName ?? "frontmost"). Is it running?"
                )
            }
            return .success(await formatScreen(app: app))
        }

        // Evaluate each path independently, collecting one view block per path.
        var outputs: [String] = []
        for raw in pathStrings {
            let parsed = PathParser.parse(raw)
            let block = await executePath(
                parsed,
                defaultApp: &currentDefault,
                windowName: windowName
            )
            outputs.append(block)
        }

        return .success(outputs.joined(separator: "\n\n==========\n\n"))
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

        // NOTE: Do NOT activate the app by default — allows background interaction
        // without stealing focus from the user's current work.

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

        // WINDOW element → raise via System Events (brings window to front)
        let isWindow = resolved.elementRef.hasPrefix("WINDOW:") ||
                       bridge.getRole(wrapper.element) == "AXWindow"
        if isWindow {
            // Try AXRaise first — fast, no System Events overhead
            bridge.performAction(wrapper.element, kAXRaiseAction)
            activateApp(pid: resolved.app.pid)

            // Fallback: System Events for apps where AXRaise doesn't work
            let windowTitle = bridge.getTitle(wrapper.element) ?? ""
            let appName = resolved.app.name
            let helper = SystemEventsHelper()

            let escapedTitle = windowTitle
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let escapedApp = appName
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")

            let script = """
                tell application "System Events"
                    tell process "\(escapedApp)"
                        set frontmost to true
                        repeat with w in windows
                            if name of w is "\(escapedTitle)" then
                                perform action "AXRaise" of w
                                return "ok"
                            end if
                        end repeat
                        return "not found"
                    end tell
                end tell
                """

            // Use short timeout to avoid blocking on apps with many windows
            let _ = helper.runAppleScript(script, timeout: 5)
            return "> tapped \(target) (window raised)"
        }

        // Browser web content: use AppleScript JS injection (no focus steal, real DOM events).
        // Extract ref role and label from the element ref (e.g. "LINK:View all@1").
        let refRole = resolved.elementRef.split(separator: ":").first.map(String.init) ?? ""
        let refLabelRaw = resolved.elementRef.split(separator: ":").dropFirst().joined(separator: ":")
        let refLabel = refLabelRaw.replacingOccurrences(of: #"@\d+$"#, with: "", options: .regularExpression)

        let appInfo = registry.findApp(pid: resolved.app.pid)
        let bundleID = appInfo?.bundleID
        if BrowserBridge.isBrowser(bundleID: bundleID) && !refLabel.isEmpty {
            if BrowserBridge.clickByRef(
                appName: resolved.app.name,
                bundleID: bundleID,
                refRole: refRole,
                label: refLabel
            ) {
                return "> tapped \(target) (browser JS)"
            }
        }

        // Web content fallback: coordinate click for non-browser Electron/web apps.
        let webOnlyRefRoles: Set<String> = ["LINK", "WEB", "HEADING"]
        let isWebElement = webOnlyRefRoles.contains(refRole) || bridge.isWebContent(wrapper.element)
        if isWebElement {
            if let bounds = bridge.getBounds(wrapper.element) {
                cgEventLayer.clickElementBackground(bounds: bounds, pid: resolved.app.pid)
                return "> tapped \(target) (via coordinates)"
            }
        }

        // AXPress — works in background for native macOS apps
        let success = bridge.performAction(wrapper.element, kAXPressAction)
        if success {
            return "> tapped \(target)"
        }

        // Fallback: background coordinate click (works without raising the window)
        if let bounds = bridge.getBounds(wrapper.element) {
            cgEventLayer.clickElementBackground(bounds: bounds, pid: resolved.app.pid)
            return "> tapped \(target) (background coordinates)"
        }

        return "> tap \(target)\n  ERROR: click failed"
    }

    /// Double-click an element using CGEvent coordinates.
    private func executeDoubleTap(
        target: String,
        defaultApp: inout (name: String, pid: Int32)
    ) async -> String {
        guard let resolved = await resolveTargetApp(from: target, defaultApp: &defaultApp) else {
            return "> doubletap \(target)\n  ERROR: app not found"
        }

        guard let wrapper = await store.resolve(target, defaultApp: resolved.app.name) else {
            return "> doubletap \(target)\n  ERROR: element not found"
        }

        guard let bounds = bridge.getBounds(wrapper.element) else {
            return "> doubletap \(target)\n  ERROR: could not get element bounds"
        }

        let x = bounds.x + bounds.width / 2
        let y = bounds.y + bounds.height / 2
        cgEventLayer.doubleClickAt(x: x, y: y, pid: resolved.app.pid)
        return "> double-tapped \(target)"
    }

    /// Close a window via AXCloseButton (background, no focus steal).
    private func executeClose(
        target: String,
        defaultApp: inout (name: String, pid: Int32)
    ) async -> String {
        guard let resolved = await resolveTargetApp(from: target, defaultApp: &defaultApp) else {
            return "> close \(target)\n  ERROR: app not found"
        }

        guard let wrapper = await store.resolve(target, defaultApp: resolved.app.name) else {
            return "> close \(target)\n  ERROR: element not found"
        }

        // Get AXCloseButton from the window element
        if let closeRef = bridge.getAttribute(wrapper.element, kAXCloseButtonAttribute) {
            let closeBtn = closeRef as! AXUIElement
            if bridge.performAction(closeBtn, kAXPressAction) {
                return "> closed \(target)"
            }
        }

        return "> close \(target)\n  ERROR: no close button found"
    }

    private func executeType(
        text: String,
        defaultApp: inout (name: String, pid: Int32)
    ) async -> String {
        // Try to split "ref actualText" — ref may contain spaces (e.g. "Slack/INPUT:김선태(Forrest Kim) hello")
        // Strategy: try matching against known refs in the store, longest match first
        if let (possibleRef, actualText) = await splitRefAndText(text, defaultApp: defaultApp) {
            if let resolved = await resolveTargetApp(from: possibleRef, defaultApp: &defaultApp) {
                // NOTE: Do NOT activate app — background interaction

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
                           let val = res["value"] as? String {
                            if val.contains("\"method\":\"value\"") {
                                // INPUT/TEXTAREA — value was set directly
                                return "> typed \"\(actualText)\" into \(possibleRef) (CDP)"
                            } else if val.contains("\"contenteditable\":true") {
                                // contenteditable/role=textbox — use Input.insertText
                                _ = try await cdp.sendCommand("Input.insertText", params: [
                                    "text": actualText
                                ])
                                return "> typed \"\(actualText)\" into \(possibleRef) (CDP)"
                            } else {
                                return "> type \(possibleRef)\n  ERROR: element is not a text input (not INPUT/TEXTAREA/contenteditable)"
                            }
                        }

                        return "> type \(possibleRef)\n  ERROR: unexpected setValueScript result"
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

                    // CGEvent typing requires app to be frontmost
                    activateApp(pid: resolved.app.pid)
                    cgEventLayer.typeString(actualText)
                    return "> typed \"\(actualText)\" into \(possibleRef) (via keyboard, activated)"
                }
            }
        }

        // Try CDP Input.insertText on defaultApp (for typing after a CDP tap/focus)
        if let cdp = cdpConnections[defaultApp.name] {
            do {
                _ = try await cdp.sendCommand("Input.insertText", params: [
                    "text": text
                ])
                return "> typed \"\(text)\" (CDP insertText)"
            } catch {
                // CDP insertText failed, fall through to CGEvent
            }
        }

        // Last resort: CGEvent typing into whatever is focused (foreground only)
        cgEventLayer.typeString(text)
        return "> typed \"\(text)\" (CGEvent, foreground)"
    }

    private func executePress(key: String, pid: pid_t) -> String {
        guard let resolved = KeyResolver.resolve(key) else {
            return "> press \(key)\n  ERROR: unknown key"
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: resolved.keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: resolved.keyCode, keyDown: false)

        let flags = CGEventFlags(rawValue: resolved.flags)
        keyDown?.flags = flags
        keyUp?.flags = flags

        // Background delivery: target the specific app by PID
        keyDown?.postToPid(pid)
        keyUp?.postToPid(pid)

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
    private func takeSnapshot(app: (name: String, pid: Int32), focusWindowTitle: String? = nil) async -> AppSnapshot {
        let appInfo = registry.findApp(pid: app.pid)
        let bundleID = appInfo?.bundleID

        // Check if this is an Electron app with CDP available
        if CDPBridge.isElectronApp(bundleID: bundleID, pid: app.pid) {
            if let cdp = await ensureCDPConnection(
                appName: app.name, bundleID: bundleID, pid: app.pid
            ) {
                // CDP path produces DOM-level snapshots and click handling.
                // The app may have been restarted; resolve the new PID.
                let resolvedApp: (name: String, pid: Int32)
                if let updated = registry.findApp(name: app.name) {
                    resolvedApp = (updated.name, updated.pid)
                } else {
                    resolvedApp = app
                }
                return await takeCDPSnapshot(
                    cdp: cdp, app: resolvedApp, bundleID: bundleID
                )
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
            maxDepth: 100,
            focusWindowTitle: focusWindowTitle
        )
    }

    /// Resolve (or establish) a CDP connection for an Electron app.
    ///
    /// Strategy:
    /// 1. Reuse a cached connection if alive.
    /// 2. Look for an existing CDP port the app is already listening on.
    /// 3. Restart the app with `--remote-debugging-port=<allocated>` (one-time
    ///    per session) and connect to it.
    ///
    /// Returns nil only when restart fails or has already been attempted in
    /// this session — callers should fall back to AX in that case.
    private func ensureCDPConnection(
        appName: String,
        bundleID: String?,
        pid: Int32
    ) async -> CDPBridge? {
        // 1. Cached
        if let cdp = cdpConnections[appName] {
            return cdp
        }

        // 2. Discover existing CDP port (app may already be running with --remote-debugging-port)
        if let port = await CDPBridge.findCDPPort(for: bundleID, pid: pid) {
            let cdp = CDPBridge(port: port)
            do {
                try await cdp.connect()
                cdpConnections[appName] = cdp
                Log.info("CDP connected to \(appName) on existing port \(port)")
                return cdp
            } catch {
                Log.info("CDP connect to existing port \(port) failed for \(appName): \(error)")
            }
        }

        // 3. Auto-restart with CDP enabled (one attempt per app per session)
        guard let bid = bundleID, !cdpRestartAttempted.contains(appName) else {
            return nil
        }
        cdpRestartAttempted.insert(appName)

        let port = allocateFreeCDPPort()

        Log.info("Restarting \(appName) with --remote-debugging-port=\(port)")
        let restarted = await CDPBridge.restartWithCDP(
            bundleID: bid, currentPid: pid, port: port
        )
        guard restarted else {
            Log.info("Failed to restart \(appName) with CDP enabled")
            return nil
        }

        // Allow registry to pick up the new pid
        try? await Task.sleep(nanoseconds: 500_000_000)

        // restartWithCDP returned true → CDP responded on `port`. Since
        // allocateFreeCDPPort skips ports already in use, this CDP must be
        // the app we just relaunched. Connect directly.
        let cdp = CDPBridge(port: port)
        do {
            try await cdp.connect()
            cdpConnections[appName] = cdp
            Log.info("CDP connected to \(appName) on new port \(port) after restart")
            return cdp
        } catch {
            Log.info("CDP connect after restart failed for \(appName): \(error)")
            return nil
        }
    }

    /// Find an unused TCP port for CDP, starting at `nextCDPPort`.
    /// Skips ports already listened on by any process to prevent collisions
    /// between Electron apps that are already in CDP mode.
    private func allocateFreeCDPPort() -> Int {
        var port = nextCDPPort
        while isPortListening(port) {
            port += 1
        }
        nextCDPPort = port + 1
        return port
    }

    private func isPortListening(_ port: Int) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-i", "TCP:\(port)", "-sTCP:LISTEN", "-P", "-n"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return !data.isEmpty
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

    /// Format screen state through the unified IR pipeline.
    ///
    /// Both CDP (Electron) and AX (native) snapshots flow through the same
    /// path: Collector → ElementStore → Compressor → Formatter. The CDP-only
    /// `summary` is carried as a side-channel field on the IR.
    ///
    /// Per-app snapshot cache also produces a change diff so repeated calls
    /// against the same app advertise what moved instead of dumping the full
    /// state again.
    private func formatScreen(
        app: (name: String, pid: Int32),
        page: Int? = nil,
        pageSize: Int = 200
    ) async -> String {
        let summary = await CDPElementHolder.shared.getSummary(appName: app.name)

        let refs: [String]
        let pageInfo: PageInfo?

        if let page {
            let result = await store.refsForApp(app.name, page: page, pageSize: pageSize)
            refs = result.refs
            let totalPages = max(1, (result.total + pageSize - 1) / pageSize)
            pageInfo = PageInfo(
                page: page, pageSize: pageSize,
                totalRefs: result.total, totalPages: totalPages
            )
        } else {
            let allRefs = await store.refsForApp(app.name)
            // Auto-paginate if too many refs (> 500)
            if allRefs.count > 500 {
                let autoPageSize = 200
                refs = Array(allRefs.prefix(autoPageSize))
                let totalPages = (allRefs.count + autoPageSize - 1) / autoPageSize
                pageInfo = PageInfo(
                    page: 0, pageSize: autoPageSize,
                    totalRefs: allRefs.count, totalPages: totalPages
                )
            } else {
                refs = allRefs
                pageInfo = nil
            }
        }

        if refs.isEmpty && (summary?.isEmpty ?? true) {
            return "[\(app.name)] No accessible elements found."
        }

        let change: SnapshotChange?
        if page == nil || page == 0 {
            let allRefs = await store.refsForApp(app.name)
            change = await snapshotCache.recordAndDiff(
                appName: app.name, currentRefs: allRefs
            )
        } else {
            change = nil
        }

        let truncations = await store.truncationAnnotations(appName: app.name)

        let compressed = UISnapshotCompressor.compress(
            appName: app.name, refs: refs, summary: summary,
            pageInfo: pageInfo
        )
        var output = UISnapshotFormatter.format(compressed, change: change)

        if !truncations.isEmpty {
            output += "\n\n=== Truncated lists ==="
            for t in truncations {
                output += "\n" + t
            }
        }

        return output
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

    // MARK: - Path Execution
    //
    // Each parsed path is a linear state machine: an accumulating app context,
    // an accumulating "focus" ref, and a stream of verbs that either consume
    // the focus (tap, type, close) or produce a new focus (find, inspect).

    private func executePath(
        _ path: ParsedPath,
        defaultApp: inout (name: String, pid: Int32)?,
        windowName: String?
    ) async -> String {
        var lines: [String] = ["▶ \(path.raw)"]
        var currentApp: (name: String, pid: Int32)? = defaultApp
        var lastRef: String? = nil
        var aborted = false

        for segment in path.segments {
            if aborted { break }
            switch segment {
            case .app(let name):
                guard let app = resolveApp(name) else {
                    lines.append("  ✗ app:\(name) — not running")
                    aborted = true
                    continue
                }
                if !(await store.isSnapshotted(app.name)) {
                    await takeSnapshot(app: app, focusWindowTitle: windowName)
                }
                currentApp = app
                defaultApp = app
                lastRef = nil

            case .ref(let rawRef):
                // Ref segments just accumulate focus; a following verb consumes it.
                lastRef = rawRef

            case .verb(let name, let args):
                guard var app = currentApp else {
                    lines.append("  ✗ \(name) — no app resolved")
                    aborted = true
                    continue
                }
                let outcome = await executeVerb(
                    name: name, args: args, focusedRef: lastRef, app: app
                )
                lines.append("  " + outcome.message)
                if let produced = outcome.producedRef {
                    lastRef = produced
                } else if Self.isTerminalVerb(name) {
                    lastRef = nil
                }
                if let next = outcome.nextApp {
                    app = next
                    currentApp = next
                    defaultApp = next
                }
                if outcome.failed && path.terminator == .assert {
                    aborted = true
                }
            }
        }

        // Terminator handling.
        switch path.terminator {
        case .silent:
            if !aborted { lines.append("  ✓ ok") }
            return lines.joined(separator: "\n")

        case .assert:
            lines.append(aborted ? "  ✗ FAIL" : "  ✓ ok")
            return lines.joined(separator: "\n")

        case .dump:
            guard let app = currentApp else {
                lines.append("  ✓ ok (no app to dump)")
                return lines.joined(separator: "\n")
            }
            // Let Electron/web virtual DOM settle before the final read.
            let info = registry.findApp(pid: app.pid)
            if CDPBridge.isElectronApp(bundleID: info?.bundleID, pid: app.pid) {
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            await takeSnapshot(app: app, focusWindowTitle: windowName)
            let screen = await formatScreen(app: app)
            lines.append("---")
            lines.append(screen)
            return lines.joined(separator: "\n")
        }
    }

    /// True when a verb consumes the current focus (so it should be cleared).
    private static func isTerminalVerb(_ name: String) -> Bool {
        switch name {
        case "tap", "click",
             "doubletap", "dclick", "doubleclick",
             "type", "press", "close", "menu",
             "screenshot", "scroll":
            return true
        default:
            return false
        }
    }

    /// Outcome of a single verb dispatch.
    private struct VerbOutcome {
        let message: String
        let producedRef: String?
        let nextApp: (name: String, pid: Int32)?
        let failed: Bool
    }

    /// Dispatch a single verb segment against the current app + focus.
    private func executeVerb(
        name: String,
        args: String?,
        focusedRef: String?,
        app: (name: String, pid: Int32)
    ) async -> VerbOutcome {
        var app = app
        switch name {
        case "tap", "click":
            let target = focusedRef ?? args ?? ""
            guard !target.isEmpty else {
                return VerbOutcome(
                    message: "tap — no target", producedRef: nil, nextApp: nil, failed: true
                )
            }
            let msg = await executeTap(target: target, defaultApp: &app)
            return VerbOutcome(
                message: msg, producedRef: nil, nextApp: app,
                failed: msg.contains("ERROR")
            )

        case "doubletap", "dclick", "doubleclick":
            let target = focusedRef ?? args ?? ""
            guard !target.isEmpty else {
                return VerbOutcome(
                    message: "doubletap — no target", producedRef: nil, nextApp: nil, failed: true
                )
            }
            let msg = await executeDoubleTap(target: target, defaultApp: &app)
            return VerbOutcome(
                message: msg, producedRef: nil, nextApp: app,
                failed: msg.contains("ERROR")
            )

        case "type":
            let text = args ?? ""
            let composed: String
            if let ref = focusedRef, !ref.isEmpty {
                composed = "\(ref) \(text)"
            } else {
                composed = text
            }
            let msg = await executeType(text: composed, defaultApp: &app)
            return VerbOutcome(
                message: msg, producedRef: nil, nextApp: app,
                failed: msg.contains("ERROR")
            )

        case "press":
            let key = (args ?? "").uppercased()
            let msg = executePress(key: key, pid: app.pid)
            return VerbOutcome(
                message: msg, producedRef: nil, nextApp: nil,
                failed: msg.contains("ERROR")
            )

        case "wait":
            let ms = Int(args ?? "500") ?? 500
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            return VerbOutcome(
                message: "waited \(ms)ms", producedRef: nil, nextApp: nil, failed: false
            )

        case "scroll":
            let parts = (args ?? "down").split(separator: ":").map(String.init)
            let dir = parts.first ?? "down"
            let amt = parts.count > 1 ? (Int(parts[1]) ?? 3) : 3
            let msg = executeScroll(direction: dir, amount: amt)
            return VerbOutcome(
                message: msg, producedRef: nil, nextApp: nil, failed: false
            )

        case "screenshot":
            let msg = executeScreenshot(path: args)
            return VerbOutcome(
                message: msg, producedRef: nil, nextApp: nil,
                failed: msg.contains("ERROR")
            )

        case "menu":
            let msg = await executeMenu(path: args ?? "", app: app)
            return VerbOutcome(
                message: msg, producedRef: nil, nextApp: nil,
                failed: msg.contains("ERROR")
            )

        case "close":
            let target = focusedRef ?? args ?? ""
            guard !target.isEmpty else {
                return VerbOutcome(
                    message: "close — no target", producedRef: nil, nextApp: nil, failed: true
                )
            }
            let msg = await executeClose(target: target, defaultApp: &app)
            return VerbOutcome(
                message: msg, producedRef: nil, nextApp: app,
                failed: msg.contains("ERROR")
            )

        case "apps":
            return VerbOutcome(
                message: executeListApps(), producedRef: nil, nextApp: nil, failed: false
            )

        case "find":
            let query = args ?? ""
            let (msg, first) = await executeFind(query: query, app: app)
            return VerbOutcome(
                message: msg, producedRef: first, nextApp: nil, failed: first == nil
            )

        case "expect":
            let expected = args ?? ""
            let (msg, ok) = await executeExpect(expected: expected, app: app)
            return VerbOutcome(
                message: msg, producedRef: nil, nextApp: nil, failed: !ok
            )

        case "focus", "inspect":
            let chosen = focusedRef ?? args
            return VerbOutcome(
                message: "focus \(chosen ?? "?")",
                producedRef: chosen, nextApp: nil, failed: chosen == nil
            )

        default:
            return VerbOutcome(
                message: "unknown verb: \(name)", producedRef: nil, nextApp: nil, failed: true
            )
        }
    }

    // MARK: - Path Verbs: find / expect

    /// `find:<query>` — search the CDP holder + AX store for refs whose full
    /// ref string contains `query` (case-insensitive). Returns a human-readable
    /// match list and picks the first match as the new focus so a following
    /// `tap` can chain (`find:닫기/tap`).
    private func executeFind(
        query: String,
        app: (name: String, pid: Int32)
    ) async -> (message: String, firstMatch: String?) {
        let cdp = await CDPElementHolder.shared.findByLabel(app.name, query: query)
        let ax = await store.findByLabel(app.name, query: query)

        var seen = Set<String>()
        var ordered: [String] = []
        for ref in cdp + ax where !seen.contains(ref) {
            seen.insert(ref)
            ordered.append(ref)
        }

        if ordered.isEmpty {
            return ("find:\(query) — no match", nil)
        }

        var lines = [
            "find:\(query) — \(ordered.count) match\(ordered.count == 1 ? "" : "es")"
        ]
        let shown = min(ordered.count, 10)
        for i in 0..<shown {
            lines.append("      [\(i + 1)] \(ordered[i])")
        }
        if ordered.count > shown {
            lines.append("      … (\(ordered.count - shown) more)")
        }
        return (lines.joined(separator: "\n    "), ordered.first)
    }

    /// `expect:<name>` — minimal assertion: the current CDP summary or any AX
    /// ref contains the expected token. Richer screen-signature matching can
    /// plug in later; this is enough to halt a path on clear divergence.
    private func executeExpect(
        expected: String,
        app: (name: String, pid: Int32)
    ) async -> (message: String, ok: Bool) {
        if let summary = await CDPElementHolder.shared.getSummary(appName: app.name),
           summary.contains(expected) {
            return ("expect:\(expected) — ok", true)
        }
        let matches = await store.findByLabel(app.name, query: expected)
        if !matches.isEmpty {
            return ("expect:\(expected) — ok", true)
        }
        return ("expect:\(expected) — MISMATCH", false)
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
