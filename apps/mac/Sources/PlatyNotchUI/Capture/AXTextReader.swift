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
    }

    /// The frontmost app's focused window.
    static func focusedWindowText(maxChars: Int) -> (title: String?, url: String?, text: String)? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        guard let r = focusedWindowText(pid: pid, maxChars: maxChars) else { return nil }
        return (r.title, r.url, r.text)
    }

    /// Depth-first over `kAXChildrenAttribute` from the focused window, collecting values,
    /// titles and descriptions, within 4 000 elements, `maxChars` (capped at 200 000) and a
    /// 150 ms deadline. Secure text fields are never read; nil when a secure text field has
    /// focus or the app has no window.
    static func focusedWindowText(pid: pid_t, maxChars: Int = maxChars) -> Result? {
        let deadline = ContinuousClock.now.advanced(by: budget)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)

        if let focused = element(app, kAXFocusedUIElementAttribute),
           AXTextCollector.isSecure(role: attribute(focused, kAXRoleAttribute),
                                    subrole: attribute(focused, kAXSubroleAttribute)) {
            return nil
        }
        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
        else { return nil }
        let title: String? = attribute(window, kAXTitleAttribute)

        var collector = AXTextCollector(maxChars: min(maxChars, Self.maxChars), maxElements: maxElements)
        var url: String?
        var stack: [AXUIElement] = [window]
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXTitleAttribute,
                     kAXDescriptionAttribute, kAXChildrenAttribute] as CFArray
        while let element = stack.popLast(), !collector.isFull, ContinuousClock.now < deadline, collector.visit() {
            AXUIElementSetMessagingTimeout(element, messagingTimeout)   // per element, not inherited
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(), &raw)
                    == .success, let values = raw as? [AnyObject], values.count == 6 else { continue }
            let role = values[0] as? String
            if AXTextCollector.isSecure(role: role, subrole: values[1] as? String) { continue }
            if url == nil, role == "AXWebArea", let u: URL = attribute(element, kAXURLAttribute) {
                url = u.absoluteString
            }
            for v in values[2...4] {
                if let s = v as? String { collector.add(s) }
            }
            if let children = values[5] as? [AnyObject] {
                stack.append(contentsOf: children.reversed().compactMap(asElement))   // keep document order
            }
        }
        return Result(title: title, url: url, text: collector.text)
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
