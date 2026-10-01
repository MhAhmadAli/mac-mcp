import AppKit
import ApplicationServices

extension AXUIElement {
    func value(_ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    func string(_ attribute: String) -> String? {
        value(attribute) as? String
    }

    func bool(_ attribute: String) -> Bool? {
        (value(attribute) as? NSNumber)?.boolValue
    }

    func element(_ attribute: String) -> AXUIElement? {
        guard let value = value(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    var role: String? { string(kAXRoleAttribute) }

    var children: [AXUIElement] {
        value(kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    var actionNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(self, &names) == .success else {
            return []
        }
        return names as? [String] ?? []
    }

    /// Position and size in screen coordinates, with the origin at the top left.
    var frame: CGRect? {
        guard let position = value(kAXPositionAttribute), let size = value(kAXSizeAttribute),
            CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else {
            return nil
        }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
        return CGRect(origin: point, size: dimensions)
    }

    var isSecureTextField: Bool {
        string(kAXSubroleAttribute) == kAXSecureTextFieldSubrole
    }

    func isSettable(_ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    func set(_ attribute: String, to value: CFTypeRef) throws {
        let result = AXUIElementSetAttributeValue(self, attribute as CFString, value)
        guard result == .success else {
            throw ToolError("Couldn't set \(attribute) (Accessibility error \(result.rawValue)).")
        }
    }

    func perform(_ action: String) throws {
        let result = AXUIElementPerformAction(self, action as CFString)
        guard result == .success else {
            throw ToolError("Couldn't perform \(action) (Accessibility error \(result.rawValue)).")
        }
    }
}

enum Accessibility {
    /// Accessibility access belongs to the app that started this server, e.g. VS Code.
    static func requireTrust() throws {
        if AXIsProcessTrusted() {
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        throw ToolError(
            "macOS hasn't granted Accessibility access. In System Settings › Privacy & Security › Accessibility, turn it on for the app that runs this server (for Claude Code in VS Code, that's Visual Studio Code), then restart that app."
        )
    }

    static func applicationElement(_ app: NSRunningApplication) -> AXUIElement {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // A hung app shouldn't hang the server
        AXUIElementSetMessagingTimeout(element, 2)
        return element
    }
}

/// Keeps the elements of each app's latest snapshot, so actions can target them by ref.
final class SnapshotStore {
    private var generation = 0
    private var latest: [pid_t: (generation: Int, elements: [AXUIElement])] = [:]

    func capture(_ app: NSRunningApplication) -> String {
        generation += 1
        var builder = SnapshotBuilder(generation: generation)
        let windows =
            Accessibility.applicationElement(app).value(kAXWindowsAttribute) as? [AXUIElement] ?? []
        if windows.isEmpty {
            builder.lines.append("(no open windows)")
        }
        for window in windows {
            builder.render(window, depth: 0, indent: "")
        }
        if builder.truncated {
            builder.lines.append("(snapshot truncated: the window has too many elements)")
        }
        latest[app.processIdentifier] = (generation, builder.elements)
        return builder.lines.joined(separator: "\n")
    }

    func element(for ref: String, in app: NSRunningApplication) throws -> AXUIElement {
        let parts = ref.trimmingCharacters(in: .whitespaces).dropFirst().split(separator: "e")
        guard ref.hasPrefix("s"), parts.count == 2, let snapshot = Int(parts[0]),
            let index = Int(parts[1])
        else {
            throw ToolError("Invalid element ref \"\(ref)\". Use a ref from the latest snapshot, like \"s3e12\".")
        }
        guard let entry = latest[app.processIdentifier], entry.generation == snapshot,
            index < entry.elements.count
        else {
            throw ToolError("That ref is from an older snapshot. Use a ref from the latest snapshot of this app.")
        }
        let element = entry.elements[index]
        guard element.role != nil else {
            throw ToolError("That element no longer exists. Take a new snapshot.")
        }
        return element
    }
}

private struct SnapshotBuilder {
    let generation: Int
    var lines: [String] = []
    var elements: [AXUIElement] = []
    var truncated = false
    private var nodeBudget = 2500

    /// Containers that add nothing unless they have a label or can be pressed.
    private static let wrapperRoles: Set<String> = [
        "AXGroup", "AXSplitGroup", "AXScrollArea", "AXLayoutArea", "AXLayoutItem", "AXUnknown",
    ]
    private static let skippedRoles: Set<String> = [
        "AXScrollBar", "AXSplitter", "AXGrowArea", "AXRuler",
    ]
    private static let maxDepth = 40
    private static let maxChildren = 300

    init(generation: Int) {
        self.generation = generation
    }

    mutating func render(_ element: AXUIElement, depth: Int, indent: String) {
        guard nodeBudget > 0 else {
            truncated = true
            return
        }
        nodeBudget -= 1

        let role = element.role ?? "AXUnknown"
        if Self.skippedRoles.contains(role) {
            return
        }
        let label = firstNonEmpty(element.string(kAXTitleAttribute), element.string(kAXDescriptionAttribute))
        let children = depth < Self.maxDepth ? element.children : []

        if role == "AXStaticText" {
            if let text = firstNonEmpty(element.string(kAXValueAttribute), label) {
                lines.append("\(indent)- text: \(clean(text))")
            }
            return
        }
        if Self.wrapperRoles.contains(role), label == nil,
            !element.actionNames.contains(kAXPressAction)
        {
            renderChildren(children, depth: depth, indent: indent)
            return
        }

        let ref = "s\(generation)e\(elements.count)"
        elements.append(element)
        var line = "\(indent)- \(displayName(role))"
        if let label {
            line += " \(quote(label))"
        }
        for attribute in attributes(element, role: role) {
            line += " [\(attribute)]"
        }
        line += " [ref=\(ref)]"

        let value = displayValue(element, role: role, label: label)
        if children.isEmpty {
            lines.append(value.map { "\(line): \($0)" } ?? line)
        } else {
            lines.append("\(line):")
            if let value {
                lines.append("\(indent)  - value: \(value)")
            }
            renderChildren(children, depth: depth, indent: indent + "  ")
        }
    }

    private mutating func renderChildren(_ children: [AXUIElement], depth: Int, indent: String) {
        for child in children.prefix(Self.maxChildren) {
            render(child, depth: depth + 1, indent: indent)
        }
        if children.count > Self.maxChildren {
            lines.append("\(indent)- (\(children.count - Self.maxChildren) more items)")
        }
    }

    private func attributes(_ element: AXUIElement, role: String) -> [String] {
        var attributes: [String] = []
        if element.bool(kAXEnabledAttribute) == false { attributes.append("disabled") }
        if element.bool(kAXFocusedAttribute) == true { attributes.append("focused") }
        if element.bool(kAXSelectedAttribute) == true { attributes.append("selected") }
        if element.bool(kAXExpandedAttribute) == true { attributes.append("expanded") }
        if role == "AXWindow" {
            if element.bool(kAXMainAttribute) == true { attributes.append("main") }
            if element.bool(kAXMinimizedAttribute) == true { attributes.append("minimized") }
        }
        if role == "AXCheckBox" || role == "AXRadioButton",
            (element.value(kAXValueAttribute) as? NSNumber)?.intValue == 1
        {
            attributes.append("checked")
        }
        return attributes
    }

    private func displayValue(_ element: AXUIElement, role: String, label: String?) -> String? {
        // macOS hides password values anyway; never show them
        if element.isSecureTextField || role == "AXCheckBox" || role == "AXRadioButton" {
            return nil
        }
        let value: String?
        switch element.value(kAXValueAttribute) {
        case let text as String: value = text
        case let number as NSNumber: value = number.stringValue
        default: value = nil
        }
        guard let value, !value.isEmpty, value != label else {
            return nil
        }
        return clean(value)
    }
}

/// "AXPopUpButton" -> "popUpButton"
private func displayName(_ role: String) -> String {
    let name = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
    return name.prefix(1).lowercased() + name.dropFirst()
}

private func firstNonEmpty(_ values: String?...) -> String? {
    values.lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
}

private func clean(_ text: String, limit: Int = 500) -> String {
    let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return collapsed.count > limit ? collapsed.prefix(limit) + "…" : collapsed
}

private func quote(_ text: String) -> String {
    let escaped = clean(text).replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}
