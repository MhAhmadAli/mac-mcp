import AppKit

/// Which apps the server may control: only ones the user allowed, never the blocked ones.
enum Policy {
    static let configURL = homeDirectory.appendingPathComponent(".mac-mcp/config.json")

    /// Respects $HOME, which homeDirectoryForCurrentUser ignores.
    private static var homeDirectory: URL {
        ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Apps that could be used to take over the Mac or read secrets. They can't be allowed.
    static let blockedBundleIDs: Set<String> = [
        "com.apple.systempreferences",
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "dev.warp.warp-stable",
        "com.apple.keychainaccess",
        "com.apple.passwords",
        "com.apple.scripteditor2",
        "com.apple.automator",
        "com.apple.shortcuts",
        "com.apple.activitymonitor",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
    ]

    private struct Config: Codable {
        var allowedApps: [String] = []
    }

    static func isBlocked(_ bundleID: String) -> Bool {
        blockedBundleIDs.contains(bundleID.lowercased())
    }

    /// Read on every call, so edits to the config apply without a restart.
    static func allowedApps() -> [String] {
        loadConfig().allowedApps
    }

    static func isAllowed(_ bundleID: String) -> Bool {
        !isBlocked(bundleID)
            && allowedApps().contains { $0.lowercased() == bundleID.lowercased() }
    }

    static func requireAllowed(bundleID: String?, name: String) throws {
        guard let bundleID else {
            throw ToolError("\(name) has no bundle ID, so it can't be allowed.")
        }
        if isBlocked(bundleID) {
            throw ToolError("\(name) (\(bundleID)) is blocked: it could be used to take over the Mac.")
        }
        if !isAllowed(bundleID) {
            throw ToolError(
                "\(name) isn't allowed. To allow it, the user runs: mac-mcp allow \(bundleID)")
        }
    }

    static func allow(_ bundleID: String) throws {
        if isBlocked(bundleID) {
            throw ToolError("\(bundleID) is blocked and can't be allowed.")
        }
        var config = loadConfig()
        if !config.allowedApps.contains(where: { $0.lowercased() == bundleID.lowercased() }) {
            config.allowedApps.append(bundleID)
        }
        try saveConfig(config)
    }

    static func disallow(_ bundleID: String) throws {
        var config = loadConfig()
        config.allowedApps.removeAll { $0.lowercased() == bundleID.lowercased() }
        try saveConfig(config)
    }

    private static func loadConfig() -> Config {
        guard let data = try? Data(contentsOf: configURL),
            let config = try? JSONDecoder().decode(Config.self, from: data)
        else {
            return Config()
        }
        return config
    }

    private static func saveConfig(_ config: Config) throws {
        let directory = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }
}
