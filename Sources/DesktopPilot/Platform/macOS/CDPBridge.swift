import AppKit
import Foundation

// MARK: - CDP Bridge

/// Chrome DevTools Protocol bridge for Electron apps.
///
/// Connects to Electron apps via their remote debugging port and
/// provides access to the Chromium-internal accessibility tree,
/// which is far richer than what macOS AX API exposes.
///
/// Usage:
///   1. Launch Electron app with --remote-debugging-port=PORT
///   2. CDPBridge.connect(port:) to establish WebSocket
///   3. getAccessibilityTree() returns the full AX tree from Chromium
///   4. performAction() to click/type/focus elements
public final class CDPBridge: @unchecked Sendable {
    private var webSocket: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var messageId: Int = 0
    private let port: Int
    private var wsURL: String?

    public init(port: Int) {
        self.port = port
    }

    // MARK: - Connection

    /// Discover CDP targets and connect to the first page target.
    public func connect() async throws {
        // Get target list
        let listURL = URL(string: "http://localhost:\(port)/json")!
        let (data, _) = try await session.data(from: listURL)

        guard let targets = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CDPError.noTargets
        }

        // Find the first page target
        guard let target = targets.first(where: { ($0["type"] as? String) == "page" }),
              let wsDebuggerUrl = target["webSocketDebuggerUrl"] as? String else {
            // If no page type, try first target
            guard let target = targets.first,
                  let wsDebuggerUrl = target["webSocketDebuggerUrl"] as? String else {
                throw CDPError.noTargets
            }
            self.wsURL = wsDebuggerUrl
            try await connectWebSocket(wsDebuggerUrl)
            return
        }

        self.wsURL = wsDebuggerUrl
        try await connectWebSocket(wsDebuggerUrl)
    }

    private func connectWebSocket(_ urlString: String) async throws {
        guard let url = URL(string: urlString) else {
            throw CDPError.invalidURL(urlString)
        }
        let task = session.webSocketTask(with: url)
        task.resume()
        self.webSocket = task

        // Enable accessibility domain
        _ = try await sendCommand("Accessibility.enable")
        // Enable DOM domain (needed for some actions)
        _ = try await sendCommand("DOM.enable")
    }

    /// Check if CDP is available on a port.
    public static func isAvailable(port: Int) async -> Bool {
        let url = URL(string: "http://localhost:\(port)/json/version")!
        do {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 1
            let session = URLSession(configuration: config)
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - CDP Commands

    /// Send a CDP command and wait for the response.
    public func sendCommand(_ method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
        guard let ws = webSocket else { throw CDPError.notConnected }

        messageId += 1
        let id = messageId

        var msg: [String: Any] = ["id": id, "method": method]
        if let params { msg["params"] = params }

        let jsonData = try JSONSerialization.data(withJSONObject: msg)
        let jsonString = String(data: jsonData, encoding: .utf8)!

        try await ws.send(.string(jsonString))

        // Read messages until we get our response
        while true {
            let message = try await ws.receive()
            switch message {
            case .string(let text):
                guard let data = text.data(using: .utf8),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                if let responseId = json["id"] as? Int, responseId == id {
                    if let error = json["error"] as? [String: Any] {
                        let errorMsg = error["message"] as? String ?? "Unknown CDP error"
                        throw CDPError.cdpError(errorMsg)
                    }
                    return json["result"] as? [String: Any] ?? [:]
                }
                // Event or other response — skip
            case .data:
                continue
            @unknown default:
                continue
            }
        }
    }

    // MARK: - Accessibility Tree

    /// Get the full Chromium accessibility tree.
    /// Returns an array of AXNode dictionaries.
    public func getAccessibilityTree() async throws -> [[String: Any]] {
        let result = try await sendCommand("Accessibility.getFullAXTree")
        guard let nodes = result["nodes"] as? [[String: Any]] else {
            return []
        }
        return nodes
    }

    // MARK: - Actions

    /// Click an element by its backend DOM node ID.
    public func clickNode(backendNodeId: Int) async throws {
        // Get the box model to find center coordinates
        let boxResult = try await sendCommand("DOM.getBoxModel", params: [
            "backendNodeId": backendNodeId
        ])

        guard let model = boxResult["model"] as? [String: Any],
              let content = model["content"] as? [Double],
              content.count >= 4 else {
            // Fallback: try focus + Enter
            try await focusNode(backendNodeId: backendNodeId)
            _ = try await sendCommand("Input.dispatchKeyEvent", params: [
                "type": "keyDown", "key": "Enter", "code": "Enter",
                "windowsVirtualKeyCode": 13, "nativeVirtualKeyCode": 13
            ])
            _ = try await sendCommand("Input.dispatchKeyEvent", params: [
                "type": "keyUp", "key": "Enter", "code": "Enter",
                "windowsVirtualKeyCode": 13, "nativeVirtualKeyCode": 13
            ])
            return
        }

        // content is [x1,y1, x2,y2, x3,y3, x4,y4] — quad corners
        let centerX = (content[0] + content[2]) / 2.0
        let centerY = (content[1] + content[5]) / 2.0

        // Mouse click sequence
        for type in ["mousePressed", "mouseReleased"] {
            _ = try await sendCommand("Input.dispatchMouseEvent", params: [
                "type": type,
                "x": centerX,
                "y": centerY,
                "button": "left",
                "clickCount": 1
            ])
        }
    }

    /// Focus an element by backend DOM node ID.
    public func focusNode(backendNodeId: Int) async throws {
        _ = try await sendCommand("DOM.focus", params: [
            "backendNodeId": backendNodeId
        ])
    }

    /// Type text into the currently focused element.
    public func typeText(_ text: String) async throws {
        for char in text {
            _ = try await sendCommand("Input.dispatchKeyEvent", params: [
                "type": "keyDown",
                "text": String(char)
            ])
            _ = try await sendCommand("Input.dispatchKeyEvent", params: [
                "type": "keyUp",
                "text": String(char)
            ])
        }
    }

    /// Set value directly via JavaScript (more reliable for some inputs).
    public func setValue(backendNodeId: Int, value: String) async throws {
        // Resolve to a remote object
        let resolveResult = try await sendCommand("DOM.resolveNode", params: [
            "backendNodeId": backendNodeId
        ])
        guard let obj = resolveResult["object"] as? [String: Any],
              let objectId = obj["objectId"] as? String else {
            throw CDPError.cdpError("Could not resolve node")
        }

        // Set value via JS
        let escaped = value.replacingOccurrences(of: "'", with: "\\'")
        _ = try await sendCommand("Runtime.callFunctionOn", params: [
            "objectId": objectId,
            "functionDeclaration": """
                function() {
                    this.focus();
                    this.value = '\(escaped)';
                    this.dispatchEvent(new Event('input', {bubbles: true}));
                    this.dispatchEvent(new Event('change', {bubbles: true}));
                }
                """,
            "awaitPromise": false
        ])
    }

    /// Press a key (Enter, Tab, Escape, etc.)
    public func pressKey(_ key: String, code: String, keyCode: Int) async throws {
        _ = try await sendCommand("Input.dispatchKeyEvent", params: [
            "type": "keyDown",
            "key": key,
            "code": code,
            "windowsVirtualKeyCode": keyCode,
            "nativeVirtualKeyCode": keyCode
        ])
        _ = try await sendCommand("Input.dispatchKeyEvent", params: [
            "type": "keyUp",
            "key": key,
            "code": code,
            "windowsVirtualKeyCode": keyCode,
            "nativeVirtualKeyCode": keyCode
        ])
    }

    // MARK: - Disconnect

    public func disconnect() {
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
    }

    deinit {
        disconnect()
    }
}

// MARK: - CDP Node Parsing

extension CDPBridge {

    /// Parse a CDP AXNode into a structured element.
    /// CDP AXNodes have: nodeId, role, name, value, properties, childIds, backendDOMNodeId
    public static func parseNodeRole(_ node: [String: Any]) -> String? {
        guard let role = node["role"] as? [String: Any],
              let value = role["value"] as? String else { return nil }
        return value
    }

    public static func parseNodeName(_ node: [String: Any]) -> String? {
        guard let name = node["name"] as? [String: Any],
              let value = name["value"] as? String,
              !value.isEmpty else { return nil }
        return value
    }

    public static func parseNodeValue(_ node: [String: Any]) -> String? {
        guard let val = node["value"] as? [String: Any],
              let value = val["value"] as? String,
              !value.isEmpty else { return nil }
        return value
    }

    public static func parseBackendNodeId(_ node: [String: Any]) -> Int? {
        return node["backendDOMNodeId"] as? Int
    }

    public static func parseNodeId(_ node: [String: Any]) -> String? {
        return node["nodeId"] as? String
    }

    public static func parseChildIds(_ node: [String: Any]) -> [String] {
        return node["childIds"] as? [String] ?? []
    }

    public static func isIgnored(_ node: [String: Any]) -> Bool {
        return node["ignored"] as? Bool ?? false
    }

    /// Map CDP role to our short TYPE prefix.
    public static func cdpRoleToShort(_ role: String) -> String {
        switch role {
        case "button":          return "BUTTON"
        case "textbox", "searchbox", "spinbutton": return "INPUT"
        case "textarea":        return "TEXTAREA"
        case "StaticText", "text": return "TEXT"
        case "checkbox":        return "CHECKBOX"
        case "radio":           return "RADIO"
        case "combobox", "listbox": return "SELECT"
        case "menuitem":        return "MENUITEM"
        case "menu", "menubar": return "MENU"
        case "img", "image":    return "IMAGE"
        case "dialog":          return "DIALOG"
        case "heading":         return "HEADING"
        case "link":            return "LINK"
        case "list":            return "LIST"
        case "listitem":        return "LISTITEM"
        case "tab":             return "TAB"
        case "tabpanel":        return "TABPANEL"
        case "tablist":         return "TABGROUP"
        case "tree":            return "TREE"
        case "treeitem":        return "TREEITEM"
        case "row":             return "ROW"
        case "cell", "gridcell": return "CELL"
        case "table", "grid":   return "TABLE"
        case "toolbar":         return "TOOLBAR"
        case "navigation":      return "NAV"
        case "main":            return "MAIN"
        case "article":         return "ARTICLE"
        case "banner":          return "BANNER"
        case "complementary":   return "ASIDE"
        case "contentinfo":     return "FOOTER"
        case "form":            return "FORM"
        case "region", "section": return "SECTION"
        case "separator":       return "SEPARATOR"
        case "slider":          return "SLIDER"
        case "progressbar":     return "PROGRESS"
        case "switch":          return "SWITCH"
        case "alertdialog", "alert": return "ALERT"
        case "group":           return "GROUP"
        case "generic", "none", "GenericContainer": return "GROUP"
        case "RootWebArea", "WebArea": return "WEB"
        case "application":     return "APP"
        default:                return role.uppercased()
        }
    }
}

// MARK: - CDP Errors

enum CDPError: Error, LocalizedError {
    case noTargets
    case notConnected
    case invalidURL(String)
    case cdpError(String)

    var errorDescription: String? {
        switch self {
        case .noTargets: return "No CDP targets found. Is the app running with --remote-debugging-port?"
        case .notConnected: return "Not connected to CDP"
        case .invalidURL(let url): return "Invalid WebSocket URL: \(url)"
        case .cdpError(let msg): return "CDP error: \(msg)"
        }
    }
}

// MARK: - Electron Detection

extension CDPBridge {

    /// Known Electron app bundle IDs.
    private static let knownElectronBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",  // Slack
        "com.hnc.Discord",             // Discord
        "com.microsoft.VSCode",        // VS Code
        "com.microsoft.VSCodeInsiders",
        "com.spotify.client",          // Spotify
        "com.figma.Desktop",           // Figma
        "md.obsidian",                 // Obsidian
        "com.github.GitHubClient",     // GitHub Desktop
        "com.linear",                  // Linear
        "com.notion.Notion",           // Notion
        "com.bitwarden.desktop",       // Bitwarden
        "com.1password.1password",     // 1Password
        "ru.keepcoder.Telegram",       // Telegram
    ]

    /// Check if an app is likely Electron by bundle ID or by inspecting the bundle.
    public static func isElectronApp(bundleID: String?, pid: Int32? = nil) -> Bool {
        if let bid = bundleID, knownElectronBundleIDs.contains(bid) {
            return true
        }

        // Check the app bundle for Electron Framework
        if let bid = bundleID,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            let frameworkPath = appURL
                .appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
            return FileManager.default.fileExists(atPath: frameworkPath.path)
        }

        return false
    }

    /// Find the CDP port owned by a specific process.
    ///
    /// Uses `lsof` to discover which TCP ports the target PID is listening on,
    /// then verifies each with a CDP handshake. Falls back to scanning common
    /// ports with PID verification via `/json/version` User-Agent.
    public static func findCDPPort(for bundleID: String?, pid: Int32) async -> Int? {
        // Strategy 1: lsof — find ports the target PID actually listens on
        if let port = findListeningCDPPort(pid: pid) {
            if await isAvailable(port: port) {
                return port
            }
        }

        // Strategy 2: scan common ports, but verify ownership via PID
        let ports = [9222, 9229, 9223, 9224, 9225]
        for port in ports {
            if isOwnedByPid(port: port, pid: pid) {
                return port
            }
        }
        return nil
    }

    /// Use `lsof` to find TCP ports a given PID is listening on.
    private static func findListeningCDPPort(pid: Int32) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-i", "TCP", "-sTCP:LISTEN", "-P", "-n", "-p", "\(pid)", "-Fn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        // lsof -Fn outputs lines like "n*:9222" or "n127.0.0.1:9222"
        for line in output.components(separatedBy: "\n") {
            guard line.hasPrefix("n") else { continue }
            let addr = String(line.dropFirst()) // strip "n" prefix
            if let colonIdx = addr.lastIndex(of: ":") {
                let portStr = String(addr[addr.index(after: colonIdx)...])
                if let port = Int(portStr), port >= 1024 {
                    return port
                }
            }
        }
        return nil
    }

    /// Check if a CDP port is owned by the given PID by inspecting `lsof`.
    private static func isOwnedByPid(port: Int, pid: Int32) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-i", "TCP:\(port)", "-sTCP:LISTEN", "-P", "-n", "-Fp"]
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
        guard let output = String(data: data, encoding: .utf8) else { return false }

        // lsof -Fp outputs lines like "p12910"
        for line in output.components(separatedBy: "\n") {
            guard line.hasPrefix("p") else { continue }
            let pidStr = String(line.dropFirst())
            if let ownerPid = Int32(pidStr), ownerPid == pid {
                return true
            }
        }
        return false
    }
}
