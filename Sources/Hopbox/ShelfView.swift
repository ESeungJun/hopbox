import AppKit
import SwiftUI

/// "전체 보기". 부채꼴에 다 못 담을 만큼 많을 때 목록으로 본다.
struct ShelfListView: View {
    @ObservedObject var store: ShelfStore
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.items) { item in
                            ShelfRow(item: item, store: store)
                        }
                    }
                    .padding(6)
                }
            }
            Divider()
            Text("끌어다 놓기 · ⌘V 담기 · 클릭하면 복사 · esc 닫기")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        }
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .overlay {
            if store.isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Color.accentColor.opacity(0.08))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            // 이 아이콘을 끌면 담긴 것을 한꺼번에 끌어낸다
            Image(systemName: "square.stack.3d.up.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .overlay(DragSource(writers: { store.dragWriters(for: store.items) }))
                .help("끌면 전부 한꺼번에 꺼내요")
            Text("택배상자")
                .font(.headline)
            if !store.items.isEmpty {
                Text("\(store.items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.removeAll()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(store.items.isEmpty)
            .help("모두 비우기 (되돌릴 수 있어요)")
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("닫기 (esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("상자가 비어 있어요")
                .font(.callout.weight(.medium))
            Text("파일을 여기로 끌어다 놓거나\n복사한 뒤 ⌘V 로 담으세요")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ShelfRow: View {
    let item: ShelfItem
    @ObservedObject var store: ShelfStore
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                ThumbnailView(item: item, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.callout)
                        .lineLimit(item.kind == .text ? 2 : 1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(item.exists ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .overlay(
                DragSource(
                    writers: { store.dragWriters(for: [item]) },
                    onClick: { store.copyToPasteboard(item) },
                    menu: { store.contextMenu(for: item) }
                )
            )

            if isHovering {
                Button {
                    store.copyToPasteboard(item)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("복사")
                Button {
                    store.remove(item)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("상자에서 빼기")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? Color.primary.opacity(0.07) : .clear)
        )
        .onHover { isHovering = $0 }
        .opacity(item.exists ? 1 : 0.55)
    }

    private var subtitle: String {
        switch item.kind {
        case .text:
            return "텍스트 · \(item.textLength ?? item.text?.count ?? 0)자"
        case .image:
            return item.exists ? "붙여넣은 이미지" : "이미지 파일이 없어요"
        case .file:
            guard item.exists else { return "원본 파일을 찾을 수 없어요" }
            let folder = item.url?.deletingLastPathComponent().path ?? ""
            return (folder as NSString).abbreviatingWithTildeInPath
        }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
