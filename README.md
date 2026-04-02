# Desktop Pilot MCP

Universal macOS app automation for Claude — 30-100x faster than screenshot-based computer-use.

## How It Works

Instead of taking screenshots and parsing them with vision, Desktop Pilot uses macOS native APIs to read and interact with any application's UI directly:

- **Accessibility API** (AXUIElement) — reads the structured UI tree of any app
- **AppleScript/JXA** — deep scripting for scriptable apps
- **CGEvent** — low-level, ultra-fast keyboard and mouse input
- **Screenshot fallback** — only for custom-rendered content

## Speed Comparison

| Operation | computer-use (screenshots) | Desktop Pilot | Speedup |
|-----------|---------------------------|---------------|---------|
| Read UI state | ~3000ms | ~100ms | 30x |
| Click button | ~3000ms | ~50ms | 60x |
| Type text | ~4000ms | ~20ms | 200x |
| Navigate menu | ~8000ms | ~150ms | 53x |

## Installation

### Requirements
- macOS 13.0+
- Swift 6.0+
- Accessibility permission (granted once in System Settings)

### Build from source
```bash
git clone https://github.com/VersoXBT/desktop-pilot-mcp.git
cd desktop-pilot-mcp
swift build -c release
```

### Configure with Claude Code
Add to `~/.claude.json`:
```json
{
  "mcpServers": {
    "desktop-pilot": {
      "command": "/path/to/desktop-pilot-mcp/.build/release/desktop-pilot-mcp",
      "args": []
    }
  }
}
```

## Tools

| Tool | Purpose |
|------|---------|
| `pilot_snapshot` | Get structured UI tree with element refs |
| `pilot_click` | Click element by ref |
| `pilot_type` | Type into element by ref |
| `pilot_read` | Read element value/text |
| `pilot_find` | Search elements by role, title, value |
| `pilot_menu` | Navigate menu bar directly |
| `pilot_script` | Run AppleScript/JXA |
| `pilot_batch` | Multiple actions in one call |
| `pilot_screenshot` | Visual fallback for custom content |
| `pilot_list_apps` | List running apps + capabilities |

## How It Works (Technical)

Desktop Pilot uses macOS Accessibility API to get a structured tree of every UI element in an application — buttons, text fields, menus, labels, etc. Each element gets a unique ref that Claude can use to interact with it directly, without needing to know pixel coordinates.

The Smart Router automatically picks the fastest interaction method for each app:
1. AppleScript (if the app is scriptable)
2. Accessibility API (universal, works with any standard app)
3. CGEvent (for raw keyboard/mouse input)
4. Screenshot (last resort, for custom-rendered content)

## License

MIT
