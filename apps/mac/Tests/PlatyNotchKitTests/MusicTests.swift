import CoreGraphics
import Foundation
import XCTest
@testable import PlatyNotchKit

final class MusicTests: XCTestCase {
    private func line(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - Spectrum bands

    private func sine(_ freq: Double, sampleRate: Double = 48_000, count: Int = 2048, amplitude: Float = 0.8) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * .pi * freq * Double($0) / sampleRate)) }
    }

    func testSineHitsRightBand() {
        let bands = 12
        for freq in [200.0, 1_000.0, 5_000.0] {
            let levels = SpectrumBands.compute(samples: sine(freq), sampleRate: 48_000, bands: bands)
            XCTAssertEqual(levels.count, bands)
            let peak = levels.indices.max { levels[$0] < levels[$1] }!
            let edges = SpectrumBands.bandEdges(bands: bands)
            XCTAssertTrue(edges[peak] <= freq && freq < edges[peak + 1],
                          "\(freq) Hz peaked in band \(peak) [\(edges[peak]), \(edges[peak + 1]))")
            XCTAssertGreaterThan(levels[peak], 0.7)
            for (i, v) in levels.enumerated() { XCTAssertTrue((0...1).contains(v), "band \(i) = \(v)") }
        }
    }

    func testSilenceIsZero() {
        XCTAssertEqual(SpectrumBands.compute(samples: [Float](repeating: 0, count: 1024), sampleRate: 48_000, bands: 8),
                       [Float](repeating: 0, count: 8))
        // too few samples is padded, never a crash
        XCTAssertEqual(SpectrumBands.compute(samples: [], sampleRate: 44_100, bands: 3), [0, 0, 0])
        XCTAssertEqual(SpectrumBands.compute(samples: [1, 2], sampleRate: 44_100, bands: 0), [])
    }

    func testBandEdgesAreLogSpaced() {
        let edges = SpectrumBands.bandEdges(bands: 4)
        XCTAssertEqual(edges.count, 5)
        XCTAssertEqual(edges.first!, 60, accuracy: 0.001)
        XCTAssertEqual(edges.last!, 12_000, accuracy: 0.01)
        let ratios = (0..<4).map { edges[$0 + 1] / edges[$0] }
        for r in ratios { XCTAssertEqual(r, ratios[0], accuracy: 1e-9) }
    }

    func testEveryBandGetsABin() {
        // 1024-point FFT at 48 kHz: 46.9 Hz bins; the narrow low bands still read one bin each.
        let ranges = SpectrumBands.binRanges(bands: 16, sampleRate: 48_000, size: SpectrumBands.fftSize)
        XCTAssertEqual(ranges.count, 16)
        for r in ranges {
            XCTAssertFalse(r.isEmpty)
            XCTAssertTrue(r.lowerBound >= 1 && r.upperBound <= SpectrumBands.fftSize / 2)
        }
    }

    func testLevelMapping() {
        XCTAssertEqual(SpectrumBands.level(amplitude: 0), 0)
        XCTAssertEqual(SpectrumBands.level(amplitude: 1), 1, accuracy: 1e-6)
        XCTAssertEqual(SpectrumBands.level(amplitude: 10), 1)   // clamped
        XCTAssertEqual(SpectrumBands.level(amplitude: 0.001), 0, accuracy: 1e-6)   // -60 dB floor
        let mid = SpectrumBands.level(amplitude: 0.0316)   // -30 dB
        XCTAssertEqual(mid, 0.5, accuracy: 0.01)
    }

    func testSmootherAttackRelease() {
        var s = BarSmoother(bands: 2, attack: 0.6, release: 0.12)
        var out = s.push([1, 0])
        XCTAssertEqual(out[0], 0.6, accuracy: 1e-6)   // fast attack
        XCTAssertEqual(out[1], 0)
        out = s.push([1, 0])
        XCTAssertEqual(out[0], 0.84, accuracy: 1e-6)
        out = s.push([0, 0])
        XCTAssertEqual(out[0], 0.84 * 0.88, accuracy: 1e-6)   // slow release
        // a wrong-sized input is padded / trimmed to the band count
        XCTAssertEqual(s.push([1]).count, 2)
        XCTAssertEqual(s.push([1, 1, 1]).count, 2)
        s.reset()
        XCTAssertEqual(s.push([0, 0]), [0, 0])
    }

    /// Privacy: the analyser keeps at most one FFT window of samples, in memory, and what it
    /// hands out is band levels only (no samples, nothing that could be written or sent).
    func testAnalyserOutputHoldsOnlyBandLevels() {
        var a = SpectrumAnalyser(bands: 6)
        let tenSeconds = sine(440, count: 48_000 * 10)
        for chunk in stride(from: 0, to: tenSeconds.count, by: 512) {
            a.push(Array(tenSeconds[chunk..<min(chunk + 512, tenSeconds.count)]), sampleRate: 48_000)
        }
        XCTAssertLessThanOrEqual(a.retainedSampleCount, SpectrumBands.fftSize)
        let out = a.levels()
        XCTAssertEqual(out.values.count, 6)
        XCTAssertTrue(out.values.allSatisfy { (0...1).contains($0) })
        let stored = Mirror(reflecting: out).children.map { $0.label ?? "" }
        XCTAssertEqual(stored, ["values"])
        a.clear()
        XCTAssertEqual(a.retainedSampleCount, 0)
        XCTAssertEqual(a.levels().values, [Float](repeating: 0, count: 6))
    }

    func testAnalyserMixesStereoToMono() {
        var a = SpectrumAnalyser(bands: 4)
        // interleaved L/R with R = -L cancels to silence
        let l = sine(1_000, count: 1024)
        var interleaved: [Float] = []
        for v in l { interleaved.append(v); interleaved.append(-v) }
        a.push(interleaved: interleaved, channels: 2, sampleRate: 48_000)
        XCTAssertEqual(a.retainedSampleCount, 1024)
        XCTAssertEqual(a.levels().values, [0, 0, 0, 0])
    }

    // MARK: - Dominant colour

    private func image(_ pixels: [(UInt8, UInt8, UInt8)], width: Int, height: Int) -> CGImage {
        var bytes: [UInt8] = []
        for p in pixels { bytes += [p.0, p.1, p.2, 255] }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    func testDominantColorIgnoresBlack() {
        // A red band over 3/4 black: the black is ignored, so the colour is red.
        let w = 32, h = 32
        let pixels: [(UInt8, UInt8, UInt8)] = (0..<(w * h)).map { $0 / w < h / 4 ? (220, 30, 30) : (0, 0, 0) }
        let c = DominantColor.of(cgImage: image(pixels, width: w, height: h))
        XCTAssertGreaterThan(c.r, 0.6)
        XCTAssertLessThan(c.g, 0.25)
        XCTAssertLessThan(c.b, 0.25)
    }

    func testDominantColorIgnoresWhite() {
        let pixels: [(UInt8, UInt8, UInt8)] = (0..<256).map { $0 % 2 == 0 ? (255, 255, 255) : (20, 60, 200) }
        let c = DominantColor.of(cgImage: image(pixels, width: 16, height: 16))
        XCTAssertGreaterThan(c.b, 0.6)
        XCTAssertLessThan(c.r, 0.2)
    }

    func testDominantColorAllBlackFallsBack() {
        let c = DominantColor.of(pixels: [0, 0, 0, 255, 0, 0, 0, 255])
        XCTAssertEqual(c.r, 0, accuracy: 0.001)
        XCTAssertEqual(c.g, 0, accuracy: 0.001)
        let none = DominantColor.of(pixels: [])
        XCTAssertEqual(none.r, DominantColor.fallback.r)
    }

    // MARK: - Playback clock

    func testPlaybackClockClamps() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let c = PlaybackClock(elapsed: 50, duration: 60, rate: 1, at: t0)
        XCTAssertEqual(c.position(now: t0), 50)
        XCTAssertEqual(c.position(now: t0.addingTimeInterval(5)), 55)
        XCTAssertEqual(c.position(now: t0.addingTimeInterval(500)), 60)   // clamps to duration
        XCTAssertEqual(c.position(now: t0.addingTimeInterval(-500)), 0)   // never negative
        XCTAssertEqual(c.progress(now: t0.addingTimeInterval(10)), 1)
        XCTAssertEqual(c.remaining(now: t0), 10)

        let paused = PlaybackClock(elapsed: 12, duration: 60, rate: 0, at: t0)
        XCTAssertEqual(paused.position(now: t0.addingTimeInterval(30)), 12)

        let fast = PlaybackClock(elapsed: 0, duration: 60, rate: 2, at: t0)
        XCTAssertEqual(fast.position(now: t0.addingTimeInterval(3)), 6)

        let unknownLength = PlaybackClock(elapsed: 5, duration: 0, rate: 1, at: t0)
        XCTAssertEqual(unknownLength.position(now: t0.addingTimeInterval(5)), 10)
        XCTAssertEqual(unknownLength.progress(now: t0), 0)
    }

    func testPlaybackClockFromInfo() {
        let now = Date(timeIntervalSince1970: 2_000)
        var info = NowPlayingInfo(bundleIdentifier: "x", title: "T", isPlaying: true)
        XCTAssertNil(PlaybackClock(info: info, now: now))   // no times
        info.elapsed = 10
        info.duration = 100
        info.timestamp = now.addingTimeInterval(-2)
        info.rate = 1
        XCTAssertEqual(PlaybackClock(info: info, now: now)?.position(now: now), 12)
        info.isPlaying = false   // paused: rate is 0 whatever the player said
        XCTAssertEqual(PlaybackClock(info: info, now: now)?.position(now: now), 10)
        info.isPlaying = true
        info.rate = nil          // playing with no rate: 1
        info.timestamp = nil     // no timestamp: as of now
        XCTAssertEqual(PlaybackClock(info: info, now: now)?.position(now: now.addingTimeInterval(1)), 11)
        let sought = PlaybackClock(info: info, now: now)!.seeking(to: 500, at: now)
        XCTAssertEqual(sought.position(now: now), 100)
    }

    // MARK: - Stream parser fields (mediaremote-adapter v0.7.7)

    func testParserReadsTimesInMicros() {
        // Captured from `stream --micros --no-artwork` (v0.7.7), Safari playing in WebKit.
        var p = MediaRemoteStreamParser()
        p.feed(line(#"{"type":"data","diff":false,"payload":{"playbackRate":1,"timestampEpochMicros":1792788521081085,"album":"","elapsedTimeMicros":922635260,"playing":true,"bundleIdentifier":"com.apple.WebKit.GPU","parentApplicationBundleIdentifier":"com.apple.Safari","processIdentifier":17298,"title":"We Paddle","uniqueIdentifier":8251012,"artist":"SIG07","contentItemIdentifier":"8251012","durationMicros":927373500}}"#))
        let c = p.current
        XCTAssertEqual(c?.elapsed ?? -1, 922.635260, accuracy: 1e-6)
        XCTAssertEqual(c?.duration ?? -1, 927.3735, accuracy: 1e-6)
        XCTAssertEqual(c?.rate, 1)
        XCTAssertEqual(c?.timestamp?.timeIntervalSince1970 ?? 0, 1_792_788_521.081085, accuracy: 1e-5)
        XCTAssertEqual(c?.parentBundleIdentifier, "com.apple.Safari")
        XCTAssertEqual(c?.appBundleIdentifier, "com.apple.Safari")

        // a seek: diff with the new elapsed time and timestamp only
        p.feed(line(#"{"type":"data","diff":true,"payload":{"elapsedTimeMicros":1000000,"timestampEpochMicros":1792788600000000}}"#))
        XCTAssertEqual(p.current?.elapsed, 1)
        XCTAssertEqual(p.current?.duration ?? -1, 927.3735, accuracy: 1e-6)
        XCTAssertEqual(p.current?.timestamp?.timeIntervalSince1970, 1_792_788_600)

        // a vanished key is removed
        p.feed(line(#"{"type":"data","diff":true,"payload":{"durationMicros":null,"playbackRate":null}}"#))
        XCTAssertNil(p.current?.duration)
        XCTAssertNil(p.current?.rate)
    }

    func testParserReadsTimesInSeconds() {
        // Without --micros the adapter prints seconds and a second-precision UTC date.
        var p = MediaRemoteStreamParser()
        p.feed(line(#"{"type":"data","diff":false,"payload":{"playbackRate":0,"elapsedTime":44.5,"timestamp":"2026-10-23T19:21:58Z","bundleIdentifier":"b","title":"X","playing":false,"duration":47.6}}"#))
        XCTAssertEqual(p.current?.elapsed, 44.5)
        XCTAssertEqual(p.current?.duration, 47.6)
        XCTAssertEqual(p.current?.rate, 0)
        XCTAssertEqual(p.current?.timestamp, ISO8601DateFormatter().date(from: "2026-10-23T19:21:58Z"))
        XCTAssertNil(p.current?.parentBundleIdentifier)
        XCTAssertEqual(p.current?.appBundleIdentifier, "b")
    }

    func testAppleScriptTimes() {
        let sep = NowPlayingInfo.appleScriptSeparator
        let now = Date(timeIntervalSince1970: 5)
        let info = NowPlayingInfo.parseAppleScript(["com.spotify.client", "playing", "Song", "Band", "12500", "200000"]
            .joined(separator: sep), now: now)
        XCTAssertEqual(info?.elapsed, 12.5)
        XCTAssertEqual(info?.duration, 200)
        XCTAssertEqual(info?.rate, 1)
        XCTAssertEqual(info?.timestamp, now)
        let paused = NowPlayingInfo.parseAppleScript(["com.apple.Music", "paused", "T", "", "1000", "x"]
            .joined(separator: sep), now: now)
        XCTAssertEqual(paused?.rate, 0)
        XCTAssertEqual(paused?.elapsed, 1)
        XCTAssertNil(paused?.duration)   // unreadable number: unknown, not 0
    }
}
