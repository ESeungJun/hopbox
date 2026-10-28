import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Finder 처럼 파일 내용이 보이는 미리보기. 만든 것은 경로별로 기억해 둔다.
enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func cached(_ path: String) -> NSImage? {
        cache.object(forKey: path as NSString)
    }

    static func load(_ path: String) async -> NSImage {
        if let image = cached(path) { return image }
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
        cache.setObject(image, forKey: path as NSString)
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
                    .fill(Color(red: 1, green: 0.97, blue: 0.82))
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
            )
    }
}
