import AppKit

/// 상자 창의 모양. 아이콘은 늘 화면의 같은 자리(anchor)에 있고, 창은 펼친 내용만큼 그 둘레로 커진다.
/// 아이콘 위치는 창 크기와 방향만으로 정해진다. 모드마다 여백이 달라지면 펼칠 때 아이콘이 튄다.
struct BoxLayout: Equatable {
    enum Mode { case icon, fan, list }

    var mode: Mode = .icon
    /// 위로 펼칠지 (화면 아래쪽에 있으면 위로, 위쪽에 있으면 아래로)
    var opensUp = true
    /// 아이콘이 오른쪽에 있고 이름표가 왼쪽으로 펼쳐지는지
    var iconOnRight = true
    /// 부채꼴에 보이는 항목 수
    var fanRows = 0

    static let iconArea: CGFloat = 96
    static let toastWidth: CGFloat = 260
    static let rowHeight: CGFloat = 58
    static let fanWidth: CGFloat = 440
    /// 부채꼴이 휘는 만큼 아이콘 바깥쪽에 남겨 두는 폭. 모든 모드에 똑같이 둔다
    static let sideMargin: CGFloat = 36
    static let listSize = CGSize(width: 340, height: 420)
    static let maxFanRows = 10

    var size: CGSize {
        switch mode {
        case .icon:
            return CGSize(width: Self.iconArea + Self.toastWidth + Self.sideMargin, height: Self.iconArea)
        case .fan:
            return CGSize(
                width: Self.fanWidth + Self.sideMargin,
                height: Self.iconArea + CGFloat(fanRows + 1) * Self.rowHeight + 16
            )
        case .list:
            return CGSize(
                width: max(Self.listSize.width, Self.iconArea + Self.toastWidth) + Self.sideMargin,
                height: Self.iconArea + Self.listSize.height + 8
            )
        }
    }

    /// SwiftUI 좌표(왼쪽 위 기준)에서 아이콘 중심. 실제 창 크기를 넣어 부른다
    func iconCenter(in size: CGSize) -> CGPoint {
        let half = Self.iconArea / 2
        return CGPoint(
            x: iconOnRight ? size.width - half - Self.sideMargin : half + Self.sideMargin,
            y: opensUp ? size.height - half : half
        )
    }

    /// 창 원점(왼쪽 아래)에서 아이콘 중심까지. 화면 좌표로 창을 놓을 때 쓴다
    var iconOffsetFromOrigin: CGPoint {
        let center = iconCenter(in: size)
        return CGPoint(x: center.x, y: size.height - center.y)
    }

    /// 아이콘이 화면 어디에 있는지 보고 펼칠 방향과 보일 줄 수를 정한다
    static func make(mode: Mode, anchor: NSPoint, in visible: NSRect, itemCount: Int) -> BoxLayout {
        var layout = BoxLayout(mode: mode)
        let above = visible.maxY - anchor.y
        let below = anchor.y - visible.minY
        layout.opensUp = above >= below
        layout.iconOnRight = anchor.x - visible.minX >= visible.maxX - anchor.x
        let room = max(above, below) - iconArea / 2 - 16
        let fitRows = Int(room / rowHeight) - 1
        layout.fanRows = max(0, min(itemCount, fitRows, maxFanRows))
        return layout
    }
}
