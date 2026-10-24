import AppKit
import AVFoundation
import CoreText
import Foundation
import ImageIO
import PlatyNotchKit
import UniformTypeIdentifiers
import Vision
import XCTest
@testable import PlatyNotchUI

/// Task 2: the real file actions on small files made here (images drawn in the test, a
/// tone, a few video frames, archives made by ditto). Nothing of the user's is read.
@MainActor
final class FileActionsEngineTests: DefaultsTestCase {
    nonisolated(unsafe) private let fm = FileManager.default
    nonisolated(unsafe) private var root: URL!
    private let engine = SystemFileActions()

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("FileActionsEngineTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func folder(_ name: String = UUID().uuidString) throws -> URL {
        let url = root.appendingPathComponent("out-\(name)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func type(of url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceGetType(src) as String?
    }

    // MARK: - Images

    func testConvertImageToEveryTarget() async throws {
        let png = try Fixtures.png(at: root.appendingPathComponent("photo.png"), width: 40, height: 30, transparent: true)
        let writable = SystemFileActions.writableImageTypes
        for target in ConversionMatrix.targets(for: .png) {
            if target != .pdf, !writable.contains(target.identifier) { continue }   // HEIC on some Macs
            let out = try await engine.perform(.convert(target, nil), sources: [png], into: try folder())
            guard case .file(let url) = out else { return XCTFail("no file") }
            XCTAssertEqual(url.pathExtension, target.preferredFilenameExtension)
            XCTAssertEqual(FileNames.split(url.lastPathComponent).base, "photo")
            if target == .pdf {
                XCTAssertEqual(CGPDFDocument(url as CFURL)?.numberOfPages, 1)
            } else {
                XCTAssertEqual(type(of: url), target.identifier)
            }
        }
        // The source is untouched and nothing was written beside it (R11).
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix("out-") }, ["photo.png"])
    }

    /// JPEG has no alpha: a transparent PNG becomes white, not black.
    func testTransparentToJPEGIsWhite() async throws {
        let png = try Fixtures.png(at: root.appendingPathComponent("clear.png"), width: 8, height: 8, transparent: true)
        let out = try await engine.perform(.convert(.jpeg, nil), sources: [png], into: try folder())
        guard case .file(let url) = out else { return XCTFail("no file") }
        let image = try SystemFileActions.uprightImage(url)
        let corner = Fixtures.pixel(image, x: 0, y: 0)
        XCTAssertGreaterThan(corner.r, 240)
        XCTAssertGreaterThan(corner.g, 240)
    }

    func testCombineImagesIntoOnePDF() async throws {
        let a = try Fixtures.png(at: root.appendingPathComponent("a.png"), width: 20, height: 10)
        let b = try Fixtures.png(at: root.appendingPathComponent("b.png"), width: 10, height: 20)
        let out = try await engine.perform(.combinePDF, sources: [a, b], into: try folder())
        guard case .file(let url) = out else { return XCTFail("no file") }
        XCTAssertEqual(url.lastPathComponent, "a and 1 more.pdf")
        let doc = try XCTUnwrap(CGPDFDocument(url as CFURL))
        XCTAssertEqual(doc.numberOfPages, 2)
        XCTAssertEqual(doc.page(at: 2)?.getBoxRect(.mediaBox).size, CGSize(width: 10, height: 20), "each page its image's size")
    }

    func testUnreadableImage() async throws {
        let bad = root.appendingPathComponent("bad.png")
        try Data("not an image".utf8).write(to: bad)
        do {
            _ = try await engine.perform(.convert(.jpeg, nil), sources: [bad], into: try folder())
            XCTFail("converted junk")
        } catch {
            XCTAssertEqual(error as? FileActionError, .unreadable)
        }
    }

    // MARK: - OCR (Vision, on this Mac)

    /// Vision's text recognizer is missing on some CI machines: skip, saying so.
    private func requireTextRecognition() throws {
        let languages = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
        guard !languages.isEmpty else { throw XCTSkip("Vision text recognition is not available on this machine") }
    }

    func testCopyTextReadsRenderedText() async throws {
        try requireTextRecognition()
        let png = try Fixtures.textImage(at: root.appendingPathComponent("shot.png"), text: "PLATYNOTCH SHELF 2026")
        let out = try await engine.perform(.copyText, sources: [png], into: nil)
        guard case .text(let text) = out else { return XCTFail("no text") }
        XCTAssertTrue(text.uppercased().contains("PLATYNOTCH"), text)
    }

    func testCopyTextReadsAPDF() async throws {
        try requireTextRecognition()
        let pdf = try Fixtures.textPDF(at: root.appendingPathComponent("page.pdf"), text: "HELLO PLATYPUS")
        let out = try await engine.perform(.copyText, sources: [pdf], into: nil)
        guard case .text(let text) = out else { return XCTFail("no text") }
        XCTAssertTrue(text.uppercased().contains("PLATYPUS"), text)
    }

    func testCopyTextOnABlankImage() async throws {
        try requireTextRecognition()
        let png = try Fixtures.png(at: root.appendingPathComponent("blank.png"), width: 64, height: 64)
        do {
            _ = try await engine.perform(.copyText, sources: [png], into: nil)
            XCTFail("found text in a blank image")
        } catch {
            XCTAssertEqual(error as? FileActionError, .noText)
        }
    }

    /// Subject lifting depends on the Mac (and finds nothing in flat test art): whatever
    /// happens, a result is a PNG in the given folder, else a typed error.
    func testRemoveBackgroundGivesAPNGOrSaysWhy() async throws {
        let png = try Fixtures.textImage(at: root.appendingPathComponent("subject.png"), text: "●")
        let out = try folder()
        do {
            let result = try await engine.perform(.removeBackground, sources: [png], into: out)
            guard case .file(let url) = result else { return XCTFail("no file") }
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, out.standardizedFileURL)
            XCTAssertEqual(url.lastPathComponent, "subject (no background).png")
            XCTAssertEqual(type(of: url), UTType.png.identifier)
        } catch let e as FileActionError {
            XCTAssertTrue(e == .noSubject || e == .unavailable, "said why: \(e)")
        }
    }

    /// Fix round 1: cancelling reaches work on a background thread (it stops between pages).
    func testCancelReachesBackgroundWork() async throws {
        let png = try Fixtures.png(at: root.appendingPathComponent("big.png"), width: 3000, height: 3000)
        let sources = Array(repeating: png, count: SystemFileActions.maxPDFImages)
        let out = try folder()
        let task = Task { [engine] in try await engine.perform(.combinePDF, sources: sources, into: out) }
        try await Task.sleep(for: .milliseconds(50))
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("finished despite the cancel")
        } catch {
            XCTAssertEqual(error as? FileActionError, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "stopped soon, not after all 100 pages")
    }

    func testCombineCap() async throws {
        let png = try Fixtures.png(at: root.appendingPathComponent("p.png"), width: 4, height: 4)
        do {
            _ = try await engine.perform(.combinePDF, sources: Array(repeating: png, count: 101), into: try folder())
            XCTFail("combined 101")
        } catch {
            XCTAssertEqual(error as? FileActionError, .tooMany(100))
        }
    }

    /// Images handed to Vision are at most 4096 px on their longest side.
    func testVisionInputIsCapped() throws {
        let png = try Fixtures.png(at: root.appendingPathComponent("wide.png"), width: 6000, height: 1500)
        let image = try SystemFileActions.uprightImage(png, maxPixels: SystemFileActions.maxVisionPixels)
        XCTAssertEqual(max(image.width, image.height), 4096)
        XCTAssertEqual(try SystemFileActions.uprightImage(png).width, 6000, "full size elsewhere")
    }

    // MARK: - Audio and video (AVFoundation)

    func testAudioToM4AAndBackToWAV() async throws {
        let wav = try Fixtures.tone(at: root.appendingPathComponent("tone.wav"), seconds: 0.5)
        let m4a = try await engine.perform(.convert(.mpeg4Audio, nil), sources: [wav], into: try folder("m4a"))
        guard case .file(let m4aURL) = m4a else { return XCTFail("no file") }
        XCTAssertEqual(m4aURL.pathExtension, "m4a")
        let file = try AVAudioFile(forReading: m4aURL)
        XCTAssertEqual(file.fileFormat.settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        let back = try await engine.perform(.convert(.wav, nil), sources: [m4aURL], into: try folder("wav"))
        guard case .file(let wavURL) = back else { return XCTFail("no file") }
        let pcm = try AVAudioFile(forReading: wavURL)
        XCTAssertEqual(Double(pcm.length) / pcm.fileFormat.sampleRate, 0.5, accuracy: 0.1)
    }

    func testVideoToMP4() async throws {
        let mov = try await Fixtures.movie(at: root.appendingPathComponent("clip.mov"))
        let out: FileActionOutput
        do {
            out = try await engine.perform(.convert(.mpeg4Movie, .h264), sources: [mov], into: try folder())
        } catch FileActionError.unsupported {
            throw XCTSkip("this Mac cannot export H.264")
        }
        guard case .file(let url) = out else { return XCTFail("no file") }
        XCTAssertEqual(url.lastPathComponent, "clip.mp4")
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
    }

    // MARK: - Archives (ditto, R9)

    func testZipAndUnzipRoundTrip() async throws {
        let src = root.appendingPathComponent("Project")
        try fm.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: src.appendingPathComponent("a.txt"))
        try Data("two".utf8).write(to: src.appendingPathComponent("sub/b.txt"))
        let zipFolder = try folder("zip")
        let zipped = try await engine.perform(.zip, sources: [src], into: zipFolder)
        guard case .file(let zip) = zipped else { return XCTFail("no file") }
        XCTAssertEqual(zip.lastPathComponent, "Project.zip")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: zipFolder.path), ["Project.zip"], "no partial left")

        let unzipped = try await engine.perform(.unzip, sources: [zip], into: try folder("unzip"))
        guard case .file(let dir) = unzipped else { return XCTFail("no folder") }
        XCTAssertEqual(dir.lastPathComponent, "Project")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("Project/sub/b.txt"), encoding: .utf8), "two")
    }

    func testUnzipRefusesAboveTheCap() async throws {
        let src = root.appendingPathComponent("big.bin")
        try Data(repeating: 0, count: 200_000).write(to: src)
        guard case .file(let zip) = try await engine.perform(.zip, sources: [src], into: try folder("z")) else {
            return XCTFail("no zip")
        }
        var capped = SystemFileActions()
        capped.unzipCap = 100_000
        let out = try folder("u")
        do {
            _ = try await capped.perform(.unzip, sources: [zip], into: out)
            XCTFail("unzipped past the cap")
        } catch {
            XCTAssertEqual(error as? FileActionError, .tooLarge(100_000))
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: out.path), [], "nothing written")
    }

    func testUnzipRefusesZipSlip() async throws {
        let zip = try Fixtures.storedZip(at: root.appendingPathComponent("evil.zip"), name: "../evil.txt", contents: Data("x".utf8))
        let out = try folder()
        do {
            _ = try await engine.perform(.unzip, sources: [zip], into: out)
            XCTFail("unzipped a zip slip")
        } catch {
            XCTAssertEqual(error as? FileActionError, .unsafeArchive)
        }
        XCTAssertFalse(fm.fileExists(atPath: out.deletingLastPathComponent().appendingPathComponent("evil.txt").path))
    }

    /// Fix round 2: an entry the directory does not list (ditto would extract it) is
    /// refused before anything runs. The reviewer's B3 archive (Kit fixtures).
    func testUnzipRefusesAHiddenEntry() async throws {
        let b3 = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PlatyNotchKitTests/Fixtures/zips/B3_hidden_slip.zip")
        var never = SystemFileActions()
        never.ditto = ProcessRunner(executableURL: URL(fileURLWithPath: "/nonexistent/ditto"), stopsOnCancel: true)
        let out = try folder()
        do {
            _ = try await never.perform(.unzip, sources: [b3], into: out)
            XCTFail("unzipped a hidden entry")
        } catch {
            XCTAssertEqual(error as? FileActionError, .unsafeArchive)
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: out.path), [])
    }

    /// Fix round 3: honest headers, a lying stream (declares 9 bytes, inflates to 200 MB:
    /// the reviewer's D). PlatyNotch's extractor stops at the declared size; nothing is left.
    func testUnzipStopsAStreamThatInflatesPastItsSize() async throws {
        let d = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PlatyNotchKitTests/Fixtures/zips/D_deflate_decl9_real200M.zip")
        let out = try folder()
        let started = Date()
        do {
            _ = try await engine.perform(.unzip, sources: [d], into: out)
            XCTFail("kept what it wrote")
        } catch {
            XCTAssertEqual(error as? FileActionError, .damagedArchive)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "stopped at once")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: out.path), [], "nothing left")
    }

    /// Cancelling an unzip stops the extractor between chunks and deletes what it wrote.
    func testCancelledUnzipLeavesNothing() async throws {
        let src = root.appendingPathComponent("big.bin")
        var bytes = [UInt8](repeating: 0, count: 64 << 20)
        for i in stride(from: 0, to: bytes.count, by: 4096) { bytes[i] = UInt8(truncatingIfNeeded: i >> 12) }
        try Data(bytes).write(to: src)
        guard case .file(let zip) = try await engine.perform(.zip, sources: [src], into: try folder("z")) else {
            return XCTFail("no zip")
        }
        let out = try folder("u")
        let task = Task { [engine] in try await engine.perform(.unzip, sources: [zip], into: out) }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do {
            _ = try await task.value
            // A fast machine may finish 64 MB first; then the result is whole.
        } catch {
            XCTAssertEqual(error as? FileActionError, .cancelled)
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: out.path), [], "what it wrote is deleted")
        }
    }

    /// Fix round 2: not enough free space: refused before anything is written.
    func testUnzipNeedsFreeSpace() async throws {
        let src = root.appendingPathComponent("f.txt")
        try Data("x".utf8).write(to: src)
        guard case .file(let zip) = try await engine.perform(.zip, sources: [src], into: try folder("z")) else {
            return XCTFail("no zip")
        }
        var full = SystemFileActions()
        full.freeSpaceAt = { _ in 1_000 }
        let out = try folder("u")
        do {
            _ = try await full.perform(.unzip, sources: [zip], into: out)
            XCTFail("unzipped onto a full disk")
        } catch {
            XCTAssertEqual(error as? FileActionError, .notEnoughSpace)
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: out.path), [])
    }

    /// R9: a cancelled zip stops ditto and deletes the partial archive.
    func testCancelledZipDeletesThePartial() async throws {
        // Stands in for ditto: writes the partial (its last argument), then waits.
        let fake = root.appendingPathComponent("slow-ditto")
        try "#!/bin/sh\nfor a; do last=$a; done\necho partial > \"$last\"\nexec sleep 30\n".write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        var slow = SystemFileActions()
        slow.ditto = ProcessRunner(executableURL: fake, stopsOnCancel: true)
        let out = try folder()
        let src = try Fixtures.png(at: root.appendingPathComponent("p.png"), width: 4, height: 4)
        let task = Task { try await slow.perform(.zip, sources: [src], into: out) }
        let partial = out.appendingPathComponent("p.png.zip.partial")
        let started = await eventually { self.fm.fileExists(atPath: partial.path) }
        XCTAssertTrue(started)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("finished")
        } catch {
            XCTAssertEqual(error as? FileActionError, .cancelled)
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: out.path), [], "the partial is gone")
    }
}

/// Small files made in the test.
enum Fixtures {
    static func png(at url: URL, width: Int, height: Int, transparent: Bool = false) throws -> URL {
        let ctx = try context(width, height)
        if transparent {
            ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        } else {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        try write(ctx, to: url)
        return url
    }

    /// Black text on white, large enough for OCR.
    static func textImage(at url: URL, text: String) throws -> URL {
        let ctx = try context(900, 200)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 200))
        draw(text, in: ctx, at: CGPoint(x: 30, y: 70))
        try write(ctx, to: url)
        return url
    }

    static func textPDF(at url: URL, text: String) throws -> URL {
        var box = CGRect(x: 0, y: 0, width: 612, height: 200)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw FileActionError.unsupported }
        ctx.beginPage(mediaBox: &box)
        draw(text, in: ctx, at: CGPoint(x: 30, y: 80))
        ctx.endPage()
        ctx.closePDF()
        return url
    }

    private static func draw(_ text: String, in ctx: CGContext, at point: CGPoint) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 56, nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
        return (data[0], data[1], data[2])
    }

    private static func context(_ w: Int, _ h: Int) throws -> CGContext {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FileActionError.unsupported }
        return ctx
    }

    private static func write(_ ctx: CGContext, to url: URL) throws {
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw FileActionError.unsupported
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw FileActionError.unsupported }
    }

    /// A 440 Hz tone, 16-bit mono WAV.
    static func tone(at url: URL, seconds: Double) throws -> URL {
        let rate = 44_100.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(frames) { samples[i] = Float(sin(2 * Double.pi * 440 * Double(i) / rate) * 0.5) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }

    /// Ten 64×64 frames of H.264 in a MOV.
    static func movie(at url: URL) async throws -> URL {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FileActionError.unsupported }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw FileActionError.unsupported }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 20), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? FileActionError.unsupported }
        return url
    }

    /// A one-entry stored (uncompressed) ZIP with any entry name (for zip-slip tests).
    static func storedZip(at url: URL, name: String, contents: Data) throws -> URL {
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let n = Data(name.utf8)
        let size = UInt32(contents.count)
        var local = le(UInt32(0x0403_4B50)) + le(UInt16(20)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt32(0))
        local += le(UInt32(0)) + le(size) + le(size) + le(UInt16(n.count)) + le(UInt16(0)) + n + contents
        var central = le(UInt32(0x0201_4B50)) + le(UInt16(20)) + le(UInt16(20)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt32(0))
        central += le(UInt32(0)) + le(size) + le(size) + le(UInt16(n.count)) + le(UInt16(0)) + le(UInt16(0))
        central += le(UInt16(0)) + le(UInt16(0)) + le(UInt32(0)) + le(UInt32(0)) + n
        var end = le(UInt32(0x0605_4B50)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(1)) + le(UInt16(1))
        end += le(UInt32(central.count)) + le(UInt32(local.count)) + le(UInt16(0))
        try (local + central + end).write(to: url)
        return url
    }
}
