import AppKit
import ScreenCaptureKit

enum Screenshot {
    /// Captures the app's largest on-screen window as a base64 PNG, at one pixel per point.
    static func capture(_ app: NSRunningApplication) throws -> String {
        let content = try blocking {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        let windows = content.windows.filter {
            $0.owningApplication?.processID == app.processIdentifier && $0.isOnScreen
                && $0.windowLayer == 0
        }
        guard let window = windows.max(by: { area($0.frame) < area($1.frame) }) else {
            throw ToolError("\(app.localizedName ?? "The app") has no visible window to capture.")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width)
        configuration.height = Int(window.frame.height)
        configuration.showsCursor = false
        let image = try blocking {
            try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ToolError("Couldn't encode the screenshot.")
        }
        return png.base64EncodedString()
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }
}

/// Runs async work from synchronous code; requests are handled one at a time anyway.
func blocking<T>(_ operation: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error>?
    Task.detached {
        do {
            result = .success(try await operation())
        } catch {
            result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try result!.get()
}
