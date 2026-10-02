import AppKit

private let snapshots = SnapshotStore()

private let appProperty: JSON = [
    "type": "string", "description": "App name or bundle ID, as listed by list_apps",
]
private let refProperty: JSON = [
    "type": "string", "description": "Exact element ref from the latest snapshot of the app",
]
private let elementProperty: JSON = [
    "type": "string",
    "description": "Human-readable element description, used to ask the user for permission",
]

func makeTools() -> [Tool] {
    [
        Tool(
            name: "list_apps",
            description: "List running apps and whether each one may be controlled. Only apps the user has allowed can be used.",
            inputSchema: schema([:]),
            handle: { _ in listApps() }
        ),
        Tool(
            name: "open_app",
            description: "Open (or bring to the front) an allowed app",
            inputSchema: schema(["app": appProperty], required: ["app"]),
            handle: openApp
        ),
        Tool(
            name: "snapshot",
            description: "Capture the accessibility tree of an app's windows. Use it to get refs for the elements to interact with.",
            inputSchema: schema(["app": appProperty], required: ["app"]),
            handle: { args in
                let app = try allowedApp(args)
                return .text(snapshotText(app))
            }
        ),
        Tool(
            name: "click",
            description: "Click an element, such as a button, checkbox or list item",
            inputSchema: schema(
                ["app": appProperty, "element": elementProperty, "ref": refProperty],
                required: ["app", "element", "ref"]),
            handle: click
        ),
        Tool(
            name: "type",
            description: "Type text into a text field, replacing its current content",
            inputSchema: schema(
                [
                    "app": appProperty, "element": elementProperty, "ref": refProperty,
                    "text": ["type": "string", "description": "Text to type"],
                    "submit": ["type": "boolean", "description": "Whether to press Return afterwards"],
                ], required: ["app", "element", "ref", "text"]),
            handle: type
        ),
        Tool(
            name: "press_key",
            description: "Press a key or shortcut in an app, such as \"return\", \"escape\" or \"cmd+s\"",
            inputSchema: schema(
                [
                    "app": appProperty,
                    "key": [
                        "type": "string",
                        "description": "Key name or character, with modifiers joined by +, like \"cmd+shift+t\"",
                    ],
                ], required: ["app", "key"]),
            handle: { args in
                let app = try allowedApp(args)
                let key = try stringArgument(args, "key")
                try Input.activate(app)
                try Input.press(key, pid: app.processIdentifier)
                return afterAction("Pressed \(key)", app: app)
            }
        ),
        Tool(
            name: "scroll",
            description: "Scroll an element, or the app's main window",
            inputSchema: schema(
                [
                    "app": appProperty,
                    "ref": ["type": "string", "description": "Element to scroll; defaults to the main window"],
                    "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                    "amount": ["type": "integer", "description": "Lines to scroll (default 5)"],
                ], required: ["app", "direction"]),
            handle: scroll
        ),
        Tool(
            name: "select_menu_item",
            description: "Choose an item from the app's menu bar, such as [\"File\", \"Save\"] or [\"Format\", \"Font\", \"Bold\"]",
            inputSchema: schema(
                [
                    "app": appProperty,
                    "path": [
                        "type": "array", "items": ["type": "string"],
                        "description": "Menu titles from the menu bar down to the item",
                    ],
                ], required: ["app", "path"]),
            handle: selectMenuItem
        ),
        Tool(
            name: "screenshot",
            description: "Take a screenshot of the app's frontmost window",
            inputSchema: schema(["app": appProperty], required: ["app"]),
            handle: { args in
                let app = try allowedApp(args)
                let png: String
                do {
                    png = try Screenshot.capture(app)
                } catch let error as ToolError {
                    throw error
                } catch {
                    throw ToolError(
                        "Couldn't take a screenshot (\(error.localizedDescription)). macOS may need Screen Recording access for the app that runs this server, in System Settings › Privacy & Security › Screen & System Audio Recording."
                    )
                }
                return ToolResult(content: [["type": "image", "data": .string(png), "mimeType": "image/png"]])
            }
        ),
    ]
}

// MARK: - Handlers

private func listApps() -> ToolResult {
    let apps = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular }
        .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    let lines = apps.map { app in
        let bundleID = app.bundleIdentifier ?? "no bundle ID"
        let status =
            Policy.isBlocked(bundleID) ? "blocked" : Policy.isAllowed(bundleID) ? "allowed" : "not allowed"
        let isFrontmost = Accessibility.applicationElement(app).bool(kAXFrontmostAttribute) == true
        return "- \(app.localizedName ?? bundleID) (\(bundleID)) [\(status)]"
            + (isFrontmost ? " [frontmost]" : "")
    }
    return .text(
        lines.joined(separator: "\n")
            + "\n\nOnly allowed apps can be controlled. The user allows one by running: mac-mcp allow <bundle ID>"
    )
}

private func openApp(_ args: JSON) throws -> ToolResult {
    let query = try stringArgument(args, "app")
    guard let url = findApplication(query), let bundleID = Bundle(url: url)?.bundleIdentifier else {
        throw ToolError("Couldn't find an app named \"\(query)\".")
    }
    try Policy.requireAllowed(bundleID: bundleID, name: url.deletingPathExtension().lastPathComponent)
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    let app = try blocking {
        try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
    // Give it time to open a window before the next snapshot
    usleep(1_000_000)
    return .text("Opened \(app.localizedName ?? query).")
}

private func click(_ args: JSON) throws -> ToolResult {
    let app = try allowedApp(args)
    let element = try snapshots.element(for: stringArgument(args, "ref"), in: app)
    if element.actionNames.contains(kAXPressAction) {
        try element.perform(kAXPressAction)
    } else {
        guard let frame = element.frame, frame.width > 0, frame.height > 0 else {
            throw ToolError("That element can't be pressed and isn't visible on screen.")
        }
        try Input.activate(app)
        Input.click(at: CGPoint(x: frame.midX, y: frame.midY))
    }
    return afterAction("Clicked \(describe(args))", app: app)
}

private func type(_ args: JSON) throws -> ToolResult {
    let app = try allowedApp(args)
    let element = try snapshots.element(for: stringArgument(args, "ref"), in: app)
    guard let text = args["text"]?.string else {
        throw ToolError("Missing \"text\".")
    }
    try? element.set(kAXFocusedAttribute, to: kCFBooleanTrue)
    if !element.isSecureTextField, element.isSettable(kAXValueAttribute) {
        try element.set(kAXValueAttribute, to: text as CFString)
    } else {
        try Input.activate(app)
        try Input.press("cmd+a", pid: app.processIdentifier)
        try Input.type(text, pid: app.processIdentifier)
    }
    if args["submit"]?.bool == true {
        try Input.press("return", pid: app.processIdentifier)
    }
    return afterAction("Typed text into \(describe(args))", app: app)
}

private func scroll(_ args: JSON) throws -> ToolResult {
    let app = try allowedApp(args)
    let amount = Int32(args["amount"]?.number ?? 5)
    let (dx, dy): (Int32, Int32)
    switch args["direction"]?.string {
    case "up": (dx, dy) = (0, amount)
    case "down": (dx, dy) = (0, -amount)
    case "left": (dx, dy) = (amount, 0)
    case "right": (dx, dy) = (-amount, 0)
    default: throw ToolError("\"direction\" must be up, down, left or right.")
    }
    let target =
        try args["ref"]?.string.map { try snapshots.element(for: $0, in: app) }
        ?? Accessibility.applicationElement(app).element(kAXMainWindowAttribute)
    guard let frame = target?.frame, frame.width > 0, frame.height > 0 else {
        throw ToolError("Nothing visible to scroll.")
    }
    try Input.activate(app)
    Input.scroll(at: CGPoint(x: frame.midX, y: frame.midY), dx: dx, dy: dy)
    return afterAction("Scrolled \(args["direction"]?.string ?? "")", app: app)
}

private func selectMenuItem(_ args: JSON) throws -> ToolResult {
    let app = try allowedApp(args)
    let path = (args["path"]?.array ?? []).compactMap(\.string)
    guard !path.isEmpty else {
        throw ToolError("\"path\" must list the menu titles, like [\"File\", \"Save\"].")
    }
    guard let menuBar = Accessibility.applicationElement(app).element(kAXMenuBarAttribute) else {
        throw ToolError("\(app.localizedName ?? "The app") has no menu bar.")
    }
    var item = menuBar
    for (depth, title) in path.enumerated() {
        // A menu bar item or submenu item holds a menu, whose children are the items
        let items = depth == 0 ? menuBar.children : (item.children.first?.children ?? [])
        guard let match = items.first(where: {
            $0.string(kAXTitleAttribute)?.caseInsensitiveCompare(title) == .orderedSame
        }) else {
            let available = items.compactMap { $0.string(kAXTitleAttribute) }.filter { !$0.isEmpty }
            throw ToolError(
                "No menu item \"\(title)\". Available: \(available.map { "\"\($0)\"" }.joined(separator: ", "))")
        }
        item = match
    }
    if item.bool(kAXEnabledAttribute) == false {
        throw ToolError("\"\(path.joined(separator: " › "))\" is disabled.")
    }
    try item.perform(kAXPressAction)
    return afterAction("Chose \(path.joined(separator: " › "))", app: app)
}

// MARK: - Helpers

private func schema(_ properties: [String: JSON], required: [String] = []) -> JSON {
    [
        "type": "object",
        "properties": .object(properties),
        "required": .array(required.map { .string($0) }),
        "additionalProperties": false,
    ]
}

private func stringArgument(_ args: JSON, _ key: String) throws -> String {
    guard let value = args[key]?.string, !value.isEmpty else {
        throw ToolError("Missing \"\(key)\".")
    }
    return value
}

private func describe(_ args: JSON) -> String {
    args["element"]?.string.map { "\"\($0)\"" } ?? "the element"
}

/// The running app named in the arguments, if the user allowed it.
private func allowedApp(_ args: JSON) throws -> NSRunningApplication {
    let query = try stringArgument(args, "app")
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    guard
        let app = apps.first(where: { $0.bundleIdentifier?.caseInsensitiveCompare(query) == .orderedSame })
            ?? apps.first(where: { $0.localizedName?.caseInsensitiveCompare(query) == .orderedSame })
    else {
        throw ToolError("No running app named \"\(query)\". Use list_apps to see running apps, or open_app to start one.")
    }
    try Policy.requireAllowed(bundleID: app.bundleIdentifier, name: app.localizedName ?? query)
    try Accessibility.requireTrust()
    return app
}

private func snapshotText(_ app: NSRunningApplication) -> String {
    """
    - App: \(app.localizedName ?? "") (\(app.bundleIdentifier ?? ""))
    - Snapshot
    ```yaml
    \(snapshots.capture(app))
    ```
    """
}

/// Actions return a fresh snapshot, so the refs stay current.
private func afterAction(_ message: String, app: NSRunningApplication) -> ToolResult {
    // Let the app update its interface first
    usleep(500_000)
    return .text("\(message)\n\n\(snapshotText(app))")
}

/// Finds an installed app by bundle ID or name.
func findApplication(_ query: String) -> URL? {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) {
        return url
    }
    let name = query.hasSuffix(".app") ? query : "\(query).app"
    let folders = [
        "/Applications", "/Applications/Utilities", "/System/Applications",
        "/System/Applications/Utilities",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
    ]
    return folders.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
        .first { FileManager.default.fileExists(atPath: $0.path) }
}
