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

    /// JavaScript that scans the DOM, stores ALL elements for actions,
    /// but returns a compact structured summary instead of a raw dump.
    /// Returns JSON: { summary: string, elements: [...] }
    static let discoveryScript = """
    (() => {
        const allEls = [];   // For element registration (action targets)
        const seen = new Set();
        window.__desktopMcpElements = [];

        // --- Phase 1: Collect ALL interactive/meaningful elements ---
        const selectors = [
            'button', 'a[href]', 'a[role]', 'input', 'textarea', 'select',
            '[role="button"]', '[role="link"]', '[role="tab"]', '[role="treeitem"]',
            '[role="menuitem"]', '[role="option"]', '[role="checkbox"]', '[role="radio"]',
            '[role="textbox"]', '[role="switch"]', '[role="slider"]', '[role="combobox"]',
            '[role="searchbox"]', '[role="listbox"]', '[role="dialog"]',
            '[data-qa]', '[data-testid]', '[data-test]',
            '[contenteditable="true"]', '[aria-label]',
            'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'img[alt]', 'label',
        ];
        for (const el of document.querySelectorAll(selectors.join(','))) {
            if (seen.has(el)) continue;
            seen.add(el);
            if (el.offsetParent === null) {
                const s = window.getComputedStyle(el);
                if (s.display === 'none' || s.visibility === 'hidden') continue;
            }
            window.__desktopMcpElements.push(el);
            allEls.push({
                type: classify(el),
                label: extractLabel(el) || 'unlabeled',
                value: extractValue(el),
                dqa: el.getAttribute('data-qa') || null,
                idx: allEls.length,
            });
        }
        // Also collect sidebar/content text spans
        for (const el of document.querySelectorAll(
            '[class*="sidebar"] span, [class*="channel"] span, [class*="message"] span, [class*="header"] span, [aria-live], .p-channel_sidebar__name'
        )) {
            if (seen.has(el) || el.offsetParent === null) continue;
            const t = el.textContent.trim();
            if (!t || t.length < 2 || t.length > 100) continue;
            seen.add(el);
            window.__desktopMcpElements.push(el);
            allEls.push({ type: 'TEXT', label: t, value: null, dqa: el.getAttribute('data-qa') || null, idx: allEls.length });
        }

        // --- Phase 2: Build smart summary ---
        const summary = buildSummary();

        return JSON.stringify({ summary, elements: allEls });

        // ===== Summary Builder (universal, pattern-based) =====
        function buildSummary() {
            const lines = [];
            lines.push('Page: ' + (document.title || location.pathname));

            // Collect regions: landmarks + dialogs
            const regions = collectRegions();

            for (const region of regions) {
                const regionLines = summarizeRegion(region);
                if (regionLines.length > 0) {
                    lines.push('');
                    lines.push('=== ' + region.name + ' ===');
                    lines.push(...regionLines);
                }
            }

            lines.push('');
            lines.push('(' + allEls.length + ' elements stored for actions)');
            return lines.join('\\n');
        }

        function collectRegions() {
            const regions = [];
            const claimedRoots = [];

            // Priority 1: visible dialogs — always their own regions
            for (const d of document.querySelectorAll('[role="dialog"], [role="alertdialog"]')) {
                if (d.offsetParent === null) continue;
                const label = d.getAttribute('aria-label') ||
                              (d.querySelector('h1,h2,h3,[role="heading"]')?.textContent.trim().substring(0, 60)) ||
                              'Dialog';
                regions.push({ name: 'Dialog: ' + label, root: d, exclude: [] });
                claimedRoots.push(d);
            }

            // Priority 2: named ARIA landmarks
            const landmarks = [
                { sel: '[role="banner"], header[role="banner"]', name: 'Header' },
                { sel: '[role="navigation"]', name: 'Navigation' },
                { sel: '[role="main"], main', name: 'Main' },
                { sel: '[role="complementary"]', name: 'Sidebar' },
                { sel: '[role="contentinfo"]', name: 'Footer' },
            ];
            for (const { sel, name } of landmarks) {
                for (const el of document.querySelectorAll(sel)) {
                    if (el.offsetParent === null) continue;
                    if (claimedRoots.some(r => r.contains(el) || el.contains(r))) continue;
                    regions.push({ name, root: el, exclude: [] });
                    claimedRoots.push(el);
                }
            }

            // Priority 3: fallback — body, excluding already-claimed regions
            if (regions.length === 0) {
                regions.push({ name: 'Page', root: document.body, exclude: [] });
            } else {
                regions.push({ name: 'Other', root: document.body, exclude: [...claimedRoots] });
            }

            return regions;
        }

        function summarizeRegion(region) {
            const lines = [];

            // 1. Find repeated item patterns (lists)
            const patterns = findPatternsIn(region);
            for (const p of patterns) {
                lines.push('');
                lines.push(p.name + ' (' + p.items.length + '):');

                // Long lists with TRULY short items (navigation/channels): inline comma-separated
                // Only collapse if items are single-line AND avg length is small
                const sampleMultiline = p.items.slice(0, 5).filter(it => (it.innerText || '').includes('\\n')).length;
                const isLongShortList = p.items.length > 10 && p.avgTextLen < 40 && sampleMultiline === 0;
                if (isLongShortList) {
                    const names = p.items.slice(0, 20).map(it => (it.innerText || '').trim().substring(0, 40)).filter(x => x);
                    lines.push('  ' + names.join(', ') + (p.items.length > 20 ? ', ...' : ''));
                    continue;
                }

                // Normal list: up to 15 items with full text
                const showN = Math.min(p.items.length, 15);
                for (let i = 0; i < showN; i++) {
                    const item = p.items[i];
                    const text = extractItemText(item);
                    if (!text) continue;
                    if (!text.includes('\\n') && text.length < 100) {
                        lines.push('  • ' + text);
                    } else {
                        lines.push('  ---');
                        const itemLines = text.split('\\n').slice(0, 25);
                        for (const ln of itemLines) {
                            if (ln.trim()) lines.push('  ' + ln.trim().substring(0, 300));
                        }
                    }
                }
                if (p.items.length > showN) {
                    lines.push('  ... (' + (p.items.length - showN) + ' more)');
                }
            }

            // 2. Unique headings
            const headings = queryIn(region, 'h1, h2, h3, [role="heading"]');
            const seenH = new Set();
            for (const h of headings) {
                const t = h.textContent.trim();
                if (t && t.length <= 100 && !seenH.has(t)) {
                    seenH.add(t);
                    lines.push('Heading: ' + t);
                }
            }

            // 3. Inputs
            const inputs = queryIn(region, 'input:not([type="hidden"]):not([type="checkbox"]):not([type="radio"]), textarea, [contenteditable="true"][role="textbox"], [data-qa="message_input"]');
            for (const inp of inputs) {
                if (inp.offsetParent === null) continue;
                const label = inp.getAttribute('placeholder') || inp.getAttribute('aria-label') ||
                              inp.getAttribute('data-qa') || inp.name || 'input';
                const val = inp.value || inp.innerText?.trim() || '';
                const display = val ? ' = "' + val.substring(0, 60) + '"' : ' [empty]';
                lines.push('Input: ' + label + display);
            }

            // 4. Standalone action buttons (not inside item patterns)
            const patternRoots = patterns.flatMap(p => p.items);
            const actions = [];
            const seenA = new Set();
            for (const btn of queryIn(region, 'button[aria-label], [role="button"][aria-label]')) {
                if (btn.offsetParent === null) continue;
                if (patternRoots.some(r => r.contains(btn))) continue;
                const label = btn.getAttribute('aria-label');
                if (!label || label.length > 40 || seenA.has(label)) continue;
                seenA.add(label);
                actions.push(label);
            }
            if (actions.length > 0) {
                lines.push('Actions: ' + actions.slice(0, 15).join(', ') + (actions.length > 15 ? ', ...' : ''));
            }

            // 5. Selected tabs
            const tabs = queryIn(region, '[role="tab"]');
            const selectedTabs = [];
            for (const t of tabs) {
                if (t.getAttribute('aria-selected') === 'true') {
                    const name = t.getAttribute('aria-label') || t.textContent.trim();
                    if (name && name.length < 50) selectedTabs.push(name);
                }
            }
            if (tabs.length > 0) {
                const allNames = [...new Set([...tabs].map(t => (t.getAttribute('aria-label') || t.textContent.trim()).substring(0, 30)).filter(x => x))];
                if (allNames.length > 0) {
                    lines.push('Tabs: ' + allNames.map(n => selectedTabs.includes(n) ? '[' + n + ']' : n).join(' | '));
                }
            }

            return lines;
        }

        function queryIn(region, selector) {
            const all = region.root.querySelectorAll(selector);
            if (region.exclude.length === 0) return [...all];
            return [...all].filter(el => !region.exclude.some(ex => ex.contains(el)));
        }

        function findPatternsIn(region) {
            // Build candidate items: data-qa, data-testid, role-based, or li
            const candidates = queryIn(region,
                '[data-qa], [data-testid], [data-test], ' +
                '[role="listitem"], [role="row"], [role="option"], [role="treeitem"], [role="article"], ' +
                'li'
            );

            // Group by signature
            const groups = new Map();
            for (const el of candidates) {
                if (el.offsetParent === null) continue;
                const sig = getSignature(el);
                if (!sig) continue;
                if (!groups.has(sig)) groups.set(sig, []);
                groups.get(sig).push(el);
            }

            // Keep groups with 3+ items AND meaningful text content
            let patterns = [];
            for (const [sig, items] of groups) {
                if (items.length < 3) continue;

                // Quality check: at least half the items must have meaningful text
                let meaningfulCount = 0;
                let totalTextLen = 0;
                for (const item of items.slice(0, 10)) {
                    const t = (item.innerText || '').trim();
                    totalTextLen += t.length;
                    if (t.length >= 2 && t.replace(/\\s/g, '').length >= 2) meaningfulCount++;
                }
                if (meaningfulCount < Math.ceil(items.slice(0, 10).length / 2)) continue;
                if (totalTextLen < 20) continue;  // entire sample has basically no text

                // Skip pure wrapper/virtual list containers (short text, mostly structural)
                const avgTextLen = totalTextLen / Math.min(items.length, 10);
                if (sig.match(/virtual|wrapper|container$/i) && avgTextLen < 30) continue;

                patterns.push({ name: sig, items, avgTextLen });
            }

            // Remove nested: if pattern A's items are all descendants of pattern B's items, drop A
            patterns = patterns.filter(p => {
                for (const other of patterns) {
                    if (other === p) continue;
                    const allNested = p.items.every(pi =>
                        other.items.some(oi => oi !== pi && oi.contains(pi))
                    );
                    if (allNested) return false;
                }
                return true;
            });

            // Also: if pattern A is a PARENT of pattern B (i.e., A's items contain B's items),
            // prefer the INNER pattern (more specific content) if it has reasonable item count.
            // Drop parent patterns whose items each contain a child pattern's item.
            const kept = [];
            for (const p of patterns) {
                let hasInnerChild = false;
                for (const other of patterns) {
                    if (other === p) continue;
                    if (other.items.length > p.items.length) continue;
                    // If every item of p contains at least one item of other, p wraps other
                    const wraps = p.items.every(pi =>
                        other.items.some(oi => pi.contains(oi) && pi !== oi)
                    );
                    if (wraps && other.items.length >= 3) {
                        hasInnerChild = true;
                        break;
                    }
                }
                if (!hasInnerChild) kept.push(p);
            }
            patterns = kept;

            // Sort: most items first
            patterns.sort((a, b) => b.items.length - a.items.length);

            // Keep top 4 patterns
            return patterns.slice(0, 4);
        }

        function getSignature(el) {
            const dqa = el.getAttribute('data-qa');
            if (dqa) return normalizeSignature(dqa);
            const dti = el.getAttribute('data-testid') || el.getAttribute('data-test');
            if (dti) return normalizeSignature(dti);
            const role = el.getAttribute('role');
            if (role) return 'role:' + role;
            if (el.tagName === 'LI') {
                const cls = (typeof el.className === 'string' && el.className) ? el.className.split(/\\s+/)[0] : '';
                return 'li:' + cls;
            }
            return null;
        }

        function normalizeSignature(s) {
            // Strip trailing numbers, UUIDs, and obvious ID suffixes
            return s.replace(/[_-]?\\d+$/, '')
                    .replace(/[_-]?[a-f0-9]{8,}$/, '')
                    .substring(0, 60);
        }

        function extractItemText(item) {
            // Use innerText to preserve display line breaks
            let text = item.innerText || item.textContent || '';
            text = text.trim();
            // Collapse excessive blank lines
            text = text.replace(/\\n{3,}/g, '\\n\\n');
            return text;
        }

        // ===== Element helpers =====
        function classify(el) {
            const tag = el.tagName.toLowerCase();
            const role = el.getAttribute('role');
            if (role) {
                const m = {button:'BUTTON',link:'LINK',tab:'TAB',treeitem:'TREEITEM',menuitem:'MENUITEM',option:'OPTION',checkbox:'CHECKBOX',radio:'RADIO',textbox:'INPUT',searchbox:'INPUT',combobox:'SELECT','switch':'SWITCH',slider:'SLIDER',dialog:'DIALOG',tabpanel:'TABPANEL',toolbar:'TOOLBAR',navigation:'NAV',heading:'HEADING'};
                if (m[role]) return m[role];
            }
            const tm = {button:'BUTTON',a:'LINK',input:'INPUT',textarea:'TEXTAREA',select:'SELECT',h1:'HEADING',h2:'HEADING',h3:'HEADING',h4:'HEADING',h5:'HEADING',h6:'HEADING',img:'IMAGE',svg:'IMAGE',label:'LABEL'};
            if (tm[tag]) return tm[tag];
            if (tag === 'input') {
                const t = el.getAttribute('type') || 'text';
                if (t === 'checkbox') return 'CHECKBOX';
                if (t === 'radio') return 'RADIO';
                if (t === 'submit' || t === 'button') return 'BUTTON';
                return 'INPUT';
            }
            if (el.getAttribute('contenteditable') === 'true') return 'INPUT';
            if (el.getAttribute('data-qa') || el.getAttribute('data-testid')) return 'BUTTON';
            return 'GROUP';
        }
        function extractLabel(el) {
            const a = el.getAttribute('aria-label'); if (a && a.trim()) return a.trim().substring(0,100);
            const d = el.getAttribute('data-qa'); if (d && d.trim()) return d.trim().substring(0,100);
            const t = el.getAttribute('data-testid') || el.getAttribute('data-test');
            if (t && t.trim()) return t.trim().substring(0,100);
            const tx = el.textContent.trim();
            if (tx && tx.length > 0 && tx.length <= 100) return tx;
            const p = el.getAttribute('placeholder'); if (p) return p.trim().substring(0,100);
            const ti = el.getAttribute('title'); if (ti) return ti.trim().substring(0,100);
            const al = el.getAttribute('alt'); if (al) return al.trim().substring(0,100);
            return null;
        }
        function extractValue(el) {
            if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') return el.value || null;
            if (el.getAttribute('contenteditable') === 'true') return el.textContent.trim() || null;
            if (el.getAttribute('aria-checked') !== null) return el.getAttribute('aria-checked');
            if (el.getAttribute('aria-selected') !== null) return el.getAttribute('aria-selected');
            const dqa = el.getAttribute('data-qa') || '';
            if (dqa.startsWith('message-text') || dqa.startsWith('message_content')) {
                const t = el.innerText.trim(); if (t) return t.substring(0,2000);
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
                return JSON.stringify({ok: true, method: 'value'});
            }
            // Detect contenteditable: direct attribute, isContentEditable property, or role=textbox
            const isEditable = el.isContentEditable || el.getAttribute('role') === 'textbox' || el.closest('[contenteditable="true"]') !== null;
            return JSON.stringify({ok: true, contenteditable: isEditable});
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
              let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let elements = parsed["elements"] as? [[String: Any]],
              let summary = parsed["summary"] as? String else {
            await store.markSnapshotted(appName)
            return emptySnapshot(appName: appName, bundleID: bundleID, pid: pid)
        }

        // Register each discovered element (DOM refs stored in __desktopMcpElements)
        let placeholder = await CDPElementHolder.shared.placeholder

        for (i, elem) in elements.enumerated() {
            let type = elem["type"] as? String ?? "GROUP"
            let label = elem["label"] as? String ?? "unlabeled"
            let value = elem["value"] as? String

            let ref = await store.register(
                placeholder,
                appName: appName,
                role: "AX\(type)",
                title: label,
                description: nil,
                value: value
            )

            await CDPElementHolder.shared.store(ref: ref, domIndex: i)
            if let value, !value.isEmpty {
                await CDPElementHolder.shared.storeValue(ref: ref, value: value)
            }
        }

        // Store the summary for display
        await CDPElementHolder.shared.storeSummary(appName: appName, summary: summary)

        await store.markSnapshotted(appName)

        let count = await store.refsForApp(appName).count
        let formatter = ISO8601DateFormatter()
        return AppSnapshot(
            app: appName,
            bundleID: bundleID,
            pid: pid,
            timestamp: formatter.string(from: Date()),
            elementCount: count,
            elements: []
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
    private var refToValue: [String: String] = [:]
    private var appSummaries: [String: String] = [:]

    let placeholder: AXElementWrapper = {
        return AXElementWrapper(AXUIElementCreateSystemWide())
    }()

    func store(ref: String, domIndex: Int) {
        refToDomIndex[ref] = domIndex
    }

    func storeValue(ref: String, value: String) {
        refToValue[ref] = value
    }

    func getValue(ref: String) -> String? {
        refToValue[ref]
    }

    func storeSummary(appName: String, summary: String) {
        appSummaries[appName] = summary
    }

    func getSummary(appName: String) -> String? {
        appSummaries[appName]
    }

    func allValues(forApp appName: String) -> [(ref: String, value: String)] {
        let prefix = appName + "/"
        return refToValue
            .filter { $0.key.hasPrefix(prefix) }
            .map { (ref: $0.key, value: $0.value) }
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
        refToValue = [:]
    }

    func resetApp(_ appName: String) {
        let prefix = appName + "/"
        for key in refToDomIndex.keys where key.hasPrefix(prefix) {
            refToDomIndex.removeValue(forKey: key)
        }
        for key in refToValue.keys where key.hasPrefix(prefix) {
            refToValue.removeValue(forKey: key)
        }
        appSummaries.removeValue(forKey: appName)
    }
}
