# mac-mcp

An MCP server that lets AI clients control macOS apps through the Accessibility API, the way Browser MCP controls a browser tab: take a snapshot of an app's interface, then click, type and choose menu items by ref.

## Tools

| Tool | What it does |
| --- | --- |
| `list_apps` | Lists running apps and whether each may be controlled |
| `open_app` | Opens an allowed app or brings it to the front |
| `snapshot` | Captures the accessibility tree of the app's windows, with a ref for each element |
| `click` | Presses a button, checkbox, list item or other element |
| `type` | Replaces a text field's content, optionally pressing Return |
| `press_key` | Presses a key or shortcut such as `cmd+s` |
| `scroll` | Scrolls an element or the main window |
| `select_menu_item` | Chooses a menu bar item, such as `["File", "Save"]` |
| `screenshot` | Captures the app's frontmost window |

Actions return a fresh snapshot, and refs are only valid for the app's latest snapshot.

## Setup

1. Build: `swift build -c release`. The binary is `.build/release/mac-mcp`.
2. Allow the apps it may control (none are allowed by default):
   ```sh
   .build/release/mac-mcp allow TextEdit
   .build/release/mac-mcp allowed
   ```
3. Add it to your MCP client, for example in `.mcp.json`:
   ```json
   { "mcpServers": { "mac-mcp": { "command": "/path/to/mac_mcp/.build/release/mac-mcp" } } }
   ```
4. Grant permissions to the app that runs the server (for Claude Code in VS Code, Visual Studio Code) in System Settings › Privacy & Security:
   - **Accessibility**, for snapshots and actions
   - **Screen & System Audio Recording**, for screenshots

## Safety

- Only apps on the allowlist in `~/.mac-mcp/config.json` can be controlled. The AI can't change it through the tools.
- Apps that could take over the Mac or expose secrets can't be allowed at all: System Settings, Terminal and other terminals, Keychain Access, Passwords, password managers, Script Editor, Automator, Shortcuts and Activity Monitor.
- Password field values are never included in snapshots.
- App content goes to the AI as is, so a document or web page can try to give it instructions. Only allow the apps you need.
