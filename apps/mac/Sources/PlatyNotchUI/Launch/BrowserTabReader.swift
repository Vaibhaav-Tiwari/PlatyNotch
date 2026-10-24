import AppKit
import Foundation
import PlatyNotchKit

/// What "Add current tab" found.
enum TabReadResult: Equatable, Sendable {
    case url(URL, SupportedBrowser)
    /// None of Safari, Chrome or Arc is running (none is ever launched).
    case noBrowser
    case noWindow(SupportedBrowser)
    /// The tab's address is not http or https (a start page, a file, a PDF viewer…).
    case notWebPage(SupportedBrowser)
    /// Automation for that browser is turned off for PlatyNotch.
    case denied(SupportedBrowser)
    case timedOut(SupportedBrowser)
    case failed(SupportedBrowser, Int)
}

/// Reads the front browser tab's address. The only code that sends Apple Events to a
/// browser, so the only thing that can raise a browser Automation prompt; called only
/// from the "Add current tab" button. Tests and smoke runs use a fake.
protocol BrowserTabReading: Sendable {
    @MainActor func currentTab() async -> TabReadResult
}

/// `SupportedBrowser.script` (constant AppleScript, nothing spliced in) for the frontmost
/// running browser, else the first running one. Runs on its own queue, never the main
/// thread; the script itself gives up after 5 s and the caller after `timeout`.
struct AppleScriptTabReader: BrowserTabReading {
    static let timeout: Double = 8
    private static let queue = DispatchQueue(label: "dev.platynotch.launch.browser-tab", qos: .userInitiated)

    @MainActor func currentTab() async -> TabReadResult {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let browser = SupportedBrowser.pick(frontmost: front, running: running) else { return .noBrowser }
        let source = browser.script
        let outcome = await Self.execute(source)
        return Self.result(outcome, browser: browser)
    }

    enum ScriptOutcome: Sendable, Equatable {
        case value(String)
        case failure(Int)
    }

    static func result(_ outcome: ScriptOutcome, browser: SupportedBrowser) -> TabReadResult {
        switch outcome {
        case .value(let text):
            if text.isEmpty { return .noWindow(browser) }
            guard let url = SiteURL.parse(text), text.lowercased().hasPrefix("http") else { return .notWebPage(browser) }
            return .url(url, browser)
        case .failure(let code):
            switch code {
            case -1743: return .denied(browser)
            case -1712: return .timedOut(browser)
            case -600, -609: return .noBrowser
            case -1728, -1719: return .noWindow(browser)
            default: return .failed(browser, code)
            }
        }
    }

    private static func execute(_ source: String) async -> ScriptOutcome {
        await withCheckedContinuation { (cont: CheckedContinuation<ScriptOutcome, Never>) in
            let once = ResumeOnce(cont)
            queue.async { once.resume(runScript(source)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(.failure(-1712)) }
        }
    }

    /// Fresh NSAppleScript per call (compiled and run on `queue`).
    private nonisolated static func runScript(_ source: String) -> ScriptOutcome {
        guard let script = NSAppleScript(source: source) else { return .failure(-1) }
        var error: NSDictionary?
        let out = script.executeAndReturnError(&error)
        if let error { return .failure((error[NSAppleScript.errorNumber] as? Int) ?? -1) }
        return .value(out.stringValue ?? "")
    }
}

/// Resumes a continuation once; later calls are ignored.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Never>?

    init(_ cont: CheckedContinuation<T, Never>) { self.cont = cont }

    func resume(_ value: T) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

/// Never sends an Apple Event (smoke runs).
struct NoBrowserTabs: BrowserTabReading {
    @MainActor func currentTab() async -> TabReadResult { .noBrowser }
}
