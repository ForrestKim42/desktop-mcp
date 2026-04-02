import DesktopPilot

let bridge = AXBridge()
let store = ElementStore()

// Log accessibility status but never prompt (prompting blocks when spawned by MCP clients)
if !bridge.isAccessibilityEnabled() {
    Log.info(
        "Accessibility permission not yet granted. "
        + "Tools will return errors until permission is granted. "
        + "Go to System Settings > Privacy & Security > Accessibility."
    )
}

let toolHandler = PilotToolHandler(bridge: bridge, store: store)
let server = MCPServer(toolHandler: toolHandler)

await server.run()
