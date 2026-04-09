import ApplicationServices
import Foundation

// MARK: - Snapshot Builder

/// Builds a `PilotElement` tree from a running app's accessibility tree.
///
/// Walks the AX hierarchy starting from the app element, reads attributes
/// via `AXBridge`, and registers every meaningful element in the
/// `ElementStore` with `App/TYPE:Label` refs.
///
/// Parallelism strategy (3 levels):
///   1. Windows are traversed concurrently via TaskGroup.
///   2. Non-target windows (when focusWindowTitle is set) are skipped entirely
///      — only their title is recorded.
///   3. Within a window, sibling nodes at shallow depth (< 3) with many
///      children (> 4) are traversed concurrently.
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

    /// Depth threshold: parallelize children only at depths below this.
    private static let parallelDepthLimit = 3
    /// Minimum sibling count to trigger parallel traversal.
    private static let parallelChildThreshold = 4
    /// Threshold above which only visible children are traversed.
    private static let smartChildThreshold = 20

    // MARK: - Public API

    /// Build a complete snapshot of an app's UI tree.
    /// Elements are registered in the store with `appName/TYPE:Label` refs.
    func buildSnapshot(
        appElement: AXUIElement,
        appName: String,
        bundleID: String?,
        pid: Int32,
        store: ElementStore,
        maxDepth: Int = 10,
        focusWindowTitle: String? = nil
    ) async -> AppSnapshot {
        // Reset only this app's elements (preserve other apps)
        await store.resetApp(appName)

        let windows = bridge.getWindows(appElement)

        let topLevelElements: [PilotElement]

        if windows.isEmpty {
            // No windows — try direct children of the app element
            let children = bridge.getChildren(appElement)
            topLevelElements = await buildChildrenParallel(
                children, appName: appName, store: store,
                depth: 0, maxDepth: maxDepth
            )
        } else {
            // Level 1: Traverse windows concurrently
            topLevelElements = await withTaskGroup(of: (Int, PilotElement?).self) { group in
                for (index, window) in windows.enumerated() {
                    let windowTitle = bridge.getTitle(window)

                    // Determine depth for this window
                    let depthForWindow: Int
                    if let focus = focusWindowTitle {
                        depthForWindow = (windowTitle == focus) ? maxDepth : 0
                    } else {
                        depthForWindow = (index == 0) ? maxDepth : 0
                    }

                    // Wrap AXUIElement in Sendable wrapper before crossing task boundary
                    let wrappedWindow = AXElementWrapper(window)
                    let windowBounds = bridge.getBounds(window)

                    group.addTask {
                        if depthForWindow == 0 {
                            // Level 2 optimization: non-target windows — title only, NO AX traversal
                            let ref = await store.register(
                                wrappedWindow, appName: appName,
                                role: "AXWindow", title: windowTitle,
                                description: nil, value: nil
                            )
                            let element = PilotElement(
                                ref: ref, role: "AXWindow",
                                title: windowTitle, value: nil,
                                description: nil, enabled: true,
                                focused: false, bounds: windowBounds,
                                children: nil
                            )
                            return (index, element)
                        }
                        // Full-depth traversal for target window
                        let element = await self.buildElement(
                            from: wrappedWindow.element, appName: appName, store: store,
                            depth: 0, maxDepth: depthForWindow
                        )
                        return (index, element)
                    }
                }

                // Collect results preserving original window order
                var results = [(Int, PilotElement?)]()
                for await result in group {
                    results.append(result)
                }
                return results.sorted { $0.0 < $1.0 }.compactMap { $0.1 }
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

    // MARK: - Recursive Tree Building (with conditional parallelism)

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
        var totalChildCount: Int?
        var visibleChildCount: Int?

        if depth < maxDepth {
            let fullCount = bridge.getChildCount(axElement)
            if fullCount > 0 {
                let axChildren: [AXUIElement]
                let truncated: Bool

                if fullCount > Self.smartChildThreshold {
                    // Smart traversal: visible children only
                    axChildren = bridge.getVisibleChildren(axElement)
                    truncated = (axChildren.count < fullCount)
                } else {
                    axChildren = bridge.getChildren(axElement)
                    truncated = false
                }

                if !axChildren.isEmpty {
                    // Parallel traversal for wide nodes at shallow depth
                    let shouldParallelize = depth < Self.parallelDepthLimit
                        && axChildren.count > Self.parallelChildThreshold

                    let built: [PilotElement]
                    if shouldParallelize {
                        built = await buildChildrenParallel(
                            axChildren, appName: appName, store: store,
                            depth: depth + 1, maxDepth: maxDepth
                        )
                    } else {
                        built = await buildChildrenSequential(
                            axChildren, appName: appName, store: store,
                            depth: depth + 1, maxDepth: maxDepth
                        )
                    }
                    childElements = built.isEmpty ? nil : built
                }

                if truncated {
                    totalChildCount = fullCount
                    visibleChildCount = axChildren.count
                }
            }
        }

        // For unlabeled container elements, inherit label from descendants
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

        var element = PilotElement(
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
        element.totalChildren = totalChildCount
        element.visibleChildren = visibleChildCount

        // Record truncation in store for output formatting
        if let total = totalChildCount, let visible = visibleChildCount {
            await store.setTruncation(ref: ref, total: total, visible: visible)
        }

        return element
    }

    // MARK: - Parallel Children

    /// Traverse children concurrently via TaskGroup, preserving order.
    private func buildChildrenParallel(
        _ axChildren: [AXUIElement],
        appName: String,
        store: ElementStore,
        depth: Int,
        maxDepth: Int
    ) async -> [PilotElement] {
        await withTaskGroup(of: (Int, PilotElement?).self) { group in
            for (i, child) in axChildren.enumerated() {
                let wrappedChild = AXElementWrapper(child)
                group.addTask {
                    let element = await self.buildElement(
                        from: wrappedChild.element, appName: appName, store: store,
                        depth: depth, maxDepth: maxDepth
                    )
                    return (i, element)
                }
            }
            var results = [(Int, PilotElement?)]()
            for await r in group {
                results.append(r)
            }
            return results.sorted { $0.0 < $1.0 }.compactMap { $0.1 }
        }
    }

    /// Traverse children sequentially (for deep/small branches).
    private func buildChildrenSequential(
        _ axChildren: [AXUIElement],
        appName: String,
        store: ElementStore,
        depth: Int,
        maxDepth: Int
    ) async -> [PilotElement] {
        var built: [PilotElement] = []
        for child in axChildren {
            if let element = await buildElement(
                from: child, appName: appName, store: store,
                depth: depth, maxDepth: maxDepth
            ) {
                built.append(element)
            }
        }
        return built
    }

    // MARK: - Label Inheritance

    /// Recursively find the first meaningful label in a subtree.
    private static func findFirstLabel(in elements: [PilotElement]) -> String? {
        for element in elements {
            if element.role == "AXImage" { continue }

            if let t = element.title, !t.isEmpty,
               !t.contains("<AXValue 0x"), t.count > 1 {
                return t
            }
            if let d = element.description, !d.isEmpty,
               !d.contains("<AXValue 0x"), d.count > 1 {
                return d
            }

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
