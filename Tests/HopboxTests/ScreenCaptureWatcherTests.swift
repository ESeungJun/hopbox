import XCTest
@testable import Hopbox

/// 스크린샷 폴더를 못 열 때 조용히 넘어가지 않고 상태로 알리는지 본다.
final class ScreenCaptureWatcherTests: XCTestCase {
    private var root: URL!
    private var storeDirectory: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        root = manager.temporaryDirectory.appendingPathComponent("hopbox-watch-\(UUID().uuidString)")
        storeDirectory = root.appendingPathComponent("store")
        try manager.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("shots").path)
        try? manager.removeItem(at: root)
    }

    private func makeWatcher(folder: URL) -> ScreenCaptureWatcher {
        let suite = "hopbox-test-\(UUID().uuidString)"
        let store = ShelfStore(directory: storeDirectory, defaults: UserDefaults(suiteName: suite)!)
        return ScreenCaptureWatcher(store: store, folder: folder)
    }

    func test_열수있는_폴더는_지켜본다() throws {
        let folder = root.appendingPathComponent("shots")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let watcher = makeWatcher(folder: folder)

        watcher.startFiles()
        defer { watcher.stopFiles() }

        XCTAssertEqual(watcher.folderAccess, .watching)
    }

    func test_접근이_막힌_폴더는_거부로_알리고_허용되면_다시_붙는다() throws {
        let folder = root.appendingPathComponent("shots")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        let watcher = makeWatcher(folder: folder)
        var changes = 0
        watcher.onAccessChange = { changes += 1 }

        watcher.startFiles()
        defer { watcher.stopFiles() }
        XCTAssertEqual(watcher.folderAccess, .denied)
        XCTAssertEqual(changes, 1)

        // 아직 막혀 있으면 그대로
        watcher.checkFolder()
        XCTAssertEqual(watcher.folderAccess, .denied)
        XCTAssertEqual(changes, 1)

        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        watcher.checkFolder()
        XCTAssertEqual(watcher.folderAccess, .watching)
        XCTAssertEqual(changes, 2)
    }

    func test_없는_폴더는_없음으로_알린다() {
        let watcher = makeWatcher(folder: root.appendingPathComponent("nowhere"))

        watcher.startFiles()
        defer { watcher.stopFiles() }

        XCTAssertEqual(watcher.folderAccess, .missing)
    }

    func test_끄면_꺼짐이다() throws {
        let folder = root.appendingPathComponent("shots")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let watcher = makeWatcher(folder: folder)

        watcher.startFiles()
        watcher.stopFiles()

        XCTAssertEqual(watcher.folderAccess, .off)
    }

    func test_새로_생긴_스크린샷만_담는다() throws {
        let folder = root.appendingPathComponent("shots")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent("스크린샷 예전.png"))
        let suite = "hopbox-test-\(UUID().uuidString)"
        let store = ShelfStore(directory: storeDirectory, defaults: UserDefaults(suiteName: suite)!)
        let watcher = ScreenCaptureWatcher(store: store, folder: folder)
        watcher.startFiles()
        defer { watcher.stopFiles() }

        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("스크린샷 새것.png"))
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("메모.txt"))

        let added = expectation(description: "새 스크린샷이 담긴다")
        let watch = store.$items.sink { if !$0.isEmpty { added.fulfill() } }
        wait(for: [added], timeout: 6)
        watch.cancel()

        XCTAssertEqual(store.items.map(\.title), ["스크린샷 새것.png"])
        XCTAssertEqual(store.items.first?.isAuto, true)
    }
}
