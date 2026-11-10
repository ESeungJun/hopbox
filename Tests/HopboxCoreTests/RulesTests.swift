import XCTest
@testable import HopboxCore

final class RulesTests: XCTestCase {
    // MARK: - 버전 비교

    func test_버전은_숫자단위로_비교한다() {
        XCTAssertTrue(Versioning.isNewer("1.0.10", than: "1.0.9"))
        XCTAssertTrue(Versioning.isNewer("1.1", than: "1.0.9"))
        XCTAssertTrue(Versioning.isNewer("2", than: "1.9.9"))
        XCTAssertFalse(Versioning.isNewer("1.0.2", than: "1.0.2"))
        XCTAssertFalse(Versioning.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(Versioning.isNewer("1.0.1", than: "1.0.2"))
        XCTAssertFalse(Versioning.isNewer("", than: "1.0.0"))
    }

    func test_태그의_v를_떼고_버전과_맞춘다() {
        XCTAssertTrue(UpdateRules.tagMatches("v1.0.3", version: "1.0.3"))
        XCTAssertTrue(UpdateRules.tagMatches("1.0.3", version: "1.0.3"))
        XCTAssertFalse(UpdateRules.tagMatches("v1.0.3", version: "1.0.2"))
    }

    // MARK: - 임시 폴더 판정

    func test_임시폴더와_캐시의_파일은_임시로_본다() {
        XCTAssertTrue(TempPath.isTemporary(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("a.png")))
        XCTAssertTrue(TempPath.isTemporary(URL(fileURLWithPath: "/private/var/folders/ab/cd/T/shot.png")))
        XCTAssertTrue(TempPath.isTemporary(URL(fileURLWithPath: "/private/tmp/a.png")))
        XCTAssertTrue(TempPath.isTemporary(URL(fileURLWithPath: "/Users/someone/Library/Caches/com.app/a.png")))
    }

    func test_사용자폴더의_파일은_임시가_아니다() {
        XCTAssertFalse(TempPath.isTemporary(URL(fileURLWithPath: "/Users/someone/Desktop/a.png")))
        XCTAssertFalse(TempPath.isTemporary(URL(fileURLWithPath: "/Users/someone/Library/Application Support/Hopbox/images/a.png")))
        XCTAssertFalse(TempPath.isTemporary(URL(fileURLWithPath: "/Volumes/USB/a.png")))
    }

    // MARK: - 보관 기한

    private func item(daysAgo: Double, auto: Bool, pinned: Bool = false, now: Date) -> ShelfItem {
        var item = ShelfItem(kind: .image, path: "/x/a.png", addedAt: now.addingTimeInterval(-daysAgo * 86_400))
        item.auto = auto ? true : nil
        item.pinned = pinned ? true : nil
        return item
    }

    func test_기한이_지난_자동항목만_고른다() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = item(daysAgo: 7.1, auto: true, now: now)
        let fresh = item(daysAgo: 6.9, auto: true, now: now)
        let manual = item(daysAgo: 30, auto: false, now: now)
        let pinned = item(daysAgo: 30, auto: true, pinned: true, now: now)

        let expired = Retention.expired([old, fresh, manual, pinned], now: now, days: 7)

        XCTAssertEqual(expired.map(\.id), [old.id])
    }

    func test_기한이_계속이면_아무것도_고르지_않는다() {
        let now = Date()
        XCTAssertTrue(Retention.expired([item(daysAgo: 400, auto: true, now: now)], now: now, days: 0).isEmpty)
    }

    func test_하루_기한의_경계() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let exactly = item(daysAgo: 1, auto: true, now: now)
        let over = item(daysAgo: 1.001, auto: true, now: now)

        XCTAssertEqual(Retention.expired([exactly, over], now: now, days: 1).map(\.id), [over.id])
    }

    func test_고정한것이_맨위고_나머지_순서는_그대로다() {
        var a = ShelfItem.text("a"), b = ShelfItem.text("b"), c = ShelfItem.text("c"), d = ShelfItem.text("d")
        b.pinned = true
        d.pinned = true
        _ = (a, c)
        a.pinned = nil
        c.pinned = false

        XCTAssertEqual(Ordering.pinnedFirst([a, b, c, d]).map(\.text), ["b", "d", "a", "c"])
    }

    // MARK: - 파일 약속 멈춤

    func test_크기가_늘고있으면_오래걸려도_멈춘게_아니다() {
        let start = Date(timeIntervalSince1970: 0)
        var detector = StallDetector(timeout: 10, now: start)
        for second in 1...120 {
            XCTAssertFalse(detector.isStalled(size: Int64(second) * 1_000_000, now: start.addingTimeInterval(Double(second))))
        }
    }

    func test_크기가_10초동안_그대로면_멈춘것이다() {
        let start = Date(timeIntervalSince1970: 0)
        var detector = StallDetector(timeout: 10, now: start)
        XCTAssertFalse(detector.isStalled(size: 0, now: start))
        XCTAssertFalse(detector.isStalled(size: 0, now: start.addingTimeInterval(9.9)))
        XCTAssertTrue(detector.isStalled(size: 0, now: start.addingTimeInterval(10)))
    }

    func test_멈췄다가_다시_늘면_시간을_다시_잰다() {
        let start = Date(timeIntervalSince1970: 0)
        var detector = StallDetector(timeout: 10, now: start)
        _ = detector.isStalled(size: 5, now: start)
        XCTAssertFalse(detector.isStalled(size: 9, now: start.addingTimeInterval(9)))
        XCTAssertFalse(detector.isStalled(size: 9, now: start.addingTimeInterval(18)))
        XCTAssertTrue(detector.isStalled(size: 9, now: start.addingTimeInterval(19)))
    }

    // MARK: - 업데이트 안내

    func test_dmg에서_바로_열었으면_옮기라고_안내한다() {
        let path = "/private/var/folders/ab/T/AppTranslocation/1234-5678/d"
        XCTAssertTrue(UpdateRules.isTranslocated(path))
        XCTAssertEqual(UpdateRules.unwritableMessage(folder: path), "택배상자를 응용 프로그램 폴더로 옮긴 뒤 다시 열어 주세요")
    }

    func test_그밖의_쓸수없는_폴더는_경로를_알려준다() {
        XCTAssertFalse(UpdateRules.isTranslocated("/Applications"))
        XCTAssertEqual(UpdateRules.unwritableMessage(folder: "/Applications"), "/Applications 폴더에 쓸 수 없어요")
    }

    // MARK: - 키보드로 고르기

    func test_숫자키는_1부터_9_그리고_0이_열째다() {
        XCTAssertEqual(KeyPick.index(digit: 1, count: 10), 0)
        XCTAssertEqual(KeyPick.index(digit: 9, count: 10), 8)
        XCTAssertEqual(KeyPick.index(digit: 0, count: 10), 9)
    }

    func test_없는_줄의_숫자키는_무시한다() {
        XCTAssertNil(KeyPick.index(digit: 3, count: 2))
        XCTAssertNil(KeyPick.index(digit: 0, count: 9))
        XCTAssertNil(KeyPick.index(digit: 1, count: 0))
        XCTAssertNil(KeyPick.index(digit: 12, count: 20))
    }

    func test_줄번호_글자() {
        XCTAssertEqual((0..<11).map { KeyPick.label(index: $0) }, ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", nil])
    }

    func test_화살표는_처음엔_끝줄을_잡고_끝에서_멈춘다() {
        XCTAssertEqual(KeyPick.move(nil, by: 1, count: 3), 0)
        XCTAssertEqual(KeyPick.move(nil, by: -1, count: 3), 2)
        XCTAssertEqual(KeyPick.move(2, by: 1, count: 3), 2)
        XCTAssertEqual(KeyPick.move(0, by: -1, count: 3), 0)
        XCTAssertEqual(KeyPick.move(1, by: 1, count: 3), 2)
        XCTAssertNil(KeyPick.move(nil, by: 1, count: 0))
    }

    func test_숫자는_그줄을_꺼내고_없는줄이면_키만_먹는다() {
        XCTAssertEqual(KeyPick.action(for: .digit(2), itemCount: 5, rows: 5, selected: nil, nextIsUp: true), .pick(1))
        XCTAssertEqual(KeyPick.action(for: .digit(0), itemCount: 12, rows: 10, selected: nil, nextIsUp: true), .pick(9))
        XCTAssertEqual(KeyPick.action(for: .digit(7), itemCount: 5, rows: 5, selected: nil, nextIsUp: true), .swallow)
        // 부채꼴에 다 안 보여도 열째까지는 숫자로 꺼낸다
        XCTAssertEqual(KeyPick.action(for: .digit(8), itemCount: 12, rows: 4, selected: nil, nextIsUp: true), .pick(7))
    }

    func test_위로_펼친_부채꼴은_위화살표가_다음줄이다() {
        XCTAssertEqual(KeyPick.action(for: .up, itemCount: 5, rows: 5, selected: nil, nextIsUp: true), .select(0))
        XCTAssertEqual(KeyPick.action(for: .up, itemCount: 5, rows: 5, selected: 0, nextIsUp: true), .select(1))
        XCTAssertEqual(KeyPick.action(for: .down, itemCount: 5, rows: 5, selected: 1, nextIsUp: true), .select(0))
    }

    func test_아래로_펼쳤거나_목록이면_아래화살표가_다음줄이다() {
        XCTAssertEqual(KeyPick.action(for: .down, itemCount: 5, rows: 5, selected: nil, nextIsUp: false), .select(0))
        XCTAssertEqual(KeyPick.action(for: .down, itemCount: 5, rows: 5, selected: 0, nextIsUp: false), .select(1))
        XCTAssertEqual(KeyPick.action(for: .up, itemCount: 5, rows: 5, selected: 1, nextIsUp: false), .select(0))
    }

    func test_화살표는_보이는_줄_안에서만_움직인다() {
        XCTAssertEqual(KeyPick.action(for: .up, itemCount: 25, rows: 6, selected: 5, nextIsUp: true), .select(5))
        XCTAssertEqual(KeyPick.action(for: .down, itemCount: 0, rows: 0, selected: nil, nextIsUp: false), .swallow)
    }

    func test_엔터와_지우기는_고른줄이_있을때만_동작한다() {
        XCTAssertEqual(KeyPick.action(for: .enter, itemCount: 5, rows: 5, selected: 3, nextIsUp: true), .pick(3))
        XCTAssertEqual(KeyPick.action(for: .delete, itemCount: 5, rows: 5, selected: 3, nextIsUp: true), .remove(3))
        XCTAssertEqual(KeyPick.action(for: .enter, itemCount: 5, rows: 5, selected: nil, nextIsUp: true), .pass)
        XCTAssertEqual(KeyPick.action(for: .delete, itemCount: 5, rows: 5, selected: nil, nextIsUp: true), .pass)
        XCTAssertEqual(KeyPick.action(for: .delete, itemCount: 2, rows: 2, selected: 4, nextIsUp: true), .pass)
    }

    // MARK: - 문구

    func test_하나_담으면_이름을_보여준다() {
        XCTAssertEqual(Wording.added([.file(URL(fileURLWithPath: "/a/보고서.pdf"))]), "보고서.pdf 담았어요")
        XCTAssertEqual(Wording.added([.text("안녕하세요")]), "글 담았어요")
    }

    func test_여러개면_개수를_보여준다() {
        let items = [ShelfItem.text("a"), .text("b"), .text("c")]
        XCTAssertEqual(Wording.added(items), "3개 담았어요")
    }

    func test_긴_이름은_가운데를_줄인다() {
        let name = "아주아주아주 긴 스크린샷 파일 이름 2026-11-10.png"
        let short = Wording.shortened(name, to: 18)
        XCTAssertEqual(short.count, 18)
        XCTAssertTrue(short.hasPrefix("아주아주"))
        XCTAssertTrue(short.hasSuffix(".png"))
        XCTAssertEqual(Wording.shortened("짧다.png", to: 18), "짧다.png")
    }

    func test_용량_표시() {
        XCTAssertEqual(Wording.size(0), "0KB")
        XCTAssertEqual(Wording.size(512 * 1024), "512KB")
        XCTAssertEqual(Wording.size(12 * 1024 * 1024), "12MB")
        XCTAssertEqual(Wording.size(3 * 1024 * 1024 * 1024 / 2), "1.5GB")
    }

    // MARK: - 항목

    func test_그림인지는_확장자로_본다() {
        XCTAssertTrue(ShelfItem.image(URL(fileURLWithPath: "/a/shot.PNG")).isPicture)
        XCTAssertTrue(ShelfItem.image(URL(fileURLWithPath: "/a/photo.heic")).isPicture)
        XCTAssertFalse(ShelfItem.image(URL(fileURLWithPath: "/a/doc.pdf")).isPicture)
        XCTAssertFalse(ShelfItem.text("png").isPicture)
    }

    func test_글_미리보기는_공백을_한칸으로_줄인다() {
        XCTAssertEqual(ShelfItem.text("  가\n\n나\t다  ").title, "가 나 다")
    }
}
