import ApplicationServices
import Foundation

// MARK: - Snapshot Builder

/// Builds a `PilotElement` tree from a running app's accessibility tree.
///
/// Walks the AX hierarchy starting from the app element, reads attributes
/// via `AXBridge`, and registers every meaningful element in the
/// `ElementStore` with `App/TYPE:Label` refs.
struct SnapshotBuilder: Sendable {
    let bridge: AXBridge

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
    /// Elements are registered in the store with `appName/TYPE:Label` refs.
    func buildSnapshot(
        appElement: AXUIElement,
        appName: String,
        bundleID: String?,
        pid: Int32,
        store: ElementStore,
        maxDepth: Int = 10
    ) async -> AppSnapshot {
        // Reset only this app's elements (preserve other apps)
        await store.resetApp(appName)

        let windows = bridge.getWindows(appElement)
        var topLevelElements: [PilotElement] = []

        for (index, window) in windows.enumerated() {
            // Frontmost window (index 0): full depth snapshot
            // Background windows: title only (depth 0) for fast discovery
            let depthForWindow = (index == 0) ? maxDepth : 0
            let element = await buildElement(
                from: window,
                appName: appName,
                store: store,
                depth: 0,
                maxDepth: depthForWindow
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
                    appName: appName,
                    store: store,
                    depth: 0,
                    maxDepth: maxDepth
                )
                if let element {
                    topLevelElements.append(element)
                }
            }
        }

        await store.markSnapshotted(appName)
        let count = await store.refsForApp(appName).count
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

    private func buildElement(
        from axElement: AXUIElement,
        appName: String,
        store: ElementStore,
        depth: Int,
        maxDepth: Int
    ) async -> PilotElement? {
        let attrs = readBatchAttributes(axElement)

        let role = attrs.role

        if role == nil && attrs.title == nil && attrs.value == nil && attrs.description == nil {
            return nil
        }

        if role == "AXUnknown" {
            return nil
        }

        let wrapper = AXElementWrapper(axElement)
        let bounds = bridge.getBounds(axElement)

        // Build children FIRST so we can inherit labels from them
        var childElements: [PilotElement]?
        if depth < maxDepth {
            let axChildren = bridge.getChildren(axElement)
            if !axChildren.isEmpty {
                var built: [PilotElement] = []
                for child in axChildren {
                    if let childElement = await buildElement(
                        from: child,
                        appName: appName,
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

        // For unlabeled container elements (GROUP, ROW, CELL), inherit label
        // by recursively searching descendants for the first meaningful text.
        var effectiveTitle = attrs.title
        var effectiveDesc = attrs.description
        if effectiveTitle == nil && effectiveDesc == nil {
            let containerRoles = Set(["AXGroup", "AXRow", "AXCell", "AXOutlineRow"])
            if let r = role, containerRoles.contains(r), let children = childElements {
                if let inherited = Self.findFirstLabel(in: children) {
                    effectiveTitle = inherited
                }
            }
        }

        let ref = await store.register(
            wrapper,
            appName: appName,
            role: role,
            title: effectiveTitle,
            description: effectiveDesc,
            value: attrs.value
        )

        return PilotElement(
            ref: ref,
            role: role ?? "AXUnknown",
            title: effectiveTitle,
            value: attrs.value,
            description: effectiveDesc,
            enabled: attrs.enabled,
            focused: attrs.focused,
            bounds: bounds,
            children: childElements
        )
    }

    // MARK: - Label Inheritance

    /// Recursively find the first meaningful label in a subtree.
    /// Skips IMAGE elements (icons) and prefers TEXT/BUTTON/INPUT labels.
    private static func findFirstLabel(in elements: [PilotElement]) -> String? {
        for element in elements {
            // Skip images — they're usually icons, not meaningful labels
            if element.role == "AXImage" { continue }

            // Check this element's title
            if let t = element.title, !t.isEmpty,
               !t.contains("<AXValue 0x"), t.count > 1 {
                return t
            }
            if let d = element.description, !d.isEmpty,
               !d.contains("<AXValue 0x"), d.count > 1 {
                return d
            }

            // Recurse into children
            if let children = element.children {
                if let found = findFirstLabel(in: children) {
                    return found
                }
            }
        }
        return nil
    }

    // MARK: - Batch Attribute Reading

    private struct BatchResult {
        let role: String?
        let title: String?
        let value: String?
        let description: String?
        let enabled: Bool
        let focused: Bool
    }

    private func readBatchAttributes(_ element: AXUIElement) -> BatchResult {
        let values = bridge.getAttributes(element, Self.batchAttributes)

        let role = values[0] as? String
        let title = values[1] as? String

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
