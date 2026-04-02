import ApplicationServices
import Foundation

// MARK: - Snapshot Builder

/// Builds a `PilotElement` tree from a running app's accessibility tree.
///
/// Walks the AX hierarchy starting from the app element, reads attributes
/// via `AXBridge`, and registers every meaningful element in the
/// `ElementStore` so it can be referenced later by its opaque ref.
struct SnapshotBuilder: Sendable {
    let bridge: AXBridge

    /// Attributes fetched in a single batch call per element for performance.
    private static let batchAttributes: [String] = [
        kAXRoleAttribute,
        kAXTitleAttribute,
        kAXValueAttribute,
        kAXDescriptionAttribute,
        kAXEnabledAttribute,
        kAXFocusedAttribute,
    ]

    // MARK: - Public API

    /// Build a complete snapshot of an app's UI tree.
    ///
    /// - Parameters:
    ///   - appElement: The root AXUIElement for the app (from `AXBridge.appElement`).
    ///   - appName: Display name of the application.
    ///   - bundleID: Bundle identifier (e.g. "com.apple.Safari"), if available.
    ///   - pid: Process identifier.
    ///   - store: The `ElementStore` actor that will hold ref-to-element mappings.
    ///   - maxDepth: Maximum recursion depth to prevent runaway traversal (default 10).
    /// - Returns: A fully populated `AppSnapshot`.
    func buildSnapshot(
        appElement: AXUIElement,
        appName: String,
        bundleID: String?,
        pid: Int32,
        store: ElementStore,
        maxDepth: Int = 10
    ) async -> AppSnapshot {
        await store.reset()

        let windows = bridge.getWindows(appElement)
        var topLevelElements: [PilotElement] = []

        for window in windows {
            let element = await buildElement(
                from: window,
                store: store,
                depth: 0,
                maxDepth: maxDepth
            )
            if let element {
                topLevelElements.append(element)
            }
        }

        // If no windows, try direct children of the app element
        if topLevelElements.isEmpty {
            let children = bridge.getChildren(appElement)
            for child in children {
                let element = await buildElement(
                    from: child,
                    store: store,
                    depth: 0,
                    maxDepth: maxDepth
                )
                if let element {
                    topLevelElements.append(element)
                }
            }
        }

        let count = await store.count()
        let formatter = ISO8601DateFormatter()

        return AppSnapshot(
            app: appName,
            bundleID: bundleID,
            pid: pid,
            timestamp: formatter.string(from: Date()),
            elementCount: count,
            elements: topLevelElements
        )
    }

    // MARK: - Recursive Tree Building

    /// Build a single `PilotElement` from an `AXUIElement`, recursing into children.
    ///
    /// Returns `nil` if the element has no useful information (no role, title, or value).
    private func buildElement(
        from axElement: AXUIElement,
        store: ElementStore,
        depth: Int,
        maxDepth: Int
    ) async -> PilotElement? {
        let attrs = readBatchAttributes(axElement)

        let role = attrs.role

        // Skip elements with unknown or missing roles that carry no info
        if role == nil && attrs.title == nil && attrs.value == nil && attrs.description == nil {
            return nil
        }

        // Skip explicitly unknown roles
        if role == "AXUnknown" {
            return nil
        }

        let wrapper = AXElementWrapper(axElement)
        let ref = await store.register(wrapper)
        let bounds = bridge.getBounds(axElement)

        // Recurse into children if within depth limit
        var childElements: [PilotElement]?
        if depth < maxDepth {
            let axChildren = bridge.getChildren(axElement)
            if !axChildren.isEmpty {
                var built: [PilotElement] = []
                for child in axChildren {
                    if let childElement = await buildElement(
                        from: child,
                        store: store,
                        depth: depth + 1,
                        maxDepth: maxDepth
                    ) {
                        built.append(childElement)
                    }
                }
                childElements = built.isEmpty ? nil : built
            }
        }

        return PilotElement(
            ref: ref,
            role: role ?? "AXUnknown",
            title: attrs.title,
            value: attrs.value,
            description: attrs.description,
            enabled: attrs.enabled,
            focused: attrs.focused,
            bounds: bounds,
            children: childElements
        )
    }

    // MARK: - Batch Attribute Reading

    /// Holds the parsed result of a batch attribute read.
    private struct BatchResult {
        let role: String?
        let title: String?
        let value: String?
        let description: String?
        let enabled: Bool
        let focused: Bool
    }

    /// Read all standard attributes in one batch call for performance.
    private func readBatchAttributes(_ element: AXUIElement) -> BatchResult {
        let values = bridge.getAttributes(element, Self.batchAttributes)

        let role = values[0] as? String
        let title = values[1] as? String

        // Value needs special handling: could be String, NSNumber, etc.
        let value: String? = {
            guard let raw = values[2] else { return nil }
            if let str = raw as? String { return str }
            if let num = raw as? NSNumber { return num.stringValue }
            return String(describing: raw)
        }()

        let description = values[3] as? String
        let enabled = (values[4] as? Bool) ?? true
        let focused = (values[5] as? Bool) ?? false

        return BatchResult(
            role: role,
            title: title,
            value: value,
            description: description,
            enabled: enabled,
            focused: focused
        )
    }
}
