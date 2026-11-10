import HopboxCore
import SwiftUI

/// 상자를 열면 담긴 것들이 Dock 스택처럼 부채꼴로 펼쳐진다.
/// 아이콘에서 멀어질수록 바깥으로 조금씩 휘고 기운다.
struct FanView: View {
    @ObservedObject var store: ShelfStore
    let layout: BoxLayout
    /// 아이콘 중심. 실제 창 크기에서 계산한 값을 받는다
    let center: CGPoint
    /// 접는 중이면 false. 줄이 상자 쪽으로 빨려 들어간다
    let isOpen: Bool
    /// 키보드로 고른 줄
    let selectedIndex: Int?
    var onShowList: () -> Void

    @State private var appeared = false

    var body: some View {
        let shown = Array(store.items.prefix(layout.fanRows))
        ZStack(alignment: .topLeading) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                place(
                    FanRow(
                        store: store, item: item, iconOnRight: layout.iconOnRight,
                        keyLabel: KeyPick.label(index: index), isSelected: selectedIndex == index
                    ),
                    at: index, of: shown.count + 1
                )
            }
            place(controls(hidden: store.items.count - shown.count), at: shown.count, of: shown.count + 1)
        }
        .allowsHitTesting(isOpen)
        .onAppear { appeared = isOpen }
        .onChange(of: isOpen) { appeared = $0 }
    }

    /// index 번째 줄을 부채꼴 자리에 놓는다. 펼쳐질 때는 아이콘 쪽에서 날아오듯 나오고,
    /// 접을 때는 먼 줄부터 차례로 상자에 빨려 들어간다
    private func place<Content: View>(_ content: Content, at index: Int, of count: Int) -> some View {
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
        // 동작 줄이기면 제자리에서 흐려졌다 나타나기만 한다
        let still = Motion.isReduced
        let settled = appeared || still

        let animation: Animation = still
            ? .easeOut(duration: 0.12)
            : appeared
                ? .spring(response: 0.38, dampingFraction: 0.78).delay(Double(index) * 0.018)
                : .easeIn(duration: 0.12).delay(Double(count - 1 - index) * 0.012)

        return content
            .frame(width: width, alignment: layout.iconOnRight ? .trailing : .leading)
            .rotationEffect(.degrees(settled ? angle : 0), anchor: layout.iconOnRight ? .trailing : .leading)
            .scaleEffect(settled ? 1 : 0.5, anchor: layout.iconOnRight ? .trailing : .leading)
            .opacity(appeared ? 1 : 0)
            .position(x: x, y: settled ? y : c.y)
            .animation(animation, value: appeared)
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
    /// 이 줄을 꺼내는 숫자 키
    let keyLabel: String?
    let isSelected: Bool
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
        .opacity(item.exists ? (item.isSent ? 0.7 : 1) : 0.5)
        .onHover { isHovering = $0 }
        .overlay(
            DragSource(
                label: item.accessibilityLabel,
                writers: { store.dragWriters(for: [item]) },
                onClick: { _ in store.copyToPasteboard(item) },
                onSent: { store.markSent([item.id]) },
                menu: { store.contextMenu(for: item) }
            )
        )
        .help(item.exists ? "끌어서 꺼내기 · 클릭하면 복사 · 우클릭 메뉴" : "원본 파일을 찾을 수 없어요")
    }

    private var label: some View {
        // 짧은 이름은 제 길이만큼만, 긴 이름은 300pt 에서 말줄임. 빈 자리를 눌러도 복사되지 않게 한다
        CappedWidth(max: 300) { tag }
    }

    /// 운송장 딱지 모양 이름표. 왼쪽 띠 색으로 파일·보관한 것·글을 가른다
    private var tag: some View {
        HStack(spacing: 6) {
            if let keyLabel {
                Text(keyLabel)
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.09)))
            }
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.tape)
            }
            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if item.isSent { SentStamp() }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(alignment: .leading) {
            ZStack(alignment: .leading) {
                Rectangle().fill(.regularMaterial)
                Rectangle().fill(Theme.stripe(for: item.kind)).frame(width: 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Theme.tape.opacity(isSelected ? 1 : (isHovering ? 0.9 : 0)), lineWidth: isSelected ? 2 : 1.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }

    private var thumbnail: some View {
        ThumbnailView(item: item, size: Self.thumbSize)
            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            .scaleEffect((isHovering || isSelected) && !Motion.isReduced ? 1.08 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovering || isSelected)
    }
}

/// 다른 앱으로 끌어내 받아들여진 항목에 찍는 도장
struct SentStamp: View {
    var body: some View {
        Text("보냄")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.waybill)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.waybill.opacity(0.8), lineWidth: 1))
            .rotationEffect(.degrees(-4))
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
        .accessibilityLabel(help)
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

extension ShelfItem {
    /// VoiceOver 가 읽는 이름
    var accessibilityLabel: String {
        let kindName: String
        switch kind {
        case .file: kindName = "파일"
        case .image: kindName = isPicture ? "이미지" : "보관한 파일"
        case .text: kindName = "글"
        }
        return [kindName, title, isPinned ? "고정됨" : nil, isSent ? "보냄" : nil].compactMap { $0 }.joined(separator: ", ")
    }
}
