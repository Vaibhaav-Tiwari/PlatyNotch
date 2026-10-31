import Foundation
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

/// Scans `Sources/PlatyNotchUI` for styles the design system forbids (spec 7, Quiet Notch
/// spec 5): text below 11 pt or above 15 pt in the panel, the 10 pt text styles, teal, tinted
/// icon squares, a light panel, monograms and bordered cards. Comment lines are skipped;
/// each failure lists file:line.
final class DesignLintTests: DefaultsTestCase {

    /// Files (relative to `Sources/PlatyNotchUI`) exempt from the text-size lints, each
    /// with its reason. Starts empty; an entry needs a reason.
    static let allowlist: [String: String] = [:]

    struct SourceLine {
        let path: String   // relative to Sources/PlatyNotchUI
        let number: Int
        let text: String
    }

    static var uiSources: URL { sources.appendingPathComponent("PlatyNotchUI") }

    /// `apps/mac/Sources`.
    static var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // PlatyNotchUITests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // apps/mac
            .appendingPathComponent("Sources")
    }

    /// Every non-comment line of every Swift file under `root` (default `Sources/PlatyNotchUI`).
    static func sourceLines(in rootURL: URL = uiSources) throws -> [SourceLine] {
        let root = rootURL.standardizedFileURL
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var lines: [SourceLine] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let path = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
                lines.append(SourceLine(path: path, number: i + 1, text: line))
            }
        }
        return lines
    }

    /// `file:line: text` for each line (outside the allowlist) where `regex` matches and
    /// `bad` accepts the match.
    static func offenders(_ pattern: String, allowlist: [String: String] = allowlist,
                          bad: (NSTextCheckingResult, NSString) -> Bool = { _, _ in true }) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        var found: [String] = []
        for line in try sourceLines() where allowlist[line.path] == nil {
            let ns = line.text as NSString
            let matches = regex.matches(in: line.text, range: NSRange(location: 0, length: ns.length))
            if matches.contains(where: { bad($0, ns) }) {
                found.append("\(line.path):\(line.number): \(line.text.trimmingCharacters(in: .whitespaces))")
            }
        }
        return found
    }

    func testScansTheSources() throws {
        XCTAssertGreaterThan(try Self.sourceLines().count, 1000, "the lint must find Sources/PlatyNotchUI")
        for (path, reason) in Self.allowlist {
            XCTAssertFalse(reason.trimmingCharacters(in: .whitespaces).isEmpty, "\(path) needs a reason")
        }
    }

    func testNoLiteralFontBelowEleven() throws {
        let found = try Self.offenders(#"\.system\(size:\s*([0-9]+(?:\.[0-9]+)?)"#) { match, ns in
            let value = Double(ns.substring(with: match.range(at: 1))) ?? 0
            return value < Double(TypeScale.minimum)
        }
        XCTAssertTrue(found.isEmpty, "text below 11 pt:\n" + found.joined(separator: "\n"))
    }

    func testNoTenPointTextStyles() throws {
        var found = try Self.offenders(#"\.font\(\s*\.(caption2?|footnote)\b"#)
        found += try Self.offenders(#"\.system\(\s*\.(caption2?|footnote)\b"#)
        XCTAssertTrue(found.isEmpty, "10 pt text styles (use DS.font(TypeScale.caption)):\n"
                      + found.joined(separator: "\n"))
    }

    /// Where tile containers live: the six tile directories and the two widget files that
    /// draw their own tiles (relative to `Sources/PlatyNotchUI`).
    static let tileDirectories = ["Views/", "Day/Views/", "Shelf/Views/", "System/Views/", "Launch/Views/",
                                  "Wellbeing/Views/", "Games/", "Games/Views/", "Camera/", "Basket/", "Library/",
                                  "Settings/", "Onboarding/"]
    static let tileFiles = ["Clipboard/ClipboardWidget.swift", "Notes/NotesWidget.swift"]

    /// `path:line` → reason for literal radii outside the scale on shapes that are not
    /// containers (progress tracks, bars). Starts empty; an entry needs a reason.
    static let radiusAllowlist: [String: String] = [:]

    // MARK: - Quiet Notch (spec 5)

    /// Panel views live outside these (relative to `Sources/PlatyNotchUI`): Settings and
    /// Onboarding are windows that follow the system, and the game boards draw their own.
    static let nonPanelDirectories = ["Settings/", "Onboarding/", "Games/Views/"]

    static func isPanel(_ path: String) -> Bool {
        !nonPanelDirectories.contains { path.hasPrefix($0) }
    }

    /// Files where the word teal may stay, each with its reason.
    static let tealAllowlist: [String: String] = [
        "Basket/BasketWindow.swift": "a basket colour the user picks and has saved (BasketColor.teal), not the panel's accent",
    ]

    /// No teal anywhere in the UI: colour is for state only (green, amber, red).
    func testNoTeal() throws {
        let found = try Self.offenders(#"(?i)\bteal\b"#, allowlist: Self.tealAllowlist)
        for (path, reason) in Self.tealAllowlist {
            XCTAssertFalse(reason.trimmingCharacters(in: .whitespaces).isEmpty, "\(path) needs a reason")
        }
        XCTAssertTrue(found.isEmpty, "teal (use white ink or a state colour):\n" + found.joined(separator: "\n"))
    }

    /// Nothing in the panel above 15 pt (`TypeScale.maximum`): literal sizes in panel views.
    func testNoFontAboveFifteen() throws {
        let regex = try NSRegularExpression(pattern: #"\.system\(size:\s*([0-9]+(?:\.[0-9]+)?)"#)
        var found: [String] = []
        for line in try Self.sourceLines() where Self.isPanel(line.path) {
            let ns = line.text as NSString
            for m in regex.matches(in: line.text, range: NSRange(location: 0, length: ns.length)) {
                let value = Double(ns.substring(with: m.range(at: 1))) ?? 0
                if value > Double(TypeScale.maximum) {
                    found.append("\(line.path):\(line.number): \(line.text.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(found.isEmpty, "type above 15 pt in the panel (use TypeScale or IconSize):\n"
                      + found.joined(separator: "\n"))
    }

    /// SF Symbols never sit on a tinted square: no rounded rectangle filled with a state or
    /// accent colour at an opacity on a line with, or just after, an `Image(systemName:`.
    func testNoTintedIconSquares() throws {
        let tinted = try NSRegularExpression(pattern:
            #"RoundedRectangle[^\n]*\.fill\((DS|Theme)\.(dynamicColor|color|tint)\([^)]*\)\.opacity\("#
            + #"|\.background\((DS|Theme)\.(dynamicColor|color|tint)\([^)]*\)(\.opacity\([^)]*\))?,\s*in:\s*RoundedRectangle"#)
        let lines = try Self.sourceLines()
        var found: [String] = []
        for (i, line) in lines.enumerated() {
            let ns = line.text as NSString
            guard tinted.firstMatch(in: line.text, range: NSRange(location: 0, length: ns.length)) != nil else { continue }
            let window = lines[max(0, i - 6)...i].filter { $0.path == line.path }
            if window.contains(where: { $0.text.contains("Image(systemName:") }) {
                found.append("\(line.path):\(line.number): \(line.text.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertTrue(found.isEmpty, "a symbol on a tinted square:\n" + found.joined(separator: "\n"))
    }

    /// The panel is always black: no light scheme outside Settings, Onboarding and the
    /// Settings renders.
    func testNoLightPanelScheme() throws {
        var found = try Self.offenders(#"colorScheme, \.light|ColorScheme\.light"#)
        found = found.filter { entry in
            !(entry.hasPrefix("Settings/") || entry.hasPrefix("Onboarding/") || entry.hasPrefix("Smoke/SettingsRenders.swift"))
        }
        XCTAssertTrue(found.isEmpty, "a light panel:\n" + found.joined(separator: "\n"))
    }

    /// Never initials: no monogram anywhere in the app's sources (Kit and UI).
    func testNoMonogram() throws {
        let regex = try NSRegularExpression(pattern: #"(?i)monogram"#)
        var found: [String] = []
        let lines = try Self.sourceLines(in: Self.sources)
        XCTAssertGreaterThan(lines.count, 10_000, "the lint must find Sources")
        for line in lines {
            let ns = line.text as NSString
            if regex.firstMatch(in: line.text, range: NSRange(location: 0, length: ns.length)) != nil {
                found.append("\(line.path):\(line.number): \(line.text.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertTrue(found.isEmpty, "monograms (show the app icon or the agent's name):\n" + found.joined(separator: "\n"))
    }

    /// Strokes allowed in Home, Agents and Views, each with its reason (`path` or `path:line`).
    static let strokeAllowlist: [String: String] = [
        "Home/DropTargetsView.swift": "the drop box's dashed outline (spec 2.2)",
        "Views/SurfaceViews.swift": "the drop peek's dashed outline, the same box as Home's",
        "Views/Theme.swift": "the keycap's 1 px hairline (spec 5.1)",
        "Views/CompactPill.swift": "the pill's progress ring, a track and its arc",
        "Views/MemoryGraphView.swift": "the memory graph's edges",
    ]

    /// No bordered cards in the panel (spec 5.3): grouping is spacing, fills and hairlines.
    func testNoBorderedCardsInPanel() throws {
        let regex = try NSRegularExpression(pattern: #"\.stroke\(|\.strokeBorder\("#)
        var found: [String] = []
        for line in try Self.sourceLines()
        where ["Home/", "Agents/", "Views/"].contains(where: { line.path.hasPrefix($0) }) {
            guard Self.strokeAllowlist[line.path] == nil, Self.strokeAllowlist["\(line.path):\(line.number)"] == nil else {
                continue
            }
            let ns = line.text as NSString
            if regex.firstMatch(in: line.text, range: NSRange(location: 0, length: ns.length)) != nil {
                found.append("\(line.path):\(line.number): \(line.text.trimmingCharacters(in: .whitespaces))")
            }
        }
        for (key, reason) in Self.strokeAllowlist {
            XCTAssertFalse(reason.trimmingCharacters(in: .whitespaces).isEmpty, "\(key) needs a reason")
        }
        XCTAssertTrue(found.isEmpty, "a bordered card in the panel (use a fill or a hairline):\n"
                      + found.joined(separator: "\n"))
    }

    func testTileContainersUseRadiusScale() throws {
        let scale = Set(Radius.scale.map { Double($0) })
        let regex = try NSRegularExpression(
            pattern: #"(?:RoundedRectangle\(cornerRadius:|\.cornerRadius\()\s*([0-9]+(?:\.[0-9]+)?)\b"#)
        var found: [String] = []
        var scanned = 0
        for line in try Self.sourceLines()
        where Self.tileDirectories.contains(where: { line.path.hasPrefix($0) && !line.path.dropFirst($0.count).contains("/") })
            || Self.tileFiles.contains(line.path) {
            scanned += 1
            let key = "\(line.path):\(line.number)"
            guard Self.radiusAllowlist[key] == nil else { continue }
            let ns = line.text as NSString
            for m in regex.matches(in: line.text, range: NSRange(location: 0, length: ns.length)) {
                let value = Double(ns.substring(with: m.range(at: 1))) ?? -1
                if !scale.contains(value) {
                    found.append("\(key): \(line.text.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 500, "the lint must find the tile sources")
        for (key, reason) in Self.radiusAllowlist {
            XCTAssertFalse(reason.trimmingCharacters(in: .whitespaces).isEmpty, "\(key) needs a reason")
        }
        XCTAssertEqual(Radius.scale, [4, 6, 8, 12, 22])
        XCTAssertTrue(found.isEmpty, "radii outside 4 / 6 / 8 / 12 / 22 (use a Radius token):\n"
                      + found.joined(separator: "\n"))
    }

    /// `.controlSize(.mini)` draws a control's text at about 9 pt. Allowed only on controls
    /// without text: a `ProgressView`, or a control whose label is hidden (`.labelsHidden()`
    /// within the three lines above, as on a switch).
    func testNoMiniTextControls() throws {
        let lines = try Self.sourceLines()
        var found: [String] = []
        for (i, line) in lines.enumerated() where line.text.contains(".controlSize(.mini)") {
            if line.text.contains("ProgressView") { continue }
            let above = lines[max(0, i - 3)..<i].filter { $0.path == line.path }
            if above.contains(where: { $0.text.contains(".labelsHidden()") }) { continue }
            found.append("\(line.path):\(line.number): \(line.text.trimmingCharacters(in: .whitespaces))")
        }
        XCTAssertTrue(found.isEmpty, "mini controls with text (use .small):\n" + found.joined(separator: "\n"))
    }

    /// One `NSColor` per (tone, alpha): the agent dot compares colours with `!=`, so a new
    /// instance per update would recolour its layer every time.
    func testDynamicColoursAreCached() {
        XCTAssertTrue(DS.dynamicNSColor(.working) === DS.dynamicNSColor(.working))
        XCTAssertTrue(DS.dynamicNSColor(.idle, alpha: 0.35) === DS.dynamicNSColor(.idle, alpha: 0.35))
        XCTAssertFalse(DS.dynamicNSColor(.idle) === DS.dynamicNSColor(.idle, alpha: 0.35))
        XCTAssertTrue(Theme.nsColor(.active) === Theme.nsColor(.active))
        XCTAssertTrue(Theme.nsColor(.off) === Theme.nsColor(.off))
    }

    func testStateToneMapping() {
        XCTAssertEqual(StateTone(AgentTone.active), .working)
        XCTAssertEqual(StateTone(AgentTone.attention), .needsYou)
        XCTAssertEqual(StateTone(AgentTone.idle), .idle)
        XCTAssertEqual(StateTone(AgentTone.off), .idle)
    }

    /// Files (relative to `Sources/PlatyNotchUI`) whose string literals may hold emoji, each
    /// with its reason. The Tasks plugin's markers (📅, 🔁) are parsed in PlatyNotchKit
    /// (`Notes/MarkdownTasks.swift`, `Notes/TaskFileWriter.swift`), outside this scan; a UI
    /// file that ever has to name a marker goes here.
    static let emojiAllowlist: [String: String] = [:]

    /// A scalar drawn as a colour emoji: emoji presentation, the emoji variation selector or
    /// the supplementary emoji planes. Text-style glyphs (↩, ⌘, ↔) are fine.
    static func isEmoji(_ s: Unicode.Scalar) -> Bool {
        s.properties.isEmojiPresentation || s.value == 0xFE0F || (0x1F000...0x1FFFF).contains(s.value)
    }

    /// No emoji in UI text or labels (user ruling, Phase 4): every string literal, single
    /// or multi-line (`"""`), raw (`#"…"#`) or not, with `\u{…}` escapes decoded.
    func testNoEmojiInStringLiterals() throws {
        XCTAssertTrue(Self.isEmoji("\u{1F4C5}"))
        XCTAssertTrue(Self.isEmoji("\u{2705}"))
        XCTAssertFalse(Self.isEmoji("\u{21A9}"))
        XCTAssertFalse(Self.isEmoji("\u{2318}"))
        let root = Self.uiSources.standardizedFileURL
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var found: [String] = []
        var scanned = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            let path = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            guard Self.emojiAllowlist[path] == nil else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for literal in Self.stringLiterals(in: text) {
                scanned += 1
                if literal.scalars.contains(where: Self.isEmoji) { found.append("\(path):\(literal.line)") }
            }
        }
        XCTAssertGreaterThan(scanned, 1000, "the scan must find the UI's string literals")
        XCTAssertTrue(found.isEmpty, "emoji in UI strings (use an SF Symbol):\n" + found.joined(separator: "\n"))
        for (path, reason) in Self.emojiAllowlist {
            XCTAssertFalse(reason.trimmingCharacters(in: .whitespaces).isEmpty, "\(path) needs a reason")
        }
    }

    /// The scanner sees every literal form and skips comments.
    func testLiteralScannerFindsEveryForm() {
        let source = #"""
        let a = "plain \u{1F4C5} escape"
        // a comment with ✅ is not a string
        let b = """
            multi ⏫ line
            """
        let c = #"raw ✅ \(not) interpolation"#
        let d = "safe ↩ \(value) and \u{21A9}"
        /* block 📅 comment */
        let e = "q\"uote ✅"
        """#
        let literals = Self.stringLiterals(in: source)
        let flagged = literals.filter { $0.scalars.contains(where: Self.isEmoji) }.map(\.line)
        XCTAssertEqual(flagged, [1, 3, 6, 9], "\(literals.map { ($0.line, String(String.UnicodeScalarView($0.scalars))) })")
    }

    /// String literals in Swift source with their first line and their scalars (escapes
    /// `\u{…}` decoded; interpolations skipped). Comments are not literals.
    static func stringLiterals(in text: String) -> [(line: Int, scalars: [Unicode.Scalar])] {
        let chars = Array(text.unicodeScalars)
        var out: [(line: Int, scalars: [Unicode.Scalar])] = []
        var i = 0
        var line = 1
        func at(_ k: Int) -> Unicode.Scalar? { k < chars.count ? chars[k] : nil }
        func starts(_ s: String, _ k: Int) -> Bool {
            for (n, c) in s.unicodeScalars.enumerated() where at(k + n) != c { return false }
            return true
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\n" { line += 1; i += 1; continue }
            if starts("//", i) {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if starts("/*", i) {
                i += 2
                while i < chars.count, !starts("*/", i) { if chars[i] == "\n" { line += 1 }; i += 1 }
                i += 2
                continue
            }
            // Opening delimiter: n × "#", then """ or ".
            var hashes = 0
            while at(i + hashes) == "#" { hashes += 1 }
            guard at(i + hashes) == "\"" else { i += max(hashes, 1); continue }
            let multi = starts("\"\"\"", i + hashes)
            let close = (multi ? "\"\"\"" : "\"") + String(repeating: "#", count: hashes)
            let escape = "\\" + String(repeating: "#", count: hashes)
            let startLine = line
            var k = i + hashes + (multi ? 3 : 1)
            var scalars: [Unicode.Scalar] = []
            while k < chars.count, !starts(close, k) {
                if chars[k] == "\n" { line += 1 }
                if starts(escape, k) {
                    let e = k + escape.unicodeScalars.count
                    if at(e) == "u", at(e + 1) == "{" {
                        var hex = ""
                        var h = e + 2
                        while let d = at(h), d != "}" { hex.unicodeScalars.append(d); h += 1 }
                        if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) { scalars.append(u) }
                        k = h + 1
                        continue
                    }
                    if at(e) == "(" {
                        var depth = 1
                        var h = e + 1
                        while h < chars.count, depth > 0 {
                            if chars[h] == "(" { depth += 1 } else if chars[h] == ")" { depth -= 1 }
                            if chars[h] == "\n" { line += 1 }
                            h += 1
                        }
                        k = h
                        continue
                    }
                    if let next = at(e) { scalars.append(next) }
                    k = e + 1
                    continue
                }
                scalars.append(chars[k])
                k += 1
            }
            out.append((line: startLine, scalars: scalars))
            i = k + close.unicodeScalars.count
        }
        return out
    }
}
