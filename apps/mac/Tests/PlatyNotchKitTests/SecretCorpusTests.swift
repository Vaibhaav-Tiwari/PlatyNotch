import Foundation
import XCTest
@testable import PlatyNotchKit

/// Round 2 (B3): how often the clipboard's skip rule fires on generated text that holds no
/// secret, and on real card formats. Seeded, so the rates are the same on every run; they
/// are printed (`SECRET-CORPUS …`) and pinned.
final class SecretCorpusTests: XCTestCase {
    /// A small seeded generator (SplitMix64).
    private struct Rand {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.count))
        }
        mutating func digits(_ n: Int) -> String {
            String((0..<n).map { i in Character(String(i == 0 ? int(1...9) : int(0...9))) })
        }
    }

    static let size = 2_000

    private func rate(_ name: String, _ make: (inout Rand) -> String) -> Double {
        var r = Rand(state: 42)
        var hits = 0
        for _ in 0..<Self.size where SecretText.containsSecret(make(&r)) { hits += 1 }
        let pct = 100 * Double(hits) / Double(Self.size)
        print(String(format: "SECRET-CORPUS %@: %.1f%% skipped (%d of %d)", name, pct, hits, Self.size))
        return pct
    }

    private static func date(_ r: inout Rand) -> String {
        String(format: "%04d-%02d-%02d", r.int(1990...2030), r.int(1...12), r.int(1...28))
    }

    /// A Luhn-valid number of `n` digits.
    private static func card(_ r: inout Rand, _ n: Int) -> String {
        var d = (0..<(n - 1)).map { i in i == 0 ? r.int(3...6) : r.int(0...9) }
        for check in 0...9 where SecretText.luhn((d + [check]).map(UInt8.init)) {
            d.append(check)
            break
        }
        return d.map(String.init).joined()
    }

    private static func grouped(_ s: String, _ sizes: [Int], _ sep: String) -> String {
        var out: [String] = []
        var i = s.startIndex
        for n in sizes {
            let j = s.index(i, offsetBy: n)
            out.append(String(s[i..<j]))
            i = j
        }
        return out.joined(separator: sep)
    }

    func testNoSecretCorporaAreNotSkipped() {
        var results: [String: Double] = [:]
        results["spreadsheet rows (tab)"] = rate("spreadsheet rows (tab)") { r in
            (0..<8).map { _ in r.digits(r.int(1...6)) }.joined(separator: "\t")
        }
        results["spreadsheet rows (space)"] = rate("spreadsheet rows (space)") { r in
            (0..<8).map { _ in r.digits(r.int(1...6)) }.joined(separator: " ")
        }
        results["two dates"] = rate("two dates") { r in "\(Self.date(&r)) \(Self.date(&r))" }
        results["three dates"] = rate("three dates") { r in "\(Self.date(&r)) \(Self.date(&r)) \(Self.date(&r))" }
        results["date + time + amount"] = rate("date + time + amount") { r in
            "\(Self.date(&r)) \(r.int(10...23)):\(r.int(10...59)) \(r.digits(r.int(3...7)))"
        }
        results["git SHA"] = rate("git SHA") { r in
            String((0..<40).map { _ in Array("0123456789abcdef")[r.int(0...15)] })
        }
        results["UUID"] = rate("UUID") { r in
            [8, 4, 4, 4, 12].map { n in String((0..<n).map { _ in Array("0123456789ABCDEF")[r.int(0...15)] }) }
                .joined(separator: "-")
        }
        results["non-Luhn order numbers"] = rate("non-Luhn order numbers") { r in
            var n = r.digits(r.int(13...19))
            while SecretText.luhn(n.compactMap { $0.wholeNumberValue }.map(UInt8.init)) { n = r.digits(n.count) }
            return "Order #\(n)"
        }
        results["phone numbers"] = rate("phone numbers") { r in
            "+1 \(r.digits(3)) \(r.digits(3)) \(r.digits(4)), +44 \(r.digits(4)) \(r.digits(6))"
        }
        for (name, pct) in results { XCTAssertEqual(pct, 0, name) }
    }

    func testRealCardFormatsAreSkipped() {
        let formats: [(String, (inout Rand) -> String)] = [
            ("4-4-4-4 spaces", { r in Self.grouped(Self.card(&r, 16), [4, 4, 4, 4], " ") }),
            ("4-4-4-4 dashes", { r in Self.grouped(Self.card(&r, 16), [4, 4, 4, 4], "-") }),
            ("16 contiguous", { r in Self.card(&r, 16) }),
            ("Amex 4-6-5", { r in Self.grouped(Self.card(&r, 15), [4, 6, 5], " ") }),
            ("Amex 15 contiguous", { r in Self.card(&r, 15) }),
            ("in a sentence", { r in "my card is \(Self.grouped(Self.card(&r, 16), [4, 4, 4, 4], " ")), exp 12/27" }),
            ("with expiry", { r in "\(Self.grouped(Self.card(&r, 16), [4, 4, 4, 4], " ")) 12/27" }),
        ]
        for (name, make) in formats { XCTAssertEqual(rate(name, make), 100, name) }
    }
}
