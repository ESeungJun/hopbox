import AppKit
import SwiftUI

/// 창이 지금 어떤 모양인지. 창 크기(layout)와 보이는 내용(mode)을 따로 둔다.
/// 펼칠 때는 창을 먼저 키우고 내용을 띄우며, 접을 때는 내용을 먼저 감추고 창을 줄인다.
final class BoxState: ObservableObject {
    @Published var layout = BoxLayout()
    @Published var mode: BoxLayout.Mode = .icon
    /// 상자가 화면에 떨어져 내려앉을 때마다 1씩 오른다
    @Published var landing = 0
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
                if state.mode == .fan && layout.mode == .fan {
                    FanView(store: store, layout: layout, center: center, onShowList: actions.showList)
                }
                if state.mode == .list && layout.mode == .list {
                    ShelfListView(store: store, onClose: actions.collapse)
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
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.mode)
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

/// 상자 그림. 앱 묶음의 Resources 에 든 png 를 쓰고, 없으면(시험 실행 등) SF Symbol 로 대신한다
private enum BoxArt {
    static let closed = load("box-closed")
    static let open = load("box-open")

    private static func load(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }
}

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

    private var isOpen: Bool { state.mode != .icon || store.isDropTargeted }

    var body: some View {
        ZStack {
            // 바닥 그림자. 상자가 눌리면 넓게 퍼진다
            Ellipse()
                .fill(Color.black.opacity(0.28))
                .frame(width: 58 * stretchX, height: 9)
                .blur(radius: 4)
                .offset(y: 37)

            if showDust { dustPuffs }

            boxImage
                .frame(width: 82, height: 82)
                .rotationEffect(.degrees(wobble ? 4 : 0), anchor: .bottom)
                .scaleEffect(x: stretchX, y: stretchY, anchor: .bottom)
                .scaleEffect(store.isDropTargeted ? 1.12 : 1, anchor: .bottom)
                .offset(y: -2)

            if store.isDropTargeted {
                Image(systemName: "arrow.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .offset(y: -46)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if !store.items.isEmpty {
                Text("\(store.items.count)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .padding(.horizontal, 6)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Capsule().fill(Color(red: 0.86, green: 0.24, blue: 0.2)).shadow(color: .black.opacity(0.2), radius: 2, y: 1))
                    .offset(x: 30, y: -30)
            }

            if let floatingCount {
                Text("+\(floatingCount)")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                    .offset(y: floatUp ? -58 : -26)
                    .opacity(floatUp ? 0 : 1)
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.5), value: store.isDropTargeted)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isOpen)
        .contentShape(Rectangle().inset(by: 12))
        .overlay(WindowHandle(onClick: onClick).frame(width: 72, height: 72))
        .help("누르면 열고 닫아요 · 끌면 상자를 옮겨요")
        .onChange(of: store.isDropTargeted) { targeted in
            if targeted {
                withAnimation(.easeInOut(duration: 0.14).repeatForever(autoreverses: true)) { wobble = true }
            } else {
                withAnimation(.easeOut(duration: 0.1)) { wobble = false }
            }
        }
        .onChange(of: store.addPulse) { _ in received() }
        .onChange(of: state.landing) { _ in landed() }
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
                .foregroundStyle(Color(red: 0.76, green: 0.55, blue: 0.33))
        }
    }

    /// 바닥에 닿을 때 양옆으로 퍼지는 먼지
    private var dustPuffs: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { index in
                let side: CGFloat = index.isMultiple(of: 2) ? 1 : -1
                let spread = CGFloat(index / 2 + 1)
                Circle()
                    .fill(Color(red: 0.8, green: 0.72, blue: 0.6).opacity(0.7))
                    .frame(width: 7 + spread * 2, height: 7 + spread * 2)
                    .offset(x: side * (dust ? 18 + spread * 9 : 10), y: dust ? 30 - spread * 3 : 34)
                    .opacity(dust ? 0 : 0.9)
                    .blur(radius: 1)
            }
        }
    }

    /// 택배가 툭 떨어져 내려앉는다: 납작하게 눌렸다가 튀어 오르고 먼지가 인다
    private func landed() {
        squash(x: 1.16, y: 0.76, settle: .spring(response: 0.38, dampingFraction: 0.38))
        showDust = true
        dust = false
        withAnimation(.easeOut(duration: 0.5)) { dust = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { showDust = false }
    }

    /// 상자에 담기면 살짝 눌렸다 튀어 오르고 "+N" 이 떠오른다
    private func received() {
        squash(x: 1.08, y: 0.86, settle: .spring(response: 0.35, dampingFraction: 0.4))
        floatingCount = store.lastAddedCount
        floatUp = false
        withAnimation(.easeOut(duration: 0.8)) { floatUp = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { floatingCount = nil }
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
                        .lineLimit(1)
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
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: alignTrailing ? .trailing : .leading)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.toast)
    }
}
