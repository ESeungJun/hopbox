import SwiftUI

/// 상자를 열면 담긴 것들이 Dock 스택처럼 부채꼴로 펼쳐진다.
/// 아이콘에서 멀어질수록 바깥으로 조금씩 휘고 기운다.
struct FanView: View {
    @ObservedObject var store: ShelfStore
    let layout: BoxLayout
    /// 아이콘 중심. 실제 창 크기에서 계산한 값을 받는다
    let center: CGPoint
    var onShowList: () -> Void

    @State private var appeared = false

    var body: some View {
        let shown = Array(store.items.prefix(layout.fanRows))
        ZStack(alignment: .topLeading) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                place(FanRow(store: store, item: item, iconOnRight: layout.iconOnRight), at: index)
            }
            place(controls(hidden: store.items.count - shown.count), at: shown.count)
        }
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { appeared = true }
        }
    }

    /// index 번째 줄을 부채꼴 자리에 놓는다. 펼쳐질 때는 아이콘 쪽에서 날아오듯 나온다
    private func place<Content: View>(_ content: Content, at index: Int) -> some View {
        let c = center
        let i = CGFloat(index)
        let up: CGFloat = layout.opensUp ? -1 : 1
        let out: CGFloat = layout.iconOnRight ? 1 : -1

        let bend = min(i * i * 0.4, BoxLayout.sideMargin)
        let thumbX = c.x + out * bend
        let y = c.y + up * (BoxLayout.iconArea / 2 + BoxLayout.rowHeight / 2 + i * BoxLayout.rowHeight)
        let width = BoxLayout.fanWidth - 20
        let x = thumbX - out * (width / 2 - FanRow.thumbSize / 2)
        let angle = Double(pow(i, 1.35)) * 0.9 * Double(out) * Double(-up)

        return content
            .frame(width: width, alignment: layout.iconOnRight ? .trailing : .leading)
            .rotationEffect(.degrees(appeared ? angle : 0), anchor: layout.iconOnRight ? .trailing : .leading)
            .scaleEffect(appeared ? 1 : 0.5, anchor: layout.iconOnRight ? .trailing : .leading)
            .opacity(appeared ? 1 : 0)
            .position(x: x, y: appeared ? y : c.y)
            .animation(.spring(response: 0.38, dampingFraction: 0.78).delay(Double(index) * 0.018), value: appeared)
    }

    private func controls(hidden: Int) -> some View {
        HStack(spacing: 8) {
            if !layout.iconOnRight { buttons }
            if store.items.isEmpty {
                pill("상자가 비어 있어요 · 끌어다 놓거나 ⌘V")
            } else if hidden > 0 {
                Button(action: onShowList) { pill("그 외 \(hidden)개") }
                    .buttonStyle(.plain)
            }
            if layout.iconOnRight { buttons }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if !store.items.isEmpty {
            CircleButton(symbol: "list.bullet", help: "전체 보기", action: onShowList)
            CircleButton(symbol: "trash", help: "모두 비우기") { store.removeAll() }
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(.regularMaterial).shadow(color: .black.opacity(0.15), radius: 4, y: 2))
    }
}

private struct FanRow: View {
    static let thumbSize: CGFloat = 50

    @ObservedObject var store: ShelfStore
    let item: ShelfItem
    let iconOnRight: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            if iconOnRight {
                label
                thumbnail
            } else {
                thumbnail
                label
            }
        }
        .opacity(item.exists ? 1 : 0.5)
        .onHover { isHovering = $0 }
        .overlay(
            DragSource(
                writers: { store.dragWriters(for: [item]) },
                onClick: { store.copyToPasteboard(item) },
                menu: { store.contextMenu(for: item) }
            )
        )
        .help(item.exists ? "끌어서 꺼내기 · 클릭하면 복사 · 우클릭 메뉴" : "원본 파일을 찾을 수 없어요")
    }

    private var label: some View {
        // 짧은 이름은 제 길이만큼만, 긴 이름은 300pt 에서 말줄임. 빈 자리를 눌러도 복사되지 않게 한다
        CappedWidth(max: 300) { labelText }
    }

    private var labelText: some View {
        Text(item.title)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(.regularMaterial)
                    .overlay(Capsule().strokeBorder(Color.accentColor.opacity(isHovering ? 0.9 : 0), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            )
    }

    private var thumbnail: some View {
        ThumbnailView(item: item, size: Self.thumbSize)
            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            .scaleEffect(isHovering ? 1.08 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

private struct CircleButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.regularMaterial).shadow(color: .black.opacity(0.18), radius: 4, y: 2))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 내용이 짧으면 제 크기, 길면 max 까지만 차지한다. frame(maxWidth:) 는 남는 폭까지 다 차지해 버린다.
private struct CappedWidth: Layout {
    var max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? max, max)
        return subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
