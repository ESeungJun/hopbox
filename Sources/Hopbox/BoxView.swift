import AppKit
import SwiftUI
import HopboxCore

/// 창이 지금 어떤 모양인지. 창 크기(layout)와 보이는 내용(mode)을 따로 둔다.
/// 펼칠 때는 창을 먼저 키우고 내용을 띄우며, 접을 때는 내용을 먼저 감추고 창을 줄인다.
final class BoxState: ObservableObject {
    /// 상자가 화면에 들어오는 방식
    enum Arrival {
        /// 처음 부를 때: 위에서 툭 떨어진다 (배달)
        case drop
        /// 다른 화면에 있다가 건너올 때: 비스듬히 뛰어 들어와 한 번 되튄다 (이동)
        case hop
    }

    @Published var layout = BoxLayout()
    @Published var mode: BoxLayout.Mode = .icon
    /// 상자가 화면에 들어올 때마다 1씩 오른다
    @Published var landing = 0
    var arrival = Arrival.drop
    /// 상자가 뛰어 나갈 때마다 1씩 오른다
    @Published var departing = 0
    /// 키보드(↑↓)로 고른 줄
    @Published var selectedIndex: Int?
}

struct BoxActions {
    var toggleFan: () -> Void
    var showList: () -> Void
    var collapse: () -> Void
}

struct BoxView: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var state: BoxState
    var actions: BoxActions

    var body: some View {
        // 아이콘 자리는 실제 창 크기로 계산한다. 창 크기와 화면 갱신이 한 박자 어긋나도 아이콘이 튀지 않는다
        GeometryReader { geometry in
            let layout = state.layout
            let center = layout.iconCenter(in: geometry.size)

            ZStack(alignment: .topLeading) {
                // 접을 때는 줄이 상자로 빨려 들어간 다음 창이 준다. 그동안 부채꼴을 남겨 둔다
                if layout.mode == .fan {
                    FanView(
                        store: store, layout: layout, center: center, isOpen: state.mode == .fan,
                        selectedIndex: state.selectedIndex, onShowList: actions.showList
                    )
                }
                if state.mode == .list && layout.mode == .list {
                    ShelfListView(store: store, selectedIndex: state.selectedIndex, onClose: actions.collapse)
                        .frame(width: BoxLayout.listSize.width, height: BoxLayout.listSize.height)
                        .position(listCenter(layout, iconCenter: center))
                        .transition(.scale(scale: 0.92, anchor: layout.opensUp ? .bottom : .top).combined(with: .opacity))
                }
                ToastView(store: store, alignTrailing: layout.iconOnRight)
                    .frame(width: BoxLayout.toastWidth - 12, height: BoxLayout.iconArea)
                    .position(toastCenter(layout, iconCenter: center))
                BoxIcon(store: store, state: state, onClick: actions.toggleFan)
                    .frame(width: BoxLayout.iconArea, height: BoxLayout.iconArea)
                    .position(center)
            }
        }
        .animation(Motion.isReduced ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.85), value: state.mode)
    }

    private func toastCenter(_ layout: BoxLayout, iconCenter c: CGPoint) -> CGPoint {
        let offset = BoxLayout.iconArea / 2 + BoxLayout.toastWidth / 2 - 6
        return CGPoint(x: c.x + (layout.iconOnRight ? -offset : offset), y: c.y)
    }

    /// 목록 카드는 아이콘 바깥 모서리에 맞춰 위나 아래로 붙인다
    private func listCenter(_ layout: BoxLayout, iconCenter c: CGPoint) -> CGPoint {
        let size = BoxLayout.listSize
        let edge = BoxLayout.iconArea / 2
        let x = layout.iconOnRight ? c.x + edge - size.width / 2 : c.x - edge + size.width / 2
        let y = layout.opensUp
            ? c.y - edge - 8 - size.height / 2
            : c.y + edge + 8 + size.height / 2
        return CGPoint(x: x, y: y)
    }
}

// MARK: - 상자 아이콘

private struct BoxIcon: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var state: BoxState
    var onClick: () -> Void

    /// 눌리고 튀어 오르는 변형 (아래쪽 기준)
    @State private var stretchX: CGFloat = 1
    @State private var stretchY: CGFloat = 1
    @State private var wobble = false
    @State private var dust = false
    @State private var showDust = false
    @State private var floatingCount: Int?
    @State private var floatUp = false
    /// 들어오고 나가는 연출: 바닥에서 떠 있는 높이, 옆으로 치우친 거리, 투명도
    @State private var lift: CGFloat = 0
    @State private var shift: CGFloat = 0
    @State private var presence: Double = 1
    /// 동작 줄이기일 때 튀는 대신 잠깐 켜지는 테두리
    @State private var flash = false

    private var isOpen: Bool { state.mode != .icon || store.isDropTargeted }
    private var showsOutline: Bool { flash || (store.isDropTargeted && Motion.isReduced) }

    var body: some View {
        ZStack {
            // 바닥 그림자. 상자가 눌리면 넓게 퍼지고, 떠 있으면 작아진다
            Ellipse()
                .fill(Color.black.opacity(0.28))
                .frame(width: 58 * stretchX, height: 9)
                .blur(radius: 4)
                .scaleEffect(max(0.3, 1 - lift / 60))
                .opacity(presence)
                .offset(y: 37)

            if showDust { dustPuffs }

            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.tape, lineWidth: 2.5)
                .frame(width: 84, height: 84)
                .opacity(showsOutline ? 1 : 0)

            ZStack {
                boxImage
                    .frame(width: 82, height: 82)
                    .rotationEffect(.degrees(wobble ? 4 : 0), anchor: .bottom)
                    .scaleEffect(x: stretchX, y: stretchY, anchor: .bottom)
                    .scaleEffect(store.isDropTargeted && !Motion.isReduced ? 1.12 : 1, anchor: .bottom)
                    .offset(y: -2)

                if !store.items.isEmpty {
                    Text("\(store.items.count)")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Capsule().fill(Theme.waybill).shadow(color: .black.opacity(0.2), radius: 2, y: 1))
                        .offset(x: 30, y: -30)
                }

                if store.receiving > 0 {
                    // 다른 앱이 파일을 써 주는 중
                    ProgressView()
                        .controlSize(.small)
                        .padding(3)
                        .background(Circle().fill(.regularMaterial))
                        .offset(x: -30, y: -30)
                        .transition(.opacity)
                }
            }
            .offset(x: shift, y: -lift)
            .opacity(presence)

            if store.isDropTargeted {
                Image(systemName: "arrow.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.tape)
                    .offset(y: -46)
                    .transition(Motion.isReduced ? .opacity : .move(edge: .top).combined(with: .opacity))
            }

            if let floatingCount {
                Text("+\(floatingCount)")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.tape)
                    .offset(y: floatUp && !Motion.isReduced ? -58 : (Motion.isReduced ? -50 : -26))
                    .opacity(floatUp ? 0 : 1)
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.5), value: store.isDropTargeted)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isOpen)
        .animation(.easeOut(duration: 0.15), value: showsOutline)
        .animation(.easeOut(duration: 0.15), value: store.receiving > 0)
        .contentShape(Rectangle().inset(by: 12))
        .overlay(
            WindowHandle(label: "택배상자, 담긴 것 \(store.items.count)개", onClick: onClick)
                .frame(width: 72, height: 72)
        )
        .help("누르면 열고 닫아요 · 끌면 상자를 옮겨요")
        .onChange(of: store.isDropTargeted) { targeted in
            guard !Motion.isReduced else { return }
            if targeted {
                withAnimation(.easeInOut(duration: 0.14).repeatForever(autoreverses: true)) { wobble = true }
            } else {
                withAnimation(.easeOut(duration: 0.1)) { wobble = false }
            }
        }
        .onChange(of: store.addPulse) { _ in received() }
        .onChange(of: state.landing) { _ in landed() }
        .onChange(of: state.departing) { _ in departed() }
        .onChange(of: state.mode) { mode in
            // 줄이 다 빨려 들어오면 상자가 한 번 작게 눌린다
            guard mode == .icon, !Motion.isReduced else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard state.mode == .icon, presence == 1 else { return }
                squash(x: 1.02, y: 0.96, settle: .spring(response: 0.25, dampingFraction: 0.6))
            }
        }
    }

    @ViewBuilder
    private var boxImage: some View {
        if let image = isOpen ? (BoxArt.open ?? BoxArt.closed) : BoxArt.closed {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .id(isOpen)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
        } else {
            Image(systemName: isOpen ? "shippingbox.and.arrow.backward.fill" : "shippingbox.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.cardboard)
        }
    }

    /// 바닥에 닿을 때 양옆으로 퍼지는 먼지
    private var dustPuffs: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { index in
                let side: CGFloat = index.isMultiple(of: 2) ? 1 : -1
                let spread = CGFloat(index / 2 + 1)
                Circle()
                    .fill(Theme.dust.opacity(0.7))
                    .frame(width: 7 + spread * 2, height: 7 + spread * 2)
                    .offset(x: side * (dust ? 18 + spread * 9 : 10), y: dust ? 30 - spread * 3 : 34)
                    .opacity(dust ? 0 : 0.9)
                    .blur(radius: 1)
            }
        }
    }

    /// 상자가 들어온다. 처음 부르면 위에서 툭 떨어지고(배달), 다른 화면에서 건너오면 비스듬히 뛰어 들어온다(이동)
    private func landed() {
        stretchX = 1
        stretchY = 1
        shift = 0
        guard !Motion.isReduced else {
            lift = 0
            presence = 0
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.12)) { presence = 1 }
            }
            return
        }
        switch state.arrival {
        case .drop: drop()
        case .hop: hopIn()
        }
    }

    /// 조금 위에서 내려와 바닥에 닿으며 살짝 눌렸다 자리 잡고, 먼지가 조금 인다
    private func drop() {
        lift = 22
        presence = 0
        // 시작 자세가 한 번 그려진 다음 내려앉기 시작한다
        DispatchQueue.main.async {
            withAnimation(.easeIn(duration: 0.2)) {
                lift = 0
                presence = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            squash(x: 1.06, y: 0.92, settle: .spring(response: 0.3, dampingFraction: 0.6))
            puffDust()
        }
    }

    /// 더 높은 곳에서 옆으로 치우쳐 포물선으로 들어와, 닿으면 눌렸다가 한 번 작게 되튄다
    private func hopIn() {
        let side: CGFloat = state.layout.iconOnRight ? 1 : -1
        lift = 48
        shift = 12 * side
        presence = 0
        DispatchQueue.main.async {
            // 세로는 점점 빠르게, 가로는 일정하게 움직여 포물선이 된다
            withAnimation(.easeIn(duration: 0.22)) { lift = 0 }
            withAnimation(.linear(duration: 0.22)) { shift = 0 }
            withAnimation(.easeOut(duration: 0.1)) { presence = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            squash(x: 1.07, y: 0.9, settle: .spring(response: 0.26, dampingFraction: 0.55))
            withAnimation(.easeOut(duration: 0.09)) { lift = 6 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.31) {
            withAnimation(.easeIn(duration: 0.09)) { lift = 0 }
        }
    }

    /// 깡충 뛰어 나간다: 잠깐 움츠렸다가 위로 뛰며 사라진다
    private func departed() {
        guard !Motion.isReduced else {
            withAnimation(.easeOut(duration: 0.12)) { presence = 0 }
            return
        }
        withAnimation(.easeOut(duration: 0.06)) {
            stretchX = 1.05
            stretchY = 0.94
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            withAnimation(.easeOut(duration: 0.14)) {
                stretchX = 0.97
                stretchY = 1.05
                lift = 28
                presence = 0
            }
        }
    }

    private func puffDust() {
        showDust = true
        dust = false
        withAnimation(.easeOut(duration: 0.45)) { dust = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showDust = false }
    }

    /// 상자에 담기면 살짝 눌렸다 튀어 오르고 "+N" 이 떠오른다. 동작 줄이기면 테두리만 잠깐 켠다
    private func received() {
        floatingCount = store.lastAddedCount
        floatUp = false
        withAnimation(.easeOut(duration: 0.8)) { floatUp = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { floatingCount = nil }
        guard !Motion.isReduced else {
            flash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { flash = false }
            return
        }
        squash(x: 1.08, y: 0.86, settle: .spring(response: 0.35, dampingFraction: 0.4))
    }

    private func squash(x: CGFloat, y: CGFloat, settle: Animation) {
        withAnimation(.easeOut(duration: 0.07)) {
            stretchX = x
            stretchY = y
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
            withAnimation(settle) {
                stretchX = 1
                stretchY = 1
            }
        }
    }
}

// MARK: - 알림

private struct ToastView: View {
    @ObservedObject var store: ShelfStore
    var alignTrailing: Bool

    var body: some View {
        ZStack(alignment: alignTrailing ? .trailing : .leading) {
            Color.clear
            if let toast = store.toast {
                HStack(spacing: 10) {
                    Text(toast.message)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if toast.undoable {
                        Button("되돌리기") { store.undoRemove() }
                            .buttonStyle(.borderless)
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(.regularMaterial).shadow(color: .black.opacity(0.18), radius: 5, y: 2))
                .id(toast.id)
                .transition(
                    Motion.isReduced
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.9, anchor: alignTrailing ? .trailing : .leading))
                )
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.toast)
    }
}
