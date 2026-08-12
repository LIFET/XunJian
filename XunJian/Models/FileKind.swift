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
        switch self {
        case .document: "文档"
        case .image: "图片"
        case .video: "视频"
        case .audio: "音频"
        case .archive: "压缩包"
        case .code: "代码"
        case .other: "其他"
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
