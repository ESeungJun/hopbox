import XCTest
@testable import HopboxCore

final class BoxLayoutTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func test_화면_아래쪽이면_위로_위쪽이면_아래로_펼친다() {
        let low = BoxLayout.make(mode: .fan, anchor: CGPoint(x: 700, y: 100), in: screen, itemCount: 3)
        let high = BoxLayout.make(mode: .fan, anchor: CGPoint(x: 700, y: 800), in: screen, itemCount: 3)

        XCTAssertTrue(low.opensUp)
        XCTAssertFalse(high.opensUp)
    }

    func test_화면_오른쪽이면_아이콘이_오른쪽에_온다() {
        XCTAssertTrue(BoxLayout.make(mode: .fan, anchor: CGPoint(x: 1300, y: 100), in: screen, itemCount: 1).iconOnRight)
        XCTAssertFalse(BoxLayout.make(mode: .fan, anchor: CGPoint(x: 100, y: 100), in: screen, itemCount: 1).iconOnRight)
    }

    func test_부채꼴은_최대_열줄이다() {
        let layout = BoxLayout.make(mode: .fan, anchor: CGPoint(x: 700, y: 60), in: CGRect(x: 0, y: 0, width: 1440, height: 2000), itemCount: 25)

        XCTAssertEqual(layout.fanRows, BoxLayout.maxFanRows)
    }

    func test_자리가_모자라면_들어가는_줄만_보인다() {
        // 아래로 500pt: (500 - 48 - 16) / 58 = 7줄, 그중 한 줄은 "그 외 N개" 자리
        let layout = BoxLayout.make(mode: .fan, anchor: CGPoint(x: 700, y: 500), in: screen, itemCount: 25)

        XCTAssertEqual(layout.fanRows, 6)
        XCTAssertLessThanOrEqual(layout.size.height, 500 + BoxLayout.iconArea / 2)
    }

    func test_담긴게_적으면_그만큼만_보인다() {
        XCTAssertEqual(BoxLayout.make(mode: .fan, anchor: CGPoint(x: 700, y: 60), in: screen, itemCount: 2).fanRows, 2)
        XCTAssertEqual(BoxLayout.make(mode: .fan, anchor: CGPoint(x: 700, y: 60), in: screen, itemCount: 0).fanRows, 0)
    }

    func test_모드가_달라도_아이콘_가로자리는_같다() {
        // 펼칠 때 아이콘이 튀지 않으려면 창 원점에서 아이콘까지의 가로 거리가 방향만으로 정해져야 한다
        for iconOnRight in [true, false] {
            var offsets: [CGFloat] = []
            for mode in [BoxLayout.Mode.icon, .fan, .list] {
                var layout = BoxLayout(mode: mode)
                layout.iconOnRight = iconOnRight
                layout.fanRows = 4
                let fromEdge = iconOnRight ? layout.size.width - layout.iconOffsetFromOrigin.x : layout.iconOffsetFromOrigin.x
                offsets.append(fromEdge)
            }
            XCTAssertEqual(Set(offsets).count, 1, "아이콘에서 바깥 모서리까지 거리가 모드마다 달라요: \(offsets)")
        }
    }

    func test_위로_펼치면_아이콘은_창_아래쪽에_있다() {
        var layout = BoxLayout(mode: .fan)
        layout.fanRows = 3
        layout.opensUp = true
        XCTAssertEqual(layout.iconOffsetFromOrigin.y, BoxLayout.iconArea / 2)
        layout.opensUp = false
        XCTAssertEqual(layout.iconOffsetFromOrigin.y, layout.size.height - BoxLayout.iconArea / 2)
    }
}
