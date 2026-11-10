import XCTest
@testable import HopboxCore

/// 목록 파일이 손상·빈 파일·부분 기록일 때 보관 파일을 지우지 않는지 본다.
final class ShelfStorageTests: XCTestCase {
    private var directory: URL!
    private var storage: ShelfStorage!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        directory = manager.temporaryDirectory.appendingPathComponent("hopbox-test-\(UUID().uuidString)")
        storage = ShelfStorage(directory: directory)
        try storage.prepare()
    }

    override func tearDown() {
        try? manager.removeItem(at: directory)
    }

    /// 보관 폴더에 파일 하나를 만들고 경로를 돌려준다
    private func keep(_ name: String) throws -> URL {
        let url = storage.imagesDirectory.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    private func writeList(_ json: String) throws {
        try Data(json.utf8).write(to: storage.listFile)
    }

    private func imageJSON(_ url: URL) -> String {
        #"{"id":"\#(UUID().uuidString)","kind":"image","path":"\#(url.path)","addedAt":0}"#
    }

    private var backups: [URL] {
        ((try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("items.json.") && $0.pathExtension == "bak" }
    }

    /// 켤 때 하는 일 그대로: 읽고, 정리해도 되면 정리한다
    private func open() -> ShelfStorage.LoadResult {
        let result = storage.load()
        if result.canCleanOrphans { storage.removeOrphanImages(keeping: result.items) }
        return result
    }

    func test_정상목록은_읽고_목록에없는_파일만_정리한다() throws {
        let kept = try keep("a.png")
        let orphan = try keep("orphan.png")
        try writeList("[\(imageJSON(kept))]")

        let result = open()

        XCTAssertEqual(result.state, .loaded)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertTrue(manager.fileExists(atPath: kept.path))
        XCTAssertFalse(manager.fileExists(atPath: orphan.path))
        XCTAssertTrue(backups.isEmpty)
    }

    func test_목록파일이_없으면_빈목록이고_백업을_만들지_않는다() throws {
        let result = open()

        XCTAssertEqual(result.state, .missing)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(backups.isEmpty)
    }

    func test_잘린목록이면_보관파일을_지우지않고_백업을_남긴다() throws {
        let kept = try keep("a.png")
        let broken = "[" + String(imageJSON(kept).dropLast(8))
        try writeList(broken)

        let result = open()

        XCTAssertEqual(result.state, .failed)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertFalse(result.canCleanOrphans)
        XCTAssertTrue(manager.fileExists(atPath: kept.path), "읽지 못한 목록의 보관 파일은 남아야 한다")
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: backups[0], encoding: .utf8), broken, "백업은 원본 그대로여야 한다")
    }

    func test_빈파일이면_보관파일을_지우지않고_백업을_남긴다() throws {
        let kept = try keep("a.png")
        try writeList("")

        let result = open()

        XCTAssertEqual(result.state, .failed)
        XCTAssertTrue(manager.fileExists(atPath: kept.path))
        XCTAssertEqual(backups.count, 1)
    }

    func test_배열이_아닌_내용이면_실패로_본다() throws {
        let kept = try keep("a.png")
        try writeList(#"{"items":[]}"#)

        XCTAssertEqual(open().state, .failed)
        XCTAssertTrue(manager.fileExists(atPath: kept.path))
        XCTAssertEqual(backups.count, 1)
    }

    func test_모르는항목이_섞이면_아는항목만_읽고_보관파일을_지우지않는다() throws {
        let kept = try keep("a.png")
        let other = try keep("b.png")
        let unknown = #"{"id":"\#(UUID().uuidString)","kind":"link","path":"\#(other.path)","addedAt":0}"#
        try writeList("[\(imageJSON(kept)),\(unknown)]")

        let result = open()

        XCTAssertEqual(result.state, .partial(skipped: 1))
        XCTAssertEqual(result.items.count, 1)
        XCTAssertFalse(result.canCleanOrphans)
        XCTAssertTrue(manager.fileExists(atPath: kept.path))
        XCTAssertTrue(manager.fileExists(atPath: other.path), "모르는 항목이 가리키는 파일도 남아야 한다")
    }

    func test_모르는항목은_저장해도_목록파일에_남는다() throws {
        let kept = try keep("a.png")
        let unknown = #"{"id":"\#(UUID().uuidString)","kind":"link","addedAt":0}"#
        try writeList("[\(imageJSON(kept)),\(unknown)]")

        let first = storage.load()
        try storage.save(first.items + [.text("새 글")])

        let reopened = ShelfStorage(directory: directory)
        let second = reopened.load()
        XCTAssertEqual(second.state, .partial(skipped: 1), "예전 버전이 저장해도 새 버전의 항목을 버리지 않는다")
        XCTAssertEqual(second.items.count, 2)
        XCTAssertEqual(second.items.last?.text, "새 글")
    }

    func test_읽기실패뒤_저장하면_새목록으로_덮어쓰고_백업은_남는다() throws {
        try writeList("[{\"id\":")
        _ = open()

        try storage.save([.text("가")])

        XCTAssertEqual(ShelfStorage(directory: directory).load().items.map(\.text), ["가"])
        XCTAssertEqual(backups.count, 1)
    }

    func test_백업은_최근_세개만_남긴다() throws {
        for second in 0..<5 {
            try writeList("깨짐 \(second)")
            _ = storage.load(now: Date(timeIntervalSince1970: 1_700_000_000 + Double(second)))
        }

        XCTAssertEqual(backups.count, 3)
        let contents = try backups.map { try String(contentsOf: $0, encoding: .utf8) }.sorted()
        XCTAssertEqual(contents, ["깨짐 2", "깨짐 3", "깨짐 4"])
    }

    func test_저장폴더가_옮겨졌으면_보관파일_경로를_지금폴더로_고친다() throws {
        let kept = try keep("a.png")
        let old = URL(fileURLWithPath: "/예전/Parcel/images/a.png")
        try writeList("[\(imageJSON(old))]")

        let result = open()

        XCTAssertTrue(result.relocated)
        XCTAssertEqual(result.items.first?.path, kept.path)
        XCTAssertTrue(manager.fileExists(atPath: kept.path))
    }

    func test_저장하고_다시읽으면_같은목록이다() throws {
        var pinned = ShelfItem.text("고정한 글")
        pinned.pinned = true
        var auto = ShelfItem.image(try keep("a.png"))
        auto.auto = true
        try storage.save([pinned, auto])

        let result = ShelfStorage(directory: directory).load()

        XCTAssertEqual(result.state, .loaded)
        XCTAssertEqual(result.items, [pinned, auto])
    }

    func test_예전버전이_쓴_목록도_읽는다() throws {
        // 1.0.2 가 쓰던 형식: auto·pinned·sentAt·bookmark 가 없다
        try writeList(#"[{"id":"\#(UUID().uuidString)","kind":"text","text":"안녕","preview":"안녕","textLength":2,"addedAt":700000000}]"#)

        let result = open()

        XCTAssertEqual(result.state, .loaded)
        XCTAssertEqual(result.items.first?.text, "안녕")
        XCTAssertFalse(result.items[0].isAuto)
        XCTAssertFalse(result.items[0].isPinned)
    }

    func test_읽지못한_목록의_보관파일은_항목으로_되살린다() throws {
        let older = try keep("a.png")
        let newer = try keep("b.pdf")
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: older.path)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: newer.path)
        try manager.createDirectory(at: storage.imagesDirectory.appendingPathComponent(".incoming-x"), withIntermediateDirectories: true)
        try writeList("{{{")
        XCTAssertEqual(storage.load().state, .failed)

        let adopted = storage.adoptOrphans()

        XCTAssertEqual(adopted.map(\.path), [newer.path, older.path], "받다 만 폴더는 빼고 최근 것부터")
        XCTAssertTrue(adopted.allSatisfy { $0.kind == .image })

        // 되살린 목록을 저장하면 다음에 켤 때 정리해도 남는다
        try storage.save(adopted)
        let reopened = ShelfStorage(directory: directory)
        let result = reopened.load()
        XCTAssertEqual(result.state, .loaded)
        reopened.removeOrphanImages(keeping: result.items)
        XCTAssertTrue(manager.fileExists(atPath: older.path))
        XCTAssertTrue(manager.fileExists(atPath: newer.path))
    }

    func test_겹치는_이름에는_꼬리표를_붙인다() throws {
        let first = try keep("a.png")
        let second = storage.uniqueURL(named: "a.png")

        XCTAssertNotEqual(second.path, first.path)
        XCTAssertEqual(second.pathExtension, "png")
        XCTAssertTrue(second.lastPathComponent.hasPrefix("a "))
        XCTAssertEqual(storage.uniqueURL(named: "new.png").lastPathComponent, "new.png")
    }

    func test_이름에_폴더구분자가_있어도_보관폴더_밖으로_나가지_않는다() {
        for name in ["../../evil.png", "/etc/passwd", "..", "a/b.png", ""] {
            let url = storage.uniqueURL(named: name)
            XCTAssertTrue(storage.isOwned(url), "\(name) → \(url.path)")
        }
    }

    func test_쓸수없는_폴더에_저장하면_오류를_던진다() throws {
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        XCTAssertThrowsError(try storage.save([.text("가")]))
    }

    func test_보관용량은_보관폴더_파일크기의_합이다() throws {
        _ = try keep("a.png")
        _ = try keep("b.png")

        XCTAssertEqual(storage.usage(), 6)
    }
}
