import Foundation

public struct ShelfItem: Identifiable, Codable, Equatable {
    public enum Kind: String, Codable {
        case file   // 원본 파일을 가리키기만 한다 (복사하지 않음)
        case image  // 상자가 보관하는 파일. 붙여넣은 이미지, 곧 지워질 임시 파일을 상자 폴더에 복사해 둔다
        case text
    }

    public let id: UUID
    public let kind: Kind
    public var path: String?
    public var text: String?
    /// 텍스트 미리보기. 긴 텍스트를 화면을 그릴 때마다 다듬지 않도록 담을 때 한 번 만든다
    public var preview: String?
    public var textLength: Int?
    public let addedAt: Date
    /// 스크린샷·복사한 이미지처럼 자동으로 담긴 것. 보관 기한은 이것만 본다
    public var auto: Bool?
    /// 고정한 것. 맨 위에 두고 보관 기한에서 뺀다
    public var pinned: Bool?
    /// 다른 앱으로 끌어내 받아들여진 때
    public var sentAt: Date?
    /// 원본 파일의 북마크. 원본이 옮겨지거나 이름이 바뀌면 이것으로 새 위치를 찾는다
    public var bookmark: Data?

    public init(
        id: UUID = UUID(), kind: Kind, path: String? = nil, text: String? = nil,
        preview: String? = nil, textLength: Int? = nil, addedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.path = path
        self.text = text
        self.preview = preview
        self.textLength = textLength
        self.addedAt = addedAt
    }

    public var url: URL? { path.map { URL(fileURLWithPath: $0) } }
    public var isAuto: Bool { auto == true }
    public var isPinned: Bool { pinned == true }
    public var isSent: Bool { sentAt != nil }

    public var exists: Bool {
        guard let path else { return kind == .text }
        return FileManager.default.fileExists(atPath: path)
    }

    /// 그림 파일인지. 파일을 열어 보지 않고 확장자로 본다 (목록을 그릴 때마다 부른다)
    public var isPicture: Bool {
        guard let ext = url?.pathExtension.lowercased() else { return false }
        return Self.pictureExtensions.contains(ext)
    }

    private static let pictureExtensions: Set<String> =
        ["png", "jpg", "jpeg", "gif", "bmp", "webp", "heic", "heif", "tif", "tiff"]

    /// 목록·부채꼴에 보이는 이름
    public var title: String {
        switch kind {
        case .text: return preview ?? ShelfItem.makePreview(text ?? "")
        case .file, .image: return url?.lastPathComponent ?? ""
        }
    }

    public static func file(_ url: URL) -> ShelfItem {
        ShelfItem(kind: .file, path: url.path)
    }

    public static func image(_ url: URL) -> ShelfItem {
        ShelfItem(kind: .image, path: url.path)
    }

    public static func text(_ string: String) -> ShelfItem {
        ShelfItem(kind: .text, text: string, preview: makePreview(string), textLength: string.count)
    }

    static func makePreview(_ string: String) -> String {
        String(string.prefix(300))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
