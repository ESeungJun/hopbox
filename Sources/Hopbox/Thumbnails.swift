import AppKit
import QuickLookThumbnailing
import SwiftUI
import HopboxCore

/// Finder 처럼 파일 내용이 보이는 미리보기. 만든 것은 경로와 수정 시각별로 기억해 둔다.
/// 같은 이름으로 덮어쓴 파일은 수정 시각이 달라 새로 만든다
enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    private static func key(_ path: String) -> NSString {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        return "\(path)|\(modified?.timeIntervalSince1970 ?? 0)" as NSString
    }

    static func cached(_ path: String) -> NSImage? {
        cache.object(forKey: key(path))
    }

    static func load(_ path: String) async -> NSImage {
        let key = key(path)
        if let image = cache.object(forKey: key) { return image }
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: 128, height: 128),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all
        )
        let image: NSImage = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage ?? NSWorkspace.shared.icon(forFile: path))
            }
        }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// 항목 하나의 미리보기. 파일은 내용 미리보기, 텍스트는 작은 메모지로 그린다.
struct ThumbnailView: View {
    let item: ShelfItem
    var size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if item.kind == .text {
                note
            } else if let image = image ?? initialImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .task(id: item.path) {
            guard let path = item.path, item.kind != .text else { return }
            image = await Thumbnails.load(path)
        }
    }

    private var initialImage: NSImage? {
        guard let path = item.path else { return nil }
        return Thumbnails.cached(path) ?? NSWorkspace.shared.icon(forFile: path)
    }

    private var note: some View {
        Text(item.title)
            .font(.system(size: max(size / 7.5, 6)))
            .foregroundStyle(.black.opacity(0.75))
            .lineLimit(5)
            .padding(size / 10)
            .frame(width: size * 0.8, height: size * 0.95, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.note)
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
            )
    }
}
