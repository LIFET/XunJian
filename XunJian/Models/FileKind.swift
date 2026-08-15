import Foundation

enum FileKind: String, CaseIterable, Identifiable, Sendable {
    case document
    case image
    case video
    case audio
    case archive
    case code
    case other

    var id: String { rawValue }

    var title: String {
        title(usesEnglish: false)
    }

    func title(usesEnglish: Bool) -> String {
        switch self {
        case .document: usesEnglish ? "Document" : "文档"
        case .image: usesEnglish ? "Image" : "图片"
        case .video: usesEnglish ? "Video" : "视频"
        case .audio: usesEnglish ? "Audio" : "音频"
        case .archive: usesEnglish ? "Archive" : "压缩包"
        case .code: usesEnglish ? "Code" : "代码"
        case .other: usesEnglish ? "Other" : "其他"
        }
    }

    /// Whether this kind can plausibly hold indexed text, used to decide if a
    /// text-preview affordance is worth offering.
    ///
    /// Approximate by design: extraction is driven by file extension, so some
    /// documents (Office formats) still yield no text. Callers must handle an
    /// empty result rather than treating this as a guarantee.
    var supportsTextExtraction: Bool {
        switch self {
        case .document, .code: true
        case .image, .video, .audio, .archive, .other: false
        }
    }

    var symbolName: String {
        switch self {
        case .document: "doc.text"
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .archive: "archivebox"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .other: "doc"
        }
    }
}
