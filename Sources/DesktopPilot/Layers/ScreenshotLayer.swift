import CoreGraphics
import AppKit
import Foundation

/// Screenshot fallback layer for custom-rendered content.
/// Used when Accessibility API can't see UI elements (game viewports, canvas, etc.).
final class ScreenshotLayer: @unchecked Sendable {

    private let bridge: AXBridge
    private let store: ElementStore

    init(bridge: AXBridge, store: ElementStore) {
        self.bridge = bridge
        self.store = store
    }

    // MARK: - Full Screen Screenshot

    /// Capture the entire main display.
    func captureFullScreen() -> Data? {
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else { return nil }
        return pngData(from: image)
    }

    // MARK: - Region Screenshot

    /// Capture a specific screen region.
    func captureRegion(x: Double, y: Double, width: Double, height: Double) -> Data? {
        let rect = CGRect(x: x, y: y, width: width, height: height)
        guard let image = CGDisplayCreateImage(CGMainDisplayID(), rect: rect) else { return nil }
        return pngData(from: image)
    }

    // MARK: - Element Screenshot

    /// Capture the bounds of a specific element (resolved from ref via AXBridge).
    func captureElement(bounds: ElementBounds) -> Data? {
        return captureRegion(
            x: bounds.x, y: bounds.y,
            width: bounds.width, height: bounds.height
        )
    }

    // MARK: - Window Screenshot

    /// Capture a specific window by its windowID.
    func captureWindow(windowID: CGWindowID) -> Data? {
        let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        )
        guard let image else { return nil }
        return pngData(from: image)
    }

    // MARK: - PNG Encoding

    private func pngData(from cgImage: CGImage) -> Data? {
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .png, properties: [:])
    }

    // MARK: - Base64 Encoding

    /// Capture and return as base64 string (for MCP image responses).
    func captureFullScreenBase64() -> String? {
        guard let data = captureFullScreen() else { return nil }
        return data.base64EncodedString()
    }

    func captureRegionBase64(x: Double, y: Double, width: Double, height: Double) -> String? {
        guard let data = captureRegion(x: x, y: y, width: width, height: height) else { return nil }
        return data.base64EncodedString()
    }

    func captureElementBase64(bounds: ElementBounds) -> String? {
        guard let data = captureElement(bounds: bounds) else { return nil }
        return data.base64EncodedString()
    }
}

// MARK: - InteractionLayer Conformance

extension ScreenshotLayer: InteractionLayer {
    var name: String { "Screenshot" }
    var priority: Int { 50 } // Lowest priority -- last resort

    func canHandle(bundleID: String?, appName: String) -> Bool {
        return true // Can always take screenshots
    }

    func snapshot(pid: Int32, maxDepth: Int) throws -> [PilotElement] {
        // Screenshots can't provide structured UI trees
        throw LayerError.notSupported(
            layer: name,
            reason: "Screenshot layer cannot provide structured snapshots. Use pilot_screenshot tool instead."
        )
    }

    func click(ref: String) throws {
        throw LayerError.notSupported(
            layer: name,
            reason: "Screenshot layer cannot click elements. Use coordinate-based clicking via CGEvent."
        )
    }

    func typeText(ref: String, text: String) throws {
        throw LayerError.notSupported(
            layer: name,
            reason: "Screenshot layer cannot type. Use CGEvent or Accessibility layer."
        )
    }

    func readValue(ref: String) throws -> String? {
        throw LayerError.notSupported(
            layer: name,
            reason: "Screenshot layer cannot read values. Use Accessibility layer."
        )
    }
}
