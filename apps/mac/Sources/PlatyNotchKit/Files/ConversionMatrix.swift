import Foundation
import UniformTypeIdentifiers

/// What a shelf file can be converted to (Task 2). Images: PNG, JPEG, HEIC, TIFF and PDF
/// (WebP, GIF, RAW and the rest are read, never written); video: MP4 (H.264 or HEVC,
/// `VideoCodec`) and MOV; audio: M4A (AAC) and WAV. Several images make one PDF
/// (`canCombineToPDF`, a separate action). The UI drops any target this Mac cannot write
/// (HEIC on some Macs).
public enum ConversionMatrix {
    public static let imageTargets: [UTType] = [.png, .jpeg, .heic, .tiff, .pdf]
    public static let videoTargets: [UTType] = [.mpeg4Movie, .quickTimeMovie]
    public static let audioTargets: [UTType] = [.mpeg4Audio, .wav]

    /// The kind of media a type is, for conversion (nil: not convertible).
    public enum Family: String, Equatable, Sendable {
        case image, video, audio
    }

    public static func family(of uti: UTType) -> Family? {
        if uti.conforms(to: .svg) || uti.conforms(to: .pdf) { return nil }   // not raster images
        if uti.conforms(to: .image) { return .image }
        if uti.conforms(to: .movie) { return .video }
        if uti.conforms(to: .audio) { return .audio }
        return nil
    }

    /// Single-file conversions for `uti`, never its own type (a JPEG is not offered JPEG).
    public static func targets(for uti: UTType) -> [UTType] {
        let all: [UTType]
        switch family(of: uti) {
        case .image: all = imageTargets
        case .video: all = videoTargets
        case .audio: all = audioTargets
        case nil: return []
        }
        return all.filter { !uti.conforms(to: $0) }
    }

    /// Two or more images, and nothing else: "Combine into PDF".
    public static func canCombineToPDF(_ types: [UTType]) -> Bool {
        types.count >= 2 && types.allSatisfy { family(of: $0) == .image }
    }
}

/// The codec of an MP4 made by Convert (MOV keeps the source's quality preset).
public enum VideoCodec: String, CaseIterable, Equatable, Sendable {
    case h264, hevc

    public var title: String {
        switch self {
        case .h264: "MP4 (H.264)"
        case .hevc: "MP4 (HEVC)"
        }
    }

    /// The `AVAssetExportSession` preset name.
    public var exportPreset: String {
        switch self {
        case .h264: "AVAssetExportPresetHighestQuality"
        case .hevc: "AVAssetExportPresetHEVCHighestQuality"
        }
    }
}

/// "Compress video": a smaller MP4 at one of these sizes (never larger than the source;
/// the preset keeps the aspect ratio).
public enum VideoQuality: String, CaseIterable, Equatable, Sendable {
    case hevc1080, p1080, p720, p540

    public var title: String {
        switch self {
        case .hevc1080: "1080p (HEVC, smallest)"
        case .p1080: "1080p (H.264)"
        case .p720: "720p (H.264)"
        case .p540: "540p (H.264)"
        }
    }

    /// The `AVAssetExportSession` preset name.
    public var exportPreset: String {
        switch self {
        case .hevc1080: "AVAssetExportPresetHEVC1920x1080"
        case .p1080: "AVAssetExportPreset1920x1080"
        case .p720: "AVAssetExportPreset1280x720"
        case .p540: "AVAssetExportPreset960x540"
        }
    }
}

/// What a shelf item is, for choosing its actions.
public enum FileSubject: Equatable, Sendable {
    case file(UTType)
    case folder
    case text
    case url
}

/// The actions under a shelf item's "Actions ›" menu.
public enum FileActionKind: String, CaseIterable, Equatable, Sendable {
    case convert, compressVideo, combinePDF, zip, unzip, copyText, removeBackground, rename
}

/// Which actions a selection gets. Actions that do not apply are left out (hidden, not
/// disabled): text and links get none; Zip and Rename take files and folders only; Copy
/// Text takes one image or PDF; Remove Background one image, where Vision supports it.
public enum FileActionMenu {
    public static func actions(for subjects: [FileSubject], removeBackgroundAvailable: Bool) -> [FileActionKind] {
        guard !subjects.isEmpty else { return [] }
        let types: [UTType] = subjects.compactMap { if case .file(let t) = $0 { t } else { nil } }
        let onDisk = subjects.allSatisfy { $0 == .folder || isFile($0) }
        var out: [FileActionKind] = []
        if subjects.count == 1, let t = types.first {
            if !ConversionMatrix.targets(for: t).isEmpty { out.append(.convert) }
            if ConversionMatrix.family(of: t) == .video { out.append(.compressVideo) }
        }
        if ConversionMatrix.canCombineToPDF(types), types.count == subjects.count { out.append(.combinePDF) }
        if onDisk { out.append(.zip) }
        if subjects.count == 1, let t = types.first, t.conforms(to: .zip) { out.append(.unzip) }
        if subjects.count == 1, let t = types.first, t.conforms(to: .pdf) || ConversionMatrix.family(of: t) == .image {
            out.append(.copyText)
        }
        if removeBackgroundAvailable, subjects.count == 1, let t = types.first, ConversionMatrix.family(of: t) == .image {
            out.append(.removeBackground)
        }
        if onDisk { out.append(.rename) }
        return out
    }

    private static func isFile(_ s: FileSubject) -> Bool {
        if case .file = s { return true }
        return false
    }
}
