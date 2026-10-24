import AVFoundation
import CoreImage
import Foundation
import ImageIO
import PlatyNotchKit
import UniformTypeIdentifiers
import Vision

/// One file action from a shelf item's "Actions ›" menu (Batch rename is separate:
/// `FileActionCenter.rename`).
enum FileAction: Equatable, Sendable {
    /// To `type`; `codec` only for an MP4 made from a video.
    case convert(UTType, VideoCodec?)
    case compress(VideoQuality)
    case combinePDF
    case zip
    case unzip
    /// OCR (Vision, on this Mac), put on the pasteboard.
    case copyText
    case removeBackground

    /// Whether it writes a file (into a fresh owned folder, R11).
    var makesFile: Bool { self != .copyText }

    /// What the card says while it runs.
    var progressTitle: String {
        switch self {
        case .convert: "Converting…"
        case .compress: "Compressing…"
        case .combinePDF: "Making PDF…"
        case .zip: "Zipping…"
        case .unzip: "Unzipping…"
        case .copyText: "Reading text…"
        case .removeBackground: "Removing background…"
        }
    }

    /// "convert", for "Couldn't convert a.heic: …".
    var verb: String {
        switch self {
        case .convert: "convert"
        case .compress: "compress"
        case .combinePDF: "make a PDF of"
        case .zip: "zip"
        case .unzip: "unzip"
        case .copyText: "read text in"
        case .removeBackground: "remove the background of"
        }
    }
}

/// What an action made.
enum FileActionOutput: Equatable, Sendable {
    /// A file or folder inside the folder it was given.
    case file(URL)
    case text(String)
}

enum FileActionError: Error, Equatable, LocalizedError {
    case unreadable
    case unsupported
    case tooLarge(UInt64)
    case unsafeArchive
    case noSubject
    case noText
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: "the file can't be read"
        case .unsupported: "this Mac can't make that kind of file"
        case .tooLarge(let cap): "it would unpack to more than \(ByteCountFormatter.string(fromByteCount: Int64(cap), countStyle: .binary))"
        case .unsafeArchive: "the archive has files that would land outside its folder"
        case .noSubject: "no subject was found"
        case .noText: "no text was found"
        case .cancelled: "cancelled"
        case .failed(let why): why
        }
    }
}

/// Runs file actions (a seam: tests use a fake). `folder` is a fresh owned folder for
/// actions that write a file, nil for Copy Text. Cancelling the calling task stops the work.
protocol FileActionPerforming: Sendable {
    func perform(_ action: FileAction, sources: [URL], into folder: URL?) async throws -> FileActionOutput
}

/// The real actions: ImageIO, AVFoundation, Vision and `/usr/bin/ditto`, all on this Mac
/// (no network). Sources are only read; every result is written into `folder`, never
/// beside the source (R11). Work runs off the main thread.
struct SystemFileActions: FileActionPerforming {
    /// ZIP and unzip runs (R9): long archives are not killed at the default 60 s.
    static let archiveTimeout: Duration = .seconds(30 * 60)
    /// Unzip refuses an archive that would unpack to more than this (R9).
    static let defaultUnzipCap: UInt64 = 2 << 30
    /// At most this many PDF pages are read for Copy Text.
    static let maxOCRPages = 50

    var unzipCap: UInt64 = defaultUnzipCap
    var ditto = ProcessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/ditto"), stopsOnCancel: true)

    func perform(_ action: FileAction, sources: [URL], into folder: URL?) async throws -> FileActionOutput {
        guard let first = sources.first else { throw FileActionError.unreadable }
        if action == .copyText { return .text(try await Self.recognizeText(first)) }
        guard let folder else { throw FileActionError.failed("no folder to write into") }
        switch action {
        case .convert(let type, let codec):
            switch ConversionMatrix.family(of: Self.type(of: first)) {
            case .image: return .file(try await Self.detached { try Self.convertImage(first, to: type, into: folder) })
            case .video:
                let preset = codec?.exportPreset ?? VideoCodec.h264.exportPreset
                return .file(try await Self.exportVideo(first, preset: preset, type: type, into: folder))
            case .audio: return .file(try await Self.detached { try Self.convertAudio(first, to: type, into: folder) })
            case nil: throw FileActionError.unsupported
            }
        case .compress(let quality):
            return .file(try await Self.exportVideo(first, preset: quality.exportPreset, type: .mpeg4Movie, into: folder))
        case .combinePDF:
            return .file(try await Self.detached { try Self.combinePDF(sources, into: folder) })
        case .zip: return .file(try await zip(first, into: folder))
        case .unzip: return .file(try await unzip(first, into: folder))
        case .removeBackground:
            return .file(try await Self.detached { try Self.removeBackground(first, into: folder) })
        case .copyText: throw FileActionError.unsupported   // handled above
        }
    }

    /// Synchronous work on a background thread; a cancel before it starts throws.
    private static func detached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    static func type(of url: URL) -> UTType {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension) ?? .data
    }

    /// `<folder>/<source name>.<ext>`.
    static func output(_ source: URL, ext: String, in folder: URL, suffix: String = "") -> URL {
        let base = FileNames.split(FileNames.safe(source.lastPathComponent)).base
        return folder.appendingPathComponent(FileNames.join(base + suffix, ext))
    }

    // MARK: - Images (ImageIO)

    /// What ImageIO can write on this Mac (HEIC is missing on some).
    static var writableImageTypes: Set<String> {
        Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    }

    /// The first image of `url`, turned upright (EXIF orientation applied).
    static func uprightImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw FileActionError.unreadable
        }
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0, h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw FileActionError.unreadable
        }
        return image
    }

    static func convertImage(_ src: URL, to type: UTType, into folder: URL) throws -> URL {
        let out = output(src, ext: type.preferredFilenameExtension ?? "img", in: folder)
        if type == .pdf {
            try writePDF([src], to: out)
            return out
        }
        guard writableImageTypes.contains(type.identifier) else { throw FileActionError.unsupported }
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw FileActionError.unreadable
        }
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
            throw FileActionError.unsupported
        }
        if type == .jpeg, let flat = try flattenedIfTransparent(source) {
            // JPEG has no alpha: transparent parts become white rather than black.
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            CGImageDestinationAddImage(dest, flat, props)
        } else {
            CGImageDestinationAddImageFromSource(dest, source, 0, nil)   // keeps metadata and orientation
        }
        guard CGImageDestinationFinalize(dest) else { throw FileActionError.failed("the image could not be written") }
        return out
    }

    private static func flattenedIfTransparent(_ source: CGImageSource) throws -> CGImage? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw FileActionError.unreadable }
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return nil
        default: break
        }
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    /// Several images: one PDF, a page per image (in order), each page the image's size.
    static func combinePDF(_ sources: [URL], into folder: URL) throws -> URL {
        let first = FileNames.split(FileNames.safe(sources.first?.lastPathComponent ?? "Images")).base
        let out = folder.appendingPathComponent(FileNames.join("\(first) and \(sources.count - 1) more", "pdf"))
        try writePDF(sources, to: out)
        return out
    }

    private static func writePDF(_ sources: [URL], to out: URL) throws {
        let images = try sources.map(uprightImage)
        guard let ctx = CGContext(out as CFURL, mediaBox: nil, nil) else { throw FileActionError.failed("the PDF could not be written") }
        for image in images {
            try Task.checkCancellation()
            var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            ctx.beginPage(mediaBox: &box)
            ctx.draw(image, in: box)
            ctx.endPage()
        }
        ctx.closePDF()
    }

    // MARK: - Video and audio (AVFoundation)

    static func exportVideo(_ src: URL, preset: String, type: UTType, into folder: URL) async throws -> URL {
        let fileType: AVFileType = type == .quickTimeMovie ? .mov : .mp4
        let out = output(src, ext: type == .quickTimeMovie ? "mov" : "mp4", in: folder)
        let asset = AVURLAsset(url: src)
        guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: fileType),
              let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw FileActionError.unsupported
        }
        do {
            try await session.export(to: out, as: fileType)
        } catch is CancellationError {
            throw FileActionError.cancelled
        } catch {
            if Task.isCancelled { throw FileActionError.cancelled }
            throw FileActionError.failed(error.localizedDescription)
        }
        return out
    }

    /// M4A (AAC, 192 kbit/s) or WAV (16-bit PCM), at the source's rate and channels.
    static func convertAudio(_ src: URL, to type: UTType, into folder: URL) throws -> URL {
        let wav = type.conforms(to: .wav)
        let out = output(src, ext: wav ? "wav" : "m4a", in: folder)
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: src) } catch { throw FileActionError.unreadable }
        let format = input.processingFormat
        let settings: [String: Any] = wav
            ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
               AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16,
               AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
               AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: 192_000]
        do {
            let output = try AVAudioFile(forWriting: out, settings: settings, commonFormat: format.commonFormat,
                                         interleaved: format.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { throw FileActionError.unsupported }
            while input.framePosition < input.length {
                if Task.isCancelled { throw FileActionError.cancelled }
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
        } catch let e as FileActionError {
            throw e
        } catch {
            throw FileActionError.failed(error.localizedDescription)
        }
        return out
    }

    // MARK: - Archives (ditto, R9)

    /// `<folder>/<name>.zip`, written as `.zip.partial` and renamed when ditto succeeds;
    /// the partial is deleted on failure, timeout or cancel.
    func zip(_ src: URL, into folder: URL) async throws -> URL {
        let name = FileNames.safe(src.lastPathComponent) + ".zip"
        let final = folder.appendingPathComponent(name)
        let partial = folder.appendingPathComponent(name + ".partial")
        let r = await ditto.run(["-c", "-k", "--sequesterRsrc", "--keepParent", src.path, partial.path],
                                timeout: Self.archiveTimeout)
        guard r.status == 0, !r.cancelled, !r.timedOut else {
            try? FileManager.default.removeItem(at: partial)
            if r.cancelled { throw FileActionError.cancelled }
            throw FileActionError.failed(r.timedOut ? "it took longer than 30 minutes" : Self.firstLine(r.combined, or: "ditto failed"))
        }
        guard ShelfStore.renameExclusive(partial, final) == 0 else {
            try? FileManager.default.removeItem(at: partial)
            throw FileActionError.failed("the archive could not be named")
        }
        return final
    }

    /// Into `<folder>/<archive name>/`. Refused when the archive declares more than
    /// `unzipCap` bytes or has unsafe names; stopped (and deleted) if what is written
    /// grows past the cap anyway (checked every second while it runs).
    func unzip(_ src: URL, into folder: URL) async throws -> URL {
        guard let summary = ZipInspector.summary(of: src) else { throw FileActionError.unreadable }
        guard !summary.hasUnsafeNames else { throw FileActionError.unsafeArchive }
        let cap = unzipCap
        guard summary.uncompressedBytes <= cap else { throw FileActionError.tooLarge(cap) }
        let dest = folder.appendingPathComponent(FileNames.split(FileNames.safe(src.lastPathComponent)).base)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        let ditto = self.ditto
        let run = Task { await ditto.run(["-x", "-k", src.path, dest.path], timeout: Self.archiveTimeout) }
        let watch = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Self.size(of: dest) > cap {
                    run.cancel()
                    return true
                }
            }
            return false
        }
        let r = await withTaskCancellationHandler { await run.value } onCancel: { run.cancel() }
        watch.cancel()
        let overCap = await watch.value || Self.size(of: dest) > cap
        guard r.status == 0, !r.cancelled, !r.timedOut, !overCap else {
            try? FileManager.default.removeItem(at: dest)
            if overCap { throw FileActionError.tooLarge(cap) }
            if r.cancelled { throw FileActionError.cancelled }
            throw FileActionError.failed(r.timedOut ? "it took longer than 30 minutes" : Self.firstLine(r.combined, or: "ditto failed"))
        }
        return dest
    }

    /// Bytes on disk under `url` (never follows links).
    static func size(of url: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in walker {
            total += UInt64((try? file.resourceValues(forKeys: Set(keys)))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private static func firstLine(_ text: String, or fallback: String) -> String {
        text.split(separator: "\n").first.map(String.init) ?? fallback
    }

    // MARK: - Vision (on this Mac)

    /// Accurate text recognition of an image, or of a PDF's pages (at most `maxOCRPages`),
    /// lines in reading order.
    static func recognizeText(_ url: URL) async throws -> String {
        let pdf = type(of: url).conforms(to: .pdf)
        let text = try await detached { () throws -> String in
            let images = pdf ? try pdfPages(url) : [try uprightImage(url)]
            var pages: [String] = []
            for image in images {
                if Task.isCancelled { throw FileActionError.cancelled }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                } catch {
                    throw FileActionError.failed(error.localizedDescription)
                }
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                if !lines.isEmpty { pages.append(lines.joined(separator: "\n")) }
            }
            return pages.joined(separator: "\n\n")
        }
        guard !text.isEmpty else { throw FileActionError.noText }
        return text
    }

    /// A PDF's pages as images at twice their size.
    private static func pdfPages(_ url: URL) throws -> [CGImage] {
        guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else { throw FileActionError.unreadable }
        var out: [CGImage] = []
        for n in 1...min(doc.numberOfPages, maxOCRPages) {
            guard let page = doc.page(at: n) else { continue }
            let box = page.getBoxRect(.mediaBox)
            let scale: CGFloat = 2
            let w = Int(box.width * scale), h = Int(box.height * scale)
            guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(page)
            if let image = ctx.makeImage() { out.append(image) }
        }
        return out
    }

    /// Vision's subject lifting (macOS 14 and later): true when this Mac has it.
    static var canRemoveBackground: Bool {
        !VNGenerateForegroundInstanceMaskRequest.supportedRevisions.isEmpty
    }

    /// The image's subjects on a transparent background, as `<name> (no background).png`.
    static func removeBackground(_ src: URL, into folder: URL) throws -> URL {
        let image = try uprightImage(src)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try handler.perform([request])
        } catch {
            throw FileActionError.failed(error.localizedDescription)
        }
        guard let result = request.results?.first, !result.allInstances.isEmpty else { throw FileActionError.noSubject }
        let buffer: CVPixelBuffer
        do {
            buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        } catch {
            throw FileActionError.failed(error.localizedDescription)
        }
        let out = output(src, ext: "png", in: folder, suffix: " (no background)")
        let ci = CIImage(cvPixelBuffer: buffer)
        do {
            try CIContext().writePNGRepresentation(of: ci, to: out, format: .RGBA8,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        } catch {
            throw FileActionError.failed(error.localizedDescription)
        }
        return out
    }
}
