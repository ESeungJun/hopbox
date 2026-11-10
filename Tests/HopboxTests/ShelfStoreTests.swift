import XCTest
import HopboxCore
@testable import Hopbox

/// 켤 때 목록을 못 읽어도 보관 파일이 남는지, 상자 단위에서 본다 (재현 시험과 같은 세 경우).
final class ShelfStoreTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite = ""
    private let manager = FileManager.default

    override func setUpWithError() throws {
        directory = manager.temporaryDirectory.appendingPathComponent("hopbox-store-\(UUID().uuidString)")
        try manager.createDirectory(at: directory.appendingPathComponent("images"), withIntermediateDirectories: true)
        suite = "hopbox-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        try? manager.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    private func keep(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent("images").appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    private func writeList(_ json: String) throws {
        try Data(json.utf8).write(to: directory.appendingPathComponent("items.json"))
    }

    private func imageJSON(_ url: URL, extra: String = "") -> String {
        #"{"id":"\#(UUID().uuidString)","kind":"image","path":"\#(url.path)","addedAt":0\#(extra)}"#
    }

    private func makeStore() -> ShelfStore {
        ShelfStore(directory: directory, defaults: defaults)
    }

    private var backupCount: Int {
        ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".bak") }.count
    }

    func test_정상목록() throws {
        let image = try keep("a.png")
        try writeList("[\(imageJSON(image))]")

        let store = makeStore()

        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(manager.fileExists(atPath: image.path))
        XCTAssertEqual(backupCount, 0)
    }

    func test_잘린목록이어도_보관이미지가_남고_다시_목록에_오른다() throws {
        let image = try keep("a.png")
        try writeList("[" + String(imageJSON(image).dropLast(8)))

        let store = makeStore()

        XCTAssertEqual(store.loadState, .failed)
        XCTAssertTrue(manager.fileExists(atPath: image.path))
        XCTAssertEqual(store.items.map(\.path), [image.path])
        XCTAssertEqual(backupCount, 1)

        // 다시 켜도(이번에는 목록을 읽는다) 정리되지 않는다
        let again = makeStore()
        XCTAssertEqual(again.loadState, .loaded)
        XCTAssertTrue(manager.fileExists(atPath: image.path))
    }

    func test_빈_목록파일이어도_보관이미지가_남는다() throws {
        let image = try keep("a.png")
        try writeList("")

        let store = makeStore()

        XCTAssertEqual(store.loadState, .failed)
        XCTAssertTrue(manager.fileExists(atPath: image.path))
        XCTAssertEqual(backupCount, 1)
    }

    func test_모르는_kind가_섞여도_보관이미지가_남는다() throws {
        let image = try keep("a.png")
        let other = try keep("b.png")
        try writeList("[\(imageJSON(image)),{\"id\":\"\(UUID().uuidString)\",\"kind\":\"link\",\"path\":\"\(other.path)\",\"addedAt\":0}]")

        let store = makeStore()

        XCTAssertEqual(store.loadState, .partial(skipped: 1))
        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(manager.fileExists(atPath: image.path))
        XCTAssertTrue(manager.fileExists(atPath: other.path))
    }

    func test_기한이_지난_자동항목만_정리하고_보관파일을_지운다() throws {
        let old = try keep("old.png")
        let manual = try keep("manual.png")
        let pinned = try keep("pinned.png")
        // addedAt 0 = 2001년. 자동·수동·고정 하나씩
        try writeList("[\(imageJSON(old, extra: #","auto":true"#)),\(imageJSON(manual)),\(imageJSON(pinned, extra: #","auto":true,"pinned":true"#))]")
        defaults.set(7, forKey: ShelfStore.retentionKey)

        let store = makeStore()

        XCTAssertEqual(Set(store.items.compactMap(\.path)), [manual.path, pinned.path])
        XCTAssertFalse(manager.fileExists(atPath: old.path))
        XCTAssertTrue(manager.fileExists(atPath: manual.path))
        XCTAssertTrue(manager.fileExists(atPath: pinned.path))
    }

    func test_기한이_계속이면_자동항목도_남는다() throws {
        let old = try keep("old.png")
        try writeList("[\(imageJSON(old, extra: #","auto":true"#))]")

        let store = makeStore()

        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(manager.fileExists(atPath: old.path))
    }

    func test_고정하면_맨위로_풀면_담은순서로_돌아간다() throws {
        try writeList(#"[{"id":"\#(UUID().uuidString)","kind":"text","text":"새것","addedAt":300},{"id":"\#(UUID().uuidString)","kind":"text","text":"중간","addedAt":200},{"id":"\#(UUID().uuidString)","kind":"text","text":"옛것","addedAt":100}]"#)
        let store = makeStore()

        store.togglePin(store.items[2])
        XCTAssertEqual(store.items.map(\.text), ["옛것", "새것", "중간"])

        store.togglePin(store.items[0])
        XCTAssertEqual(store.items.map(\.text), ["새것", "중간", "옛것"])
        XCTAssertEqual(makeStore().items.map(\.text), ["새것", "중간", "옛것"], "저장돼 있어야 한다")
    }

    func test_보낸것은_표시하고_설정이_켜져있으면_뺀다() throws {
        try writeList(#"[{"id":"\#(UUID().uuidString)","kind":"text","text":"가","addedAt":2},{"id":"\#(UUID().uuidString)","kind":"text","text":"나","addedAt":1}]"#)
        let store = makeStore()

        store.markSent([store.items[0].id])
        XCTAssertTrue(store.items[0].isSent)
        XCTAssertFalse(store.items[1].isSent)

        store.removesAfterSend = true
        store.markSent([store.items[1].id])
        XCTAssertEqual(store.items.map(\.text), ["가"])
        store.undoRemove()
        XCTAssertEqual(store.items.map(\.text), ["가", "나"])
    }

    func test_저장하지_못하면_알림으로_알린다() throws {
        let store = makeStore()
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        let pasteboard = NSPasteboard(name: .init("hopbox-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("저장 안 되는 글", forType: .string)
        XCTAssertEqual(store.add(from: pasteboard), 1)

        XCTAssertEqual(store.toast?.message, "저장하지 못했어요 · 다시 켜면 사라질 수 있어요")
    }

    func test_글은_담기고_같은글은_다시_담지_않는다() {
        let store = makeStore()
        let pasteboard = NSPasteboard(name: .init("hopbox-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("안녕", forType: .string)

        XCTAssertEqual(store.add(from: pasteboard), 1)
        XCTAssertEqual(store.toast?.message, "글 담았어요")
        XCTAssertEqual(store.add(from: pasteboard), 0)
        XCTAssertEqual(store.toast?.message, "이미 담겨 있어요")
        XCTAssertEqual(store.items.count, 1)
    }

    func test_비밀번호_표시가_있는_값은_담지_않는다() {
        let store = makeStore()
        let pasteboard = NSPasteboard(name: .init("hopbox-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("hunter2", forType: .string)
        pasteboard.setString("", forType: .init("org.nspasteboard.ConcealedType"))

        XCTAssertEqual(store.add(from: pasteboard), 0)
        XCTAssertTrue(store.items.isEmpty)
    }

    func test_너무_긴_글은_담지_않는다() {
        let store = makeStore()
        let pasteboard = NSPasteboard(name: .init("hopbox-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString(String(repeating: "가", count: ShelfStore.maxTextLength + 1), forType: .string)

        XCTAssertEqual(store.add(from: pasteboard), 0)
        XCTAssertTrue(store.items.isEmpty)
    }

    func test_임시폴더의_파일은_복사해_보관하고_원본이_지워져도_남는다() throws {
        let store = makeStore()
        let temp = manager.temporaryDirectory.appendingPathComponent("hopbox-src-\(UUID().uuidString).png")
        try Data([9, 9, 9, 9]).write(to: temp)
        let pasteboard = NSPasteboard(name: .init("hopbox-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([temp as NSURL])

        XCTAssertEqual(store.add(from: pasteboard), 1)
        let added = expectation(description: "복사가 끝나 목록에 들어온다")
        let watch = store.$items.sink { if !$0.isEmpty { added.fulfill() } }
        wait(for: [added], timeout: 5)
        watch.cancel()

        try manager.removeItem(at: temp)
        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.kind, .image)
        XCTAssertTrue(item.exists)
        XCTAssertNotEqual(item.path, temp.path)
    }
}
