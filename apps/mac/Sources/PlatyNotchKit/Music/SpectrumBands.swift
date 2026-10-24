import Accelerate
import Foundation

/// Audio samples → a few bar levels for the music visualiser: Hann window, a 1024-point
/// vDSP FFT, log-spaced bands from 60 Hz to 12 kHz, each the loudest bin in the band on a
/// 60 dB scale (0 silent … 1 full scale). Smoothing over time is `BarSmoother`'s job.
public enum SpectrumBands {
    public static let fftSize = 1024
    public static let lowHz = 60.0
    public static let highHz = 12_000.0
    /// The quietest level that still shows (maps to 0).
    public static let floorDB = -60.0

    public static func compute(samples: [Float], sampleRate: Double, bands: Int) -> [Float] {
        guard bands > 0 else { return [] }
        let fft = SpectrumFFT(size: fftSize)
        var window = [Float](repeating: 0, count: fftSize)
        // The last `fftSize` samples, zero-padded in front when there are fewer.
        let tail = samples.suffix(fftSize)
        window.replaceSubrange((fftSize - tail.count)..<fftSize, with: tail)
        return fft.levels(of: window, sampleRate: sampleRate, bands: bands)
    }

    /// `bands + 1` edges in Hz, evenly spaced on a log scale from `lowHz` to `highHz`.
    public static func bandEdges(bands: Int) -> [Double] {
        guard bands > 0 else { return [] }
        return (0...bands).map { lowHz * pow(highHz / lowHz, Double($0) / Double(bands)) }
    }

    /// For each band, the FFT bins (1 ..< size/2) whose centre frequency falls in it; a band
    /// narrower than one bin reads the bin nearest its centre, so no band is always 0.
    public static func binRanges(bands: Int, sampleRate: Double, size: Int) -> [Range<Int>] {
        let edges = bandEdges(bands: bands)
        let binHz = sampleRate / Double(size)
        let lastBin = size / 2 - 1
        guard lastBin >= 1, binHz > 0 else { return Array(repeating: 1..<1, count: max(bands, 0)) }
        return (0..<bands).map { i in
            let lo = max(1, Int((edges[i] / binHz).rounded(.up)))
            let hi = min(lastBin + 1, Int((edges[i + 1] / binHz).rounded(.up)))
            if lo < hi { return lo..<hi }
            let centre = Int((sqrt(edges[i] * edges[i + 1]) / binHz).rounded())
            let bin = min(max(centre, 1), lastBin)
            return bin..<(bin + 1)
        }
    }

    /// Linear amplitude (1 = full-scale sine) → 0…1 on a `floorDB` … 0 dB scale.
    public static func level(amplitude: Float) -> Float {
        guard amplitude > 0 else { return 0 }
        let db = 20 * log10(Double(amplitude))
        return Float(min(max((db - floorDB) / -floorDB, 0), 1))
    }
}

/// A reusable vDSP FFT and its scratch buffers (not thread-safe: one user at a time).
/// Only the returned levels are allocated per call.
public final class SpectrumFFT {
    public let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var hann: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var magnitudes: [Float]
    private var windowed: [Float]
    private var ranges: [Range<Int>] = []
    private var rangesKey: (Double, Int) = (0, 0)

    public init(size: Int) {
        self.size = size
        log2n = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        hann = [Float](repeating: 0, count: size)
        vDSP_hann_window(&hann, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
        real = [Float](repeating: 0, count: size / 2)
        imag = [Float](repeating: 0, count: size / 2)
        magnitudes = [Float](repeating: 0, count: size / 2)
        windowed = [Float](repeating: 0, count: size)
    }

    /// Zeroes every scratch buffer (what is left of the last audio analysed).
    public func clear() {
        for i in real.indices { real[i] = 0; imag[i] = 0; magnitudes[i] = 0 }
        for i in windowed.indices { windowed[i] = 0 }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// `samples` must hold exactly `size` values (oldest first).
    public func levels(of samples: [Float], sampleRate: Double, bands: Int) -> [Float] {
        precondition(samples.count == size)
        if rangesKey != (sampleRate, bands) {
            ranges = SpectrumBands.binRanges(bands: bands, sampleRate: sampleRate, size: size)
            rangesKey = (sampleRate, bands)
        }
        vDSP_vmul(samples, 1, hann, 1, &windowed, 1, vDSP_Length(size))
        let half = size / 2
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }
        // A sine of amplitude A peaks at A·N/2 in the DFT, halved by the Hann window's
        // coherent gain (A·N/4), doubled by zrip's scaling (A·N/2): A = magnitude · 2/N.
        let scale = 2 / Float(size)
        return ranges.map { r in
            var peak: Float = 0
            for k in r where magnitudes[k] > peak { peak = magnitudes[k] }
            return SpectrumBands.level(amplitude: peak * scale)
        }
    }
}

/// Band levels: all the visualiser ever hands out of the audio it hears.
public struct BandLevels: Equatable, Sendable {
    public let values: [Float]
    public init(values: [Float]) { self.values = values }
}

/// Keeps the latest `SpectrumBands.fftSize` mono samples (in memory only, overwritten as
/// audio arrives; nothing else is kept) and reduces them to `BandLevels` on demand.
/// Not thread-safe: the caller serialises `push` and `levels`. Non-copyable: it owns its
/// FFT scratch, which copies would otherwise share.
public struct SpectrumAnalyser: ~Copyable {
    public let bands: Int
    private var ring: [Float]
    private var write = 0
    private var filled = 0
    private var sampleRate: Double = 48_000
    private let fft = SpectrumFFT(size: SpectrumBands.fftSize)

    public init(bands: Int) {
        self.bands = max(bands, 0)
        ring = [Float](repeating: 0, count: SpectrumBands.fftSize)
    }

    /// How many samples are held (never more than one FFT window).
    public var retainedSampleCount: Int { filled }

    public mutating func push(_ mono: [Float], sampleRate: Double) {
        mono.withUnsafeBufferPointer { push(interleaved: $0, channels: 1, sampleRate: sampleRate) }
    }

    public mutating func push(interleaved: [Float], channels: Int, sampleRate: Double) {
        interleaved.withUnsafeBufferPointer { push(interleaved: $0, channels: channels, sampleRate: sampleRate) }
    }

    /// Mixes `channels` interleaved channels to mono into the ring (no allocation).
    public mutating func push(interleaved: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Double) {
        guard channels > 0, sampleRate > 0 else { return }
        self.sampleRate = sampleRate
        let frames = interleaved.count / channels
        let n = ring.count
        let inv = 1 / Float(channels)
        for f in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += interleaved[f * channels + c] }
            ring[write] = sum * inv
            write = (write + 1) % n
        }
        filled = min(n, filled + frames)
    }

    /// Forgets every sample, including what the last FFT left in its buffers.
    public mutating func clear() {
        for i in ring.indices { ring[i] = 0 }
        write = 0
        filled = 0
        fft.clear()
    }

    /// Copies the held samples, oldest first, into `buffer` (`SpectrumBands.fftSize` long,
    /// allocated by the caller; no allocation here, so it is cheap under a lock). Returns
    /// how many are real samples and their rate.
    public func copySamples(into buffer: inout [Float]) -> (count: Int, sampleRate: Double) {
        precondition(buffer.count == ring.count)
        let n = ring.count
        for i in 0..<n { buffer[i] = ring[(write + i) % n] }
        return (filled, sampleRate)
    }

    public func levels() -> BandLevels {
        guard bands > 0 else { return BandLevels(values: []) }
        guard filled > 0 else { return BandLevels(values: [Float](repeating: 0, count: bands)) }
        // Oldest first.
        let ordered = Array(ring[write...] + ring[..<write])
        return BandLevels(values: fft.levels(of: ordered, sampleRate: sampleRate, bands: bands))
    }
}

/// Fast attack, slow release per bar, so bars jump with a beat and fall gently.
public struct BarSmoother: Equatable, Sendable {
    public let attack: Float
    public let release: Float
    public private(set) var current: [Float]

    public init(bands: Int, attack: Float = 0.6, release: Float = 0.12) {
        self.attack = attack
        self.release = release
        current = [Float](repeating: 0, count: max(bands, 0))
    }

    /// Moves each bar toward `v` (padded with 0 / trimmed to the band count) and returns them.
    public mutating func push(_ v: [Float]) -> [Float] {
        for i in current.indices {
            let target = i < v.count ? v[i] : 0
            let k = target > current[i] ? attack : release
            current[i] += (target - current[i]) * k
        }
        return current
    }

    public mutating func reset() {
        for i in current.indices { current[i] = 0 }
    }
}
