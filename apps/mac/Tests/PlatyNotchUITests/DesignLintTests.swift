import Foundation
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

/// Scans `Sources/PlatyNotchUI` for styles the design system forbids (spec 7): text below
/// 11 pt, and the 10 pt text styles (`.caption`, `.caption2`, `.footnote` on macOS).
/// Comment lines are skipped; each failure lists file:line.
final class DesignLintTests: DefaultsTestCase {

    /// Files (relative to `Sources/PlatyNotchUI`) exempt from the text-size lints, each
    /// with its reason. Starts empty; an entry needs a reason.
    static let allowlist: [String: String] = [:]

    struct SourceLine {
        let path: String   // relative to Sources/PlatyNotchUI
        let number: Int
        let text: String
    }

    static var uiSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // PlatyNotchUITests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // apps/mac
            .appendingPathComponent("Sources/PlatyNotchUI")
    }

    /// Every non-comment line of every Swift file under `Sources/PlatyNotchUI`.
    static func sourceLines() throws -> [SourceLine] {
        let root = uiSources.standardizedFileURL
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

    func testStateToneMapping() {
        XCTAssertEqual(StateTone(AgentTone.active), .working)
        XCTAssertEqual(StateTone(AgentTone.attention), .needsYou)
        XCTAssertEqual(StateTone(AgentTone.idle), .idle)
        XCTAssertEqual(StateTone(AgentTone.off), .idle)
    }
}
