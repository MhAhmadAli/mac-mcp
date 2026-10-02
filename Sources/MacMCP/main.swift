import AppKit

let version = "0.1.0"

let usage = """
    Usage:
      mac-mcp                    Run the MCP server (started by your MCP client)
      mac-mcp allow <app>        Let the server control an app (name or bundle ID)
      mac-mcp disallow <app>     Stop the server from controlling an app
      mac-mcp allowed            List the allowed apps
    """

/// Resolves an app name like "TextEdit" to its bundle ID, so either can be given.
func bundleID(for query: String) -> String {
    findApplication(query).flatMap { Bundle(url: $0)?.bundleIdentifier } ?? query
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch (arguments.first, arguments.count) {
    case (nil, _):
        if isatty(STDIN_FILENO) != 0 {
            log("mac-mcp is running and waiting for an MCP client on stdin. It's meant to be started by your MCP client. Press Ctrl+C to stop.\n\n\(usage)")
        }
        // Connects to the window server, which screen capture needs; no Dock icon
        NSApplication.shared.setActivationPolicy(.prohibited)
        MCPServer(name: "mac-mcp", version: version, tools: makeTools()).run()
    case ("allow", 2):
        let id = bundleID(for: arguments[1])
        try Policy.allow(id)
        print("Allowed \(id)")
    case ("disallow", 2):
        let id = bundleID(for: arguments[1])
        try Policy.disallow(id)
        print("Disallowed \(id)")
    case ("allowed", 1):
        let apps = Policy.allowedApps()
        print(apps.isEmpty ? "No apps are allowed yet." : apps.joined(separator: "\n"))
    default:
        print(usage)
        exit(arguments.first == "--help" || arguments.first == "-h" ? 0 : 1)
    }
} catch {
    log(error.localizedDescription)
    exit(1)
}
