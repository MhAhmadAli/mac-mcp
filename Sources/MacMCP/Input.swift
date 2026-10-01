import AppKit
import CoreGraphics

/// Synthetic keyboard and mouse input.
enum Input {
    private static let source = CGEventSource(stateID: .hidSystemState)

    /// macOS virtual key codes (US layout).
    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "backspace": 51, "escape": 53,
        "esc": 53, "delete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "arrowleft": 123, "arrowright": 124, "arrowdown": 125, "arrowup": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    private static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "meta": .maskCommand,
        "shift": .maskShift,
        "option": .maskAlternate, "opt": .maskAlternate, "alt": .maskAlternate,
        "ctrl": .maskControl, "control": .maskControl,
    ]

    /// Presses a key or combination such as "cmd+s" or "shift+tab".
    static func press(_ combo: String, pid: pid_t) throws {
        let parts = combo.lowercased().split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let keyName = parts.last, let keyCode = keyCodes[keyName] else {
            throw ToolError(
                "Unknown key \"\(combo)\". Use a name like \"return\", \"tab\", \"down\" or a character, with modifiers like \"cmd+s\"."
            )
        }
        var flags: CGEventFlags = []
        for name in parts.dropLast() {
            guard let flag = modifiers[name] else {
                throw ToolError("Unknown modifier \"\(name)\". Use cmd, shift, option or ctrl.")
            }
            flags.insert(flag)
        }
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
            event?.flags = flags
            event?.postToPid(pid)
        }
    }

    /// Types text as keystrokes, so the app sees it as typed.
    static func type(_ text: String, pid: pid_t) throws {
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 {
                try press("return", pid: pid)
            }
            let units = Array(line.utf16)
            // Events carry at most 20 UTF-16 units each
            for start in stride(from: 0, to: units.count, by: 20) {
                let chunk = Array(units[start..<min(start + 20, units.count)])
                for keyDown in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                    event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    event?.postToPid(pid)
                }
                usleep(5000)
            }
        }
    }

    static func click(at point: CGPoint) {
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            usleep(20000)
        }
    }

    /// Scrolls the window under `point`, by lines.
    static func scroll(at point: CGPoint, dx: Int32, dy: Int32) {
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        let event = CGEvent(
            scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        event?.location = point
        event?.post(tap: .cghidEventTap)
    }

    /// Brings the app to the front, as mouse input goes to whatever is under the cursor.
    ///
    /// Uses Accessibility both ways: a background process can't activate other apps
    /// with NSRunningApplication, whose state also only refreshes on a run loop.
    static func activate(_ app: NSRunningApplication) throws {
        let element = Accessibility.applicationElement(app)
        if element.bool(kAXFrontmostAttribute) == true {
            return
        }
        try? element.set(kAXFrontmostAttribute, to: kCFBooleanTrue)
        for _ in 0..<20 where element.bool(kAXFrontmostAttribute) != true {
            usleep(50000)
        }
        guard element.bool(kAXFrontmostAttribute) == true else {
            throw ToolError("Couldn't bring \(app.localizedName ?? "the app") to the front.")
        }
    }
}
