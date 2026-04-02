import ApplicationServices
import Foundation

// MARK: - Element Store

/// Stores the mapping between opaque ref strings and AXUIElement objects.
///
/// Refs are ephemeral -- they reset on each new snapshot. When Claude says
/// "click e5", the store resolves "e5" back to the actual AXUIElement.
///
/// Uses `actor` isolation to guarantee thread safety. AXUIElement objects
/// are wrapped in `AXElementWrapper` (@unchecked Sendable) before crossing
/// the isolation boundary, since AXUIElement is thread-safe by Apple's
/// implementation but Swift 6 does not know that.
actor ElementStore {
    private var elements: [String: AXElementWrapper] = [:]
    private var counter: Int = 0

    // MARK: - Lifecycle

    /// Reset the store before building a new snapshot.
    /// All previous refs become invalid after this call.
    func reset() {
        elements = [:]
        counter = 0
    }

    // MARK: - Registration

    /// Register an element wrapper and return its unique ref (e.g. "e1", "e2").
    func register(_ wrapper: AXElementWrapper) -> String {
        counter += 1
        let ref = "e\(counter)"
        elements[ref] = wrapper
        return ref
    }

    // MARK: - Lookup

    /// Resolve a ref string back to its AXElementWrapper.
    /// Returns `nil` if the ref is unknown or the store has been reset.
    func resolve(_ ref: String) -> AXElementWrapper? {
        return elements[ref]
    }

    /// Convenience alias used by AccessibilityLayer.
    func resolveWrapped(_ ref: String) -> AXElementWrapper? {
        return elements[ref]
    }

    // MARK: - Diagnostics

    /// Current number of stored elements.
    func count() -> Int {
        return elements.count
    }
}
