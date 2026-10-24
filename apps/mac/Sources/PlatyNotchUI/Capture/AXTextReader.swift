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
    /// Steps up from the focused element looking for the outermost page (`AXWebArea`).
    static let maxParentSteps = 40


    /// Sets the process-wide default messaging timeout once (the system-wide element's
    /// timeout applies to every element that has none of its own).
    private static let globalTimeout: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }()

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
        let focus = readFocus(app, inTime: inTime)
        if case .stop(let outcome) = focus { return outcome }
        var page: AXUIElement?
        if case .page(let p) = focus { page = p }
        guard inTime() else { return .noWindow }
        let (found, refusal) = readWindow(app, inTime: inTime)
        if let refusal { return refusal }
        guard let window = found, inTime() else { return .noWindow }
        AXUIElementSetMessagingTimeout(window, messagingTimeout)
        let info = values(window, [kAXTitleAttribute, kAXDocumentAttribute, kAXDescriptionAttribute])
        var result = AXWindowText(title: info?[0] as? String, url: nil, text: "",
                                  document: info?[1] as? String, windowDescription: info?[2] as? String)

        // The page is read first only if it is in this window: the private-window
        // check sees this window's title, never another's.
        page = AXTreeWalk.page(page, in: window, inTime: inTime, windowOf: windowOf, same: { CFEqual($0, $1) })
        let (text, url) = collect(window: window, page: page, maxChars: maxChars, inTime: inTime)
        result.text = text
        result.url = url
        return .text(result)
    }

    /// The focused window, else the main window; or why there is none to read.
    private static func readWindow(_ app: AXUIElement, inTime: () -> Bool) -> (AXUIElement?, AXReadOutcome?) {
        var (window, error) = element(app, kAXFocusedWindowAttribute)
        if window == nil, inTime() { (window, error) = element(app, kAXMainWindowAttribute) }
        if error == .apiDisabled { return (nil, .accessibilityUnavailable) }
        return (window, nil)
    }

    private enum Focus {
        case page(AXUIElement?)
        case stop(AXReadOutcome)
    }

    /// The focused element: a stop when it is a secure field (nothing is read) or
    /// Accessibility refuses; else the outermost page holding it, if any.
    private static func readFocus(_ app: AXUIElement, inTime: () -> Bool) -> Focus {
        let (focused, error) = element(app, kAXFocusedUIElementAttribute)
        if error == .apiDisabled { return .stop(.accessibilityUnavailable) }
        guard let focused else { return .page(nil) }
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)
        guard inTime() else { return .stop(.noWindow) }
        let head = values(focused, [kAXRoleAttribute, kAXSubroleAttribute])
        let role = head?[0] as? String
        if AXTextCollector.isSecure(role: role, subrole: head?[1] as? String) { return .stop(.passwordField) }
        return .page(AXTreeWalk.outermostWebArea(from: focused, role: role, maxSteps: maxParentSteps,
                                                 inTime: inTime, parent: parentOf, role: roleOf))
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

    private static func parentOf(_ e: AXUIElement) -> AXUIElement? {
        guard let parent = element(e, kAXParentAttribute).0 else { return nil }
        AXUIElementSetMessagingTimeout(parent, messagingTimeout)
        return parent
    }

    private static func roleOf(_ e: AXUIElement) -> String? { attribute(e, kAXRoleAttribute) }

    private static func windowOf(_ e: AXUIElement) -> AXUIElement? { element(e, kAXWindowAttribute).0 }

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

/// `AXManualAccessibility` on a real process. Chromium and Electron apps (Chrome,
/// Slack, VS Code, Discord, Notion...) expose almost no text until an assistive app
/// sets it. `AXEnhancedUserInterface` is not used: it slows window animations and
/// confuses window managers. Call off the main actor.
struct LiveManualAccessibilityAX: ManualAccessibilityAX {
    static let attribute = "AXManualAccessibility"

    func isSettable(pid: pid_t) -> Bool {
        var settable: DarwinBoolean = false
        let app = Self.app(pid)
        return AXUIElementIsAttributeSettable(app, Self.attribute as CFString, &settable) == .success && settable.boolValue
    }

    func isOn(pid: pid_t) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(Self.app(pid), Self.attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    func set(_ on: Bool, pid: pid_t) {
        _ = AXUIElementSetAttributeValue(Self.app(pid), Self.attribute as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
    }

    private static func app(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, AXTextReader.messagingTimeout)
        return app
    }
}
