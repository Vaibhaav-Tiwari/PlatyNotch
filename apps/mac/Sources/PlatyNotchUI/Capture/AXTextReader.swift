import ApplicationServices
import AppKit
import PlatyNotchKit

/// Reads the visible text of an app's focused window through the Accessibility API.
/// Call off the main actor: each AX call can block up to the messaging timeout.
enum AXTextReader {
    static let maxElements = 4_000
    static let maxChars = 200_000
    static let budget: Duration = .milliseconds(150)
    static let messagingTimeout: Float = 0.25

    struct Result: Sendable, Equatable {
        var title: String?
        var url: String?
        var text: String
        /// The window's `AXDocument` and `AXDescription`, checked for private-browsing markers.
        var document: String? = nil
        var windowDescription: String? = nil
    }

    /// The frontmost app's focused window.
    static func focusedWindowText(maxChars: Int) -> (title: String?, url: String?, text: String)? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        guard let r = focusedWindowText(pid: pid, maxChars: maxChars) else { return nil }
        return (r.title, r.url, r.text)
    }

    /// Sets the process-wide default messaging timeout once (the system-wide element's
    /// timeout applies to every element that has none of its own).
    private static let globalTimeout: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }()

    /// Depth-first over `kAXChildrenAttribute` from the focused window, collecting values,
    /// titles and descriptions, within 4 000 elements, `maxChars` (capped at 200 000) and a
    /// 150 ms deadline checked before every AX call site. Every element gets the 0.25 s
    /// messaging timeout before it is read. Secure text fields are never read (their
    /// value is not even requested); nil when a secure text field has focus, the app has
    /// no window, or the deadline passes before the window is known.
    static func focusedWindowText(pid: pid_t, maxChars: Int = maxChars) -> Result? {
        _ = globalTimeout
        let deadline = ContinuousClock.now.advanced(by: budget)
        func inTime() -> Bool { ContinuousClock.now < deadline }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)

        guard inTime() else { return nil }
        if let focused = element(app, kAXFocusedUIElementAttribute) {
            AXUIElementSetMessagingTimeout(focused, messagingTimeout)
            guard inTime() else { return nil }
            let head = values(focused, [kAXRoleAttribute, kAXSubroleAttribute])
            if AXTextCollector.isSecure(role: head?[0] as? String, subrole: head?[1] as? String) { return nil }
        }
        guard inTime(), let window = element(app, kAXFocusedWindowAttribute)
                ?? (inTime() ? element(app, kAXMainWindowAttribute) : nil) else { return nil }
        AXUIElementSetMessagingTimeout(window, messagingTimeout)
        guard inTime() else { return nil }
        let info = values(window, [kAXTitleAttribute, kAXDocumentAttribute, kAXDescriptionAttribute])
        var result = Result(title: info?[0] as? String, url: nil, text: "",
                            document: info?[1] as? String, windowDescription: info?[2] as? String)

        var collector = AXTextCollector(maxChars: min(maxChars, Self.maxChars), maxElements: maxElements)
        var stack: [AXUIElement] = [window]
        while let element = stack.popLast(), !collector.isFull, inTime(), collector.visit() {
            AXUIElementSetMessagingTimeout(element, messagingTimeout)   // per element, not inherited
            // Role first: a secure field's value is never requested.
            guard let head = values(element, [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
                                              kAXDescriptionAttribute, kAXChildrenAttribute]) else { continue }
            let role = head[0] as? String
            if AXTextCollector.isSecure(role: role, subrole: head[1] as? String) { continue }
            guard inTime() else { break }
            if let value: String = attribute(element, kAXValueAttribute) { collector.add(value) }
            for v in head[2...3] {
                if let s = v as? String { collector.add(s) }
            }
            if result.url == nil, role == "AXWebArea", inTime(), let u: URL = attribute(element, kAXURLAttribute) {
                result.url = u.absoluteString
            }
            // Never queue more than the element cap.
            let room = maxElements - collector.visited - stack.count
            if room > 0, let children = head[4] as? [AnyObject] {
                let elements = children.prefix(room).compactMap(asElement)
                stack.append(contentsOf: elements.reversed())   // keep document order
            }
        }
        result.text = collector.text
        return result
    }

    /// Several attributes in one round trip; missing ones come back as non-matching values.
    private static func values(_ element: AXUIElement, _ names: [String]) -> [AnyObject]? {
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(), &raw)
                == .success, let values = raw as? [AnyObject], values.count == names.count else { return nil }
        return values
    }

    private static func asElement(_ value: AnyObject) -> AXUIElement? {
        CFGetTypeID(value) == AXUIElementGetTypeID() ? unsafeDowncast(value, to: AXUIElement.self) : nil
    }

    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        return asElement(value)
    }

    /// Bridged value types only (String, URL); use `element` for AXUIElement.
    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
