@preconcurrency import ApplicationServices
import Foundation

// MARK: - CDP DOM Snapshot Builder

/// Builds element list by directly querying the DOM via CDP Runtime.evaluate.
///
/// This is far more reliable than CDP's Accessibility.getFullAXTree() because:
/// 1. Catches elements without ARIA roles (common in Electron apps)
/// 2. Reads data-qa, data-testid, aria-label — stable selectors
/// 3. Handles virtualized lists via scrollIntoView
/// 4. Works universally across all Electron apps
struct CDPSnapshotBuilder: Sendable {

    /// The JavaScript that runs inside the Electron app to discover elements.
    /// Returns a JSON array of discovered elements with type, label, and index.
    static let discoveryScript = """
    (() => {
        const results = [];
        const seen = new Set();
        window.__desktopMcpElements = [];  // Store DOM refs for later actions

        // Phase 1: Query all interactive/meaningful elements
        const selectors = [
            'button', 'a[href]', 'a[role]', 'input', 'textarea', 'select',
            '[role="button"]', '[role="link"]', '[role="tab"]', '[role="treeitem"]',
            '[role="menuitem"]', '[role="option"]', '[role="checkbox"]', '[role="radio"]',
            '[role="textbox"]', '[role="switch"]', '[role="slider"]', '[role="combobox"]',
            '[role="searchbox"]', '[role="listbox"]', '[role="dialog"]', '[role="alertdialog"]',
            '[role="tabpanel"]', '[role="toolbar"]', '[role="navigation"]',
            '[data-qa]', '[data-testid]', '[data-test]', '[data-test-id]',
            '[contenteditable="true"]',
            '[aria-label]',
            'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
            'img[alt]', 'svg[aria-label]',
            'label',
        ];

        const allElements = document.querySelectorAll(selectors.join(','));

        for (const el of allElements) {
            if (seen.has(el)) continue;
            seen.add(el);

            // Skip hidden elements
            if (el.offsetParent === null && el.tagName !== 'INPUT' && el.getAttribute('type') !== 'hidden') {
                // Check if it's inside a visible overflow container
                const style = window.getComputedStyle(el);
                if (style.display === 'none' || style.visibility === 'hidden') continue;
            }

            // Skip tiny elements (likely icons without meaning)
            const rect = el.getBoundingClientRect();
            if (rect.width < 2 && rect.height < 2) continue;

            const type = classifyElement(el);
            const label = extractLabel(el);
            if (!label && type === 'GROUP') continue; // Skip unlabeled groups

            window.__desktopMcpElements.push(el);  // Store DOM ref at same index
            results.push({
                type: type,
                label: label || 'unlabeled',
                value: extractValue(el),
                dataQa: el.getAttribute('data-qa') || null,
                disabled: el.disabled || el.getAttribute('aria-disabled') === 'true',
                focused: document.activeElement === el,
                index: results.length,
            });
        }

        // Phase 2: Scan for visible text blocks not covered above
        // (e.g. status text, labels, important static text)
        const textSelectors = [
            '[class*="sidebar"] span', '[class*="channel"] span',
            '[class*="message"] span', '[class*="header"] span',
            '[aria-live]', '[role="status"]', '[role="alert"]',
            '.p-channel_sidebar__name',
        ];
        try {
            const textEls = document.querySelectorAll(textSelectors.join(','));
            for (const el of textEls) {
                if (seen.has(el)) continue;
                seen.add(el);
                const text = el.textContent.trim();
                if (!text || text.length < 2 || text.length > 100) continue;
                if (el.offsetParent === null) continue;

                window.__desktopMcpElements.push(el);
                results.push({
                    type: 'TEXT',
                    label: text,
                    value: null,
                    dataQa: el.getAttribute('data-qa') || null,
                    disabled: false,
                    focused: false,
                    index: results.length,
                });
            }
        } catch(e) {}

        return JSON.stringify(results);

        // --- Helper functions ---

        function classifyElement(el) {
            const tag = el.tagName.toLowerCase();
            const role = el.getAttribute('role');

            // Role takes priority
            if (role) {
                const roleMap = {
                    'button': 'BUTTON', 'link': 'LINK', 'tab': 'TAB',
                    'treeitem': 'TREEITEM', 'menuitem': 'MENUITEM',
                    'option': 'OPTION', 'checkbox': 'CHECKBOX', 'radio': 'RADIO',
                    'textbox': 'INPUT', 'searchbox': 'INPUT', 'combobox': 'SELECT',
                    'switch': 'SWITCH', 'slider': 'SLIDER', 'listbox': 'SELECT',
                    'dialog': 'DIALOG', 'alertdialog': 'DIALOG',
                    'tabpanel': 'TABPANEL', 'toolbar': 'TOOLBAR',
                    'navigation': 'NAV', 'heading': 'HEADING',
                };
                if (roleMap[role]) return roleMap[role];
            }

            // Tag-based
            const tagMap = {
                'button': 'BUTTON', 'a': 'LINK', 'input': 'INPUT',
                'textarea': 'TEXTAREA', 'select': 'SELECT',
                'h1': 'HEADING', 'h2': 'HEADING', 'h3': 'HEADING',
                'h4': 'HEADING', 'h5': 'HEADING', 'h6': 'HEADING',
                'img': 'IMAGE', 'svg': 'IMAGE', 'label': 'LABEL',
            };
            if (tagMap[tag]) return tagMap[tag];

            // Input types
            if (tag === 'input') {
                const inputType = el.getAttribute('type') || 'text';
                if (inputType === 'checkbox') return 'CHECKBOX';
                if (inputType === 'radio') return 'RADIO';
                if (inputType === 'submit' || inputType === 'button') return 'BUTTON';
                return 'INPUT';
            }

            if (el.getAttribute('contenteditable') === 'true') return 'INPUT';
            if (el.getAttribute('data-qa') || el.getAttribute('data-testid')) return 'BUTTON';

            return 'GROUP';
        }

        function extractLabel(el) {
            // Priority: aria-label > data-qa > data-testid > textContent > placeholder > title > alt
            const ariaLabel = el.getAttribute('aria-label');
            if (ariaLabel && ariaLabel.trim()) return ariaLabel.trim().substring(0, 100);

            const dataQa = el.getAttribute('data-qa');
            if (dataQa && dataQa.trim()) {
                // Clean up data-qa format: "channel_sidebar_name_홍길동" → "홍길동"
                // But keep it if it's descriptive
                return dataQa.trim().substring(0, 100);
            }

            const testId = el.getAttribute('data-testid') || el.getAttribute('data-test') || el.getAttribute('data-test-id');
            if (testId && testId.trim()) return testId.trim().substring(0, 100);

            // textContent — but be smart about it
            const text = el.textContent.trim();
            if (text && text.length > 0 && text.length <= 100) {
                // Skip if it's just whitespace or numbers
                if (text.replace(/\\s/g, '').length > 0) return text;
            }

            const placeholder = el.getAttribute('placeholder');
            if (placeholder) return placeholder.trim().substring(0, 100);

            const title = el.getAttribute('title');
            if (title) return title.trim().substring(0, 100);

            const alt = el.getAttribute('alt');
            if (alt) return alt.trim().substring(0, 100);

            return null;
        }

        function extractValue(el) {
            if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
                return el.value || null;
            }
            if (el.getAttribute('contenteditable') === 'true') {
                return el.textContent.trim() || null;
            }
            if (el.getAttribute('aria-checked') !== null) {
                return el.getAttribute('aria-checked');
            }
            if (el.getAttribute('aria-selected') !== null) {
                return el.getAttribute('aria-selected');
            }
            return null;
        }
    })()
    """

    /// The JavaScript for clicking an element by its discovery index.
    static func clickScript(index: Int) -> String {
        return """
        (() => {
            const el = window.__desktopMcpElements && window.__desktopMcpElements[\(index)];
            if (!el) return JSON.stringify({ok: false, error: 'element not found at index \(index)'});
            el.scrollIntoView({block: 'center', behavior: 'instant'});
            el.click();
            return JSON.stringify({ok: true, tag: el.tagName, text: (el.textContent || '').substring(0, 50)});
        })()
        """
    }

    /// The JavaScript for typing into an element by index.
    static func focusScript(index: Int) -> String {
        return """
        (() => {
            const el = window.__desktopMcpElements && window.__desktopMcpElements[\(index)];
            if (!el) return JSON.stringify({ok: false, error: 'element not found'});
            el.scrollIntoView({block: 'center', behavior: 'instant'});
            el.focus();
            el.click();
            return JSON.stringify({ok: true, tag: el.tagName});
        })()
        """
    }

    /// The JavaScript for setting a value on an element by index.
    static func setValueScript(index: Int, value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        (() => {
            const el = window.__desktopMcpElements && window.__desktopMcpElements[\(index)];
            if (!el) return JSON.stringify({ok: false, error: 'element not found'});
            el.scrollIntoView({block: 'center', behavior: 'instant'});
            el.focus();
            if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
                el.value = '\(escaped)';
                el.dispatchEvent(new Event('input', {bubbles: true}));
                el.dispatchEvent(new Event('change', {bubbles: true}));
            }
            // For contenteditable, we'll use Input.insertText via CDP
            return JSON.stringify({ok: true, contenteditable: el.getAttribute('contenteditable') === 'true'});
        })()
        """
    }


    // MARK: - Build Snapshot

    /// Build a snapshot by querying the DOM via CDP.
    func buildSnapshot(
        cdp: CDPBridge,
        appName: String,
        bundleID: String?,
        pid: Int32,
        store: ElementStore
    ) async throws -> AppSnapshot {
        await store.resetApp(appName)
        await CDPElementHolder.shared.resetApp(appName)

        // Run discovery script in the page
        let result = try await cdp.sendCommand("Runtime.evaluate", params: [
            "expression": Self.discoveryScript,
            "returnByValue": true
        ])

        guard let resultObj = result["result"] as? [String: Any],
              let jsonString = resultObj["value"] as? String,
              let jsonData = jsonString.data(using: .utf8),
              let elements = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
            await store.markSnapshotted(appName)
            return emptySnapshot(appName: appName, bundleID: bundleID, pid: pid)
        }

        // Register each discovered element (DOM refs already stored in __desktopMcpElements)
        let placeholder = await CDPElementHolder.shared.placeholder

        for (i, elem) in elements.enumerated() {
            let type = elem["type"] as? String ?? "GROUP"
            let label = elem["label"] as? String ?? "unlabeled"
            let value = elem["value"] as? String
            let disabled = elem["disabled"] as? Bool ?? false
            let focused = elem["focused"] as? Bool ?? false

            let ref = await store.register(
                placeholder,
                appName: appName,
                role: "AX\(type)",
                title: label,
                description: nil,
                value: value
            )

            // Store the DOM index for later actions
            await CDPElementHolder.shared.store(ref: ref, domIndex: i)
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
            elements: []  // Flat list via store.refsForApp() instead
        )
    }

    private func emptySnapshot(appName: String, bundleID: String?, pid: Int32) -> AppSnapshot {
        let formatter = ISO8601DateFormatter()
        return AppSnapshot(
            app: appName,
            bundleID: bundleID,
            pid: pid,
            timestamp: formatter.string(from: Date()),
            elementCount: 0,
            elements: []
        )
    }
}

// MARK: - CDP Element Holder

/// Actor that maps element refs to CDP DOM element indices.
actor CDPElementHolder {
    static let shared = CDPElementHolder()

    private var refToDomIndex: [String: Int] = [:]

    let placeholder: AXElementWrapper = {
        return AXElementWrapper(AXUIElementCreateSystemWide())
    }()

    func store(ref: String, domIndex: Int) {
        refToDomIndex[ref] = domIndex
    }

    func store(ref: String, backendNodeId: Int) {
        // Legacy compat — map negative indices for backend node IDs
        refToDomIndex[ref] = -backendNodeId
    }

    func resolve(ref: String) -> Int? {
        return refToDomIndex[ref]
    }

    func reset() {
        refToDomIndex = [:]
    }

    func resetApp(_ appName: String) {
        let prefix = appName + "/"
        let toRemove = refToDomIndex.keys.filter { $0.hasPrefix(prefix) }
        for key in toRemove {
            refToDomIndex.removeValue(forKey: key)
        }
    }
}
