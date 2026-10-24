import ApplicationServices
import AppKit
import PlatyNotchKit

/// Reads the visible text of an app's focused window through the Accessibility API.
/// Call off the main actor: each AX call can block up to the messaging timeout.
enum AXTextReader {
    static let maxElements = 4_000
    static let maxChars = 200_000
    /// 150 ms ran out in a browser's tab strip before the page was reached.
    static let budget: Duration = .milliseconds(400)
    static let messagingTimeout: Float = 0.25
    /// Steps up from the focused element looking for the page (`AXWebArea`) that holds it.
    static let maxParentSteps = 40

    /// Asks Chromium and Electron apps (Chrome, Slack, VS Code, Discord, Notion...) to
    /// build their accessibility tree: they expose almost no text until an assistive
    /// app sets it. Other apps ignore the attribute. `AXEnhancedUserInterface` is not
    /// used: it slows window animations and confuses window managers.
    static let manualAccessibility = "AXManualAccessibility"

    /// Sets the process-wide default messaging timeout once (the system-wide element's
    /// timeout applies to every element that has none of its own).
    private static let globalTimeout: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }()

    /// Turns on Chromium/Electron accessibility for `pid` (once per process is enough).
    static func enableManualAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        _ = AXUIElementSetAttributeValue(app, manualAccessibility as CFString, kCFBooleanTrue)
    }

    /// Walks the focused window (the focused page first, toolbars last; see
    /// `AXTreeWalk`), collecting values, titles and descriptions, within 4 000
    /// elements, `maxChars` (capped at 200 000) and a 400 ms deadline checked before
    /// every AX call site. Every element gets the 0.25 s messaging timeout before it is
    /// read. Secure text fields are never read (their value is not even requested).
    static func focusedWindowText(pid: pid_t, maxChars: Int = maxChars) -> AXReadOutcome {
        _ = globalTimeout
        let deadline = ContinuousClock.now.advanced(by: budget)
        func inTime() -> Bool { ContinuousClock.now < deadline }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)

        guard inTime() else { return .noWindow }
        let (focused, focusError) = element(app, kAXFocusedUIElementAttribute)
        if focusError == .apiDisabled { return .accessibilityUnavailable }
        var page: AXUIElement?
        if let focused {
            AXUIElementSetMessagingTimeout(focused, messagingTimeout)
            guard inTime() else { return .noWindow }
            let head = values(focused, [kAXRoleAttribute, kAXSubroleAttribute])
            if AXTextCollector.isSecure(role: head?[0] as? String, subrole: head?[1] as? String) { return .passwordField }
            page = webArea(containing: focused, role: head?[0] as? String, inTime: inTime)
        }
        guard inTime() else { return .noWindow }
        var (window, windowError) = element(app, kAXFocusedWindowAttribute)
        if window == nil, inTime() { (window, windowError) = element(app, kAXMainWindowAttribute) }
        if windowError == .apiDisabled { return .accessibilityUnavailable }
        guard let window, inTime() else { return .noWindow }
        AXUIElementSetMessagingTimeout(window, messagingTimeout)
        let info = values(window, [kAXTitleAttribute, kAXDocumentAttribute, kAXDescriptionAttribute])
        var result = AXWindowText(title: info?[0] as? String, url: nil, text: "",
                                  document: info?[1] as? String, windowDescription: info?[2] as? String)

        // The page is read first only if it is in this window: the private-window
        // check sees this window's title, never another's.
        if let p = page, !isInWindow(p, window, inTime: inTime) { page = nil }
        let (text, url) = collect(window: window, page: page, maxChars: maxChars, inTime: inTime)
        result.text = text
        result.url = url
        return .text(result)
    }

    private static func isInWindow(_ element: AXUIElement, _ window: AXUIElement, inTime: () -> Bool) -> Bool {
        guard inTime(), let owner = self.element(element, kAXWindowAttribute).0 else { return false }
        return CFEqual(owner, window)
    }

    /// The window's text (and the page URL, if a web area is reached).
    private static func collect(window: AXUIElement, page: AXUIElement?, maxChars: Int,
                                inTime: () -> Bool) -> (text: String, url: String?) {
        var url: String?
        var collector = AXTextCollector(maxChars: min(maxChars, Self.maxChars), maxElements: maxElements)
        AXTreeWalk.collect(
            root: window, first: page, into: &collector, inTime: inTime,
            same: { CFEqual($0, $1) },
            head: readHead,
            value: { e in attribute(e, kAXValueAttribute) },
            visit: { e, h in
                guard url == nil, h.role == "AXWebArea", inTime() else { return }
                let u: URL? = attribute(e, kAXURLAttribute)
                url = u?.absoluteString
            })
        return (collector.text, url)
    }

    /// One element's head, after giving it the messaging timeout (per element, not inherited).
    private static func readHead(_ e: AXUIElement) -> AXElementHead<AXUIElement>? {
        AXUIElementSetMessagingTimeout(e, messagingTimeout)
        return head(e)
    }

    /// The `AXWebArea` holding the focused element, if any (the page in a browser or
    /// an Electron app).
    private static func webArea(containing focused: AXUIElement, role: String?,
                                inTime: () -> Bool) -> AXUIElement? {
        var current = focused
        var currentRole = role
        for _ in 0..<maxParentSteps {
            if currentRole == "AXWebArea" { return current }
            if currentRole == "AXWindow" || currentRole == "AXApplication" { return nil }
            guard inTime(), let parent = element(current, kAXParentAttribute).0 else { return nil }
            AXUIElementSetMessagingTimeout(parent, messagingTimeout)
            current = parent
            currentRole = attribute(parent, kAXRoleAttribute)
        }
        return nil
    }

    private static func head(_ element: AXUIElement) -> AXElementHead<AXUIElement>? {
        guard let v = values(element, [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
                                       kAXDescriptionAttribute, kAXChildrenAttribute]) else { return nil }
        let children = (v[4] as? [AnyObject] ?? []).compactMap(asElement)
        return AXElementHead(role: v[0] as? String, subrole: v[1] as? String, title: v[2] as? String,
                             description: v[3] as? String, children: children)
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

    private static func element(_ element: AXUIElement, _ name: String) -> (AXUIElement?, AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard error == .success, let value else { return (nil, error) }
        return (asElement(value), error)
    }

    /// Bridged value types only (String, URL); use `element` for AXUIElement.
    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
