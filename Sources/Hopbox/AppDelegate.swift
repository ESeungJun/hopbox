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
    private let openItem = NSMenuItem(title: "상자 열기", action: #selector(openPanel), keyEquivalent: "")
    private var recorderWindow: ShortcutRecorderWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = ShelfPanel(store: store)
        setUpStatusItem()
        captureWatcher.start()

        if !registerHotKey(Shortcut.saved) {
            let alert = NSAlert()
            alert.messageText = "단축키 \(Shortcut.saved.displayName) 를 등록하지 못했어요"
            alert.informativeText = "다른 앱이 같은 단축키를 쓰고 있을 수 있어요. 메뉴 막대의 상자 아이콘에서 단축키를 바꿀 수 있어요."
            alert.runModal()
        }
    }

    // MARK: - 단축키

    @discardableResult
    private func registerHotKey(_ shortcut: Shortcut) -> Bool {
        hotKey = nil
        hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
            self?.panel.toggle()
        }
        let (key, modifiers) = shortcut.menuKeyEquivalent
        openItem.keyEquivalent = key
        openItem.keyEquivalentModifierMask = modifiers
        return hotKey != nil
    }

    @objc private func changeShortcut() {
        if let recorderWindow {
            recorderWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // 지금 단축키를 그대로 다시 누를 수 있게, 바꾸는 동안에는 등록을 풀어 둔다
        hotKey = nil
        let window = ShortcutRecorderWindow(
            current: Shortcut.saved,
            onRecord: { shortcut in
                // 다른 앱이 이미 쓰는 조합인지 한 번 등록해 보고 바로 푼다
                guard HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, action: {}) != nil else { return false }
                Shortcut.saved = shortcut
                return true
            },
            onEnd: { [weak self] in
                guard let self else { return }
                self.registerHotKey(Shortcut.saved)
                self.recorderWindow = nil
            }
        )
        recorderWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "택배상자")

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(openItem)
        menu.addItem(NSMenuItem(title: "모두 비우기", action: #selector(clearAll), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(captureFilesItem)
        menu.addItem(copiedImagesItem)
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "단축키 바꾸기…", action: #selector(changeShortcut), keyEquivalent: ""))
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
