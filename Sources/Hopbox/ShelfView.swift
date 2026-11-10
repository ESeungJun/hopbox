import AppKit
import SwiftUI
import HopboxCore

/// "전체 보기". 부채꼴에 다 못 담을 만큼 많을 때 목록으로 본다.
/// ⌘클릭·⇧클릭으로 여러 줄을 고르고 그중 하나를 끌면 고른 것만 나간다.
struct ShelfListView: View {
    @ObservedObject var store: ShelfStore
    /// 키보드(↑↓)로 고른 줄
    let selectedIndex: Int?
    var onClose: () -> Void

    @State private var selection: Set<UUID> = []
    @State private var lastClicked: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.items.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                                ShelfRow(
                                    item: item, store: store,
                                    isChosen: selection.contains(item.id), isSelected: selectedIndex == index,
                                    dragged: { dragged(with: item) },
                                    onClick: { flags in clicked(item, flags) }
                                )
                                .id(item.id)
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: selectedIndex) { index in
                        guard let index, store.items.indices.contains(index) else { return }
                        proxy.scrollTo(store.items[index].id)
                    }
                }
            }
        }
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .overlay {
            if store.isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Theme.tape, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Theme.tape.opacity(0.08))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .onChange(of: store.items) { items in
            // 빠진 항목은 고른 것에서도 뺀다
            selection.formIntersection(items.map(\.id))
        }
    }

    /// ⌘클릭은 고르기, ⇧클릭은 범위 고르기, 그냥 클릭은 복사
    private func clicked(_ item: ShelfItem, _ flags: NSEvent.ModifierFlags) {
        if flags.contains(.command) {
            if !selection.insert(item.id).inserted { selection.remove(item.id) }
            lastClicked = item.id
        } else if flags.contains(.shift),
                  let from = store.items.firstIndex(where: { $0.id == lastClicked }),
                  let to = store.items.firstIndex(where: { $0.id == item.id }) {
            selection.formUnion(store.items[min(from, to)...max(from, to)].map(\.id))
        } else {
            selection = []
            lastClicked = item.id
            store.copyToPasteboard(item)
        }
    }

    /// 고른 줄을 끌면 고른 것 전부, 아니면 그 줄만
    private func dragged(with item: ShelfItem) -> [ShelfItem] {
        selection.contains(item.id) ? store.items.filter { selection.contains($0.id) } : [item]
    }

    private var header: some View {
        HStack(spacing: 8) {
            // 이 상자를 끌면 담긴 것을 한꺼번에 끌어낸다
            headerIcon
                .frame(width: 28, height: 28)
                .overlay(
                    DragSource(
                        label: "담긴 것 전부 끌어내기",
                        writers: { store.dragWriters(for: store.items) },
                        onSent: { store.markSent(store.items.map(\.id)) }
                    )
                )
                .help("끌면 전부 한꺼번에 꺼내요")
            VStack(alignment: .leading, spacing: 1) {
                Text(selection.isEmpty ? "담긴 것 \(store.items.count)개" : "\(selection.count)개 골랐어요 · 끌어서 꺼내기")
                    .font(.headline)
                if store.usageBytes > 0 {
                    Text("상자에 보관한 파일 \(Wording.size(store.usageBytes))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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
            .accessibilityLabel("모두 비우기")
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("닫기 (esc)")
            .accessibilityLabel("닫기")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var headerIcon: some View {
        if let image = BoxArt.closed {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "shippingbox.fill")
                .font(.title3)
                .foregroundStyle(Theme.cardboard)
        }
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
    /// ⌘클릭으로 고른 줄
    let isChosen: Bool
    /// 키보드로 고른 줄
    let isSelected: Bool
    var dragged: () -> [ShelfItem]
    var onClick: (NSEvent.ModifierFlags) -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                ThumbnailView(item: item, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if item.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.tape)
                        }
                        Text(item.title)
                            .font(.callout)
                            .lineLimit(item.kind == .text ? 2 : 1)
                            .truncationMode(.middle)
                        if item.isSent { SentStamp() }
                    }
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
                    label: item.accessibilityLabel,
                    writers: { store.dragWriters(for: dragged()) },
                    onClick: onClick,
                    onSent: { store.markSent(dragged().map(\.id)) },
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
                .accessibilityLabel("복사")
                Button {
                    store.remove(item)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("상자에서 빼기")
                .accessibilityLabel("상자에서 빼기")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isChosen ? Theme.tape.opacity(0.22) : (isHovering ? Color.primary.opacity(0.07) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.tape.opacity(isSelected ? 1 : 0), lineWidth: 2)
        )
        .onHover { isHovering = $0 }
        .opacity(item.exists ? (item.isSent ? 0.7 : 1) : 0.55)
        .help("클릭하면 복사 · ⌘클릭으로 여러 개 고르기 · 끌어서 꺼내기")
    }

    private var subtitle: String {
        switch item.kind {
        case .text:
            return "텍스트 · \(item.textLength ?? item.text?.count ?? 0)자"
        case .image:
            guard item.exists else { return "보관한 파일이 없어요" }
            return item.isPicture ? "상자에 보관한 이미지" : "상자에 보관한 파일"
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
