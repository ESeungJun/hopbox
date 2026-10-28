import AppKit
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = ShelfStore()
    private var panel: ShelfPanel!
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private lazy var captureWatcher = ScreenCaptureWatcher(store: store)
    private let captureFilesItem = NSMenuItem(title: "스크린샷·화면 기록 자동 담기", action: #selector(toggleCaptureFiles), keyEquivalent: "")
    private let copiedImagesItem = NSMenuItem(title: "복사한 이미지 자동 담기", action: #selector(toggleCopiedImages), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLoginItem), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = ShelfPanel(store: store)
        setUpStatusItem()
        captureWatcher.start()

        // ⌥⌘B — Box
        hotKey = HotKey(keyCode: kVK_ANSI_B, modifiers: cmdKey | optionKey) { [weak self] in
            self?.panel.toggle()
        }
        if hotKey == nil {
            let alert = NSAlert()
            alert.messageText = "단축키 ⌥⌘B 를 등록하지 못했어요"
            alert.informativeText = "다른 앱이 같은 단축키를 쓰고 있을 수 있어요. 메뉴 막대의 상자 아이콘으로 열 수 있어요."
            alert.runModal()
        }
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "택배상자")

        let menu = NSMenu()
        menu.delegate = self
        let open = NSMenuItem(title: "상자 열기", action: #selector(openPanel), keyEquivalent: "b")
        open.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(open)
        menu.addItem(NSMenuItem(title: "모두 비우기", action: #selector(clearAll), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(captureFilesItem)
        menu.addItem(copiedImagesItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        captureFilesItem.state = captureWatcher.watchesFiles ? .on : .off
        copiedImagesItem.state = captureWatcher.watchesPasteboard ? .on : .off
    }

    @objc private func toggleCaptureFiles() {
        captureWatcher.watchesFiles.toggle()
    }

    @objc private func toggleCopiedImages() {
        captureWatcher.watchesPasteboard.toggle()
    }

    @objc private func openPanel() {
        panel.show()
    }

    @objc private func clearAll() {
        // 되돌리기 알림이 보이도록 상자를 띄운 채로 비운다
        panel.show()
        store.removeAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.purgePendingRemoval()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "자동 실행 설정을 바꾸지 못했어요"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
