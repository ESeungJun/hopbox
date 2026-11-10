import AppKit
import Carbon
import HopboxCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let welcomedKey = "didWelcome"
    private static let captureTitle = "스크린샷·화면 기록 자동 담기"

    private let store = ShelfStore()
    private var panel: ShelfPanel!
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private lazy var captureWatcher = ScreenCaptureWatcher(store: store)
    private let captureFilesItem = NSMenuItem(title: AppDelegate.captureTitle, action: #selector(toggleCaptureFiles), keyEquivalent: "")
    private let grantAccessItem = NSMenuItem(title: "폴더 접근 허용하기…", action: #selector(openFolderAccessSettings), keyEquivalent: "")
    private let copiedImagesItem = NSMenuItem(title: "복사한 이미지 자동 담기", action: #selector(toggleCopiedImages), keyEquivalent: "")
    private let retentionItem = NSMenuItem(title: "자동으로 담긴 것 보관", action: nil, keyEquivalent: "")
    private let removeAfterSendItem = NSMenuItem(title: "꺼낸 것은 상자에서 빼기", action: #selector(toggleRemoveAfterSend), keyEquivalent: "")
    private let followItem = NSMenuItem(title: "화면을 옮기면 따라오기", action: #selector(toggleFollow), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLoginItem), keyEquivalent: "")
    private let openItem = NSMenuItem(title: "상자 열기", action: #selector(openPanel), keyEquivalent: "")
    private var recorderWindow: ShortcutRecorderWindow?
    private let updater = Updater()
    private let versionItem = NSMenuItem(title: "택배상자 \(Updater.currentVersion)", action: nil, keyEquivalent: "")
    private let updateItem = NSMenuItem(title: "업데이트 확인…", action: #selector(checkForUpdates), keyEquivalent: "")
    private var retentionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = ShelfPanel(store: store)
        setUpStatusItem()
        captureWatcher.start()
        // 새 버전은 창을 띄우지 않고 메뉴 막대와, 다음에 상자를 부를 때 알림 자리로 알린다
        updater.onChange = { [weak self] in
            self?.updateUpdateItem()
            self?.updateStatusIcon()
        }
        updater.onFound = { [weak self] version in
            self?.store.queueNotice("새 버전 \(version) 이 나왔어요 · 메뉴에서 설치")
        }
        updater.start()

        // 자동으로 담긴 것의 보관 기한은 켤 때 한 번(ShelfStore.init), 그 뒤로 한 시간마다 본다
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.purgeExpired() }
        }
        retentionTimer?.tolerance = 60

        if !registerHotKey(Shortcut.saved) {
            // 메뉴 막대 앱이라 앞으로 가져오지 않으면 알림이 다른 창 뒤에 깔린다
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "단축키 \(Shortcut.saved.displayName) 를 등록하지 못했어요"
            alert.informativeText = "다른 앱이 같은 단축키를 쓰고 있을 수 있어요. 메뉴 막대의 상자 아이콘에서 단축키를 바꿀 수 있어요."
            alert.runModal()
        }
        welcomeIfFirstRun()
        #if DEBUG
        runDemo()
        #endif
    }

    #if DEBUG
    /// 개발용(디버그 빌드에만 있다): 단축키·마우스 없이 화면 동작을 차례로 재생한다.
    /// 예) HOPBOX_DEMO="show,wait:1.6,key:up,wait:0.3,key:3,wait:1,hop,wait:1,hide"
    /// 쓰던 앱의 키 입력을 가져오지 않도록 상자를 키 창으로 만들지 않는다
    private func runDemo() {
        guard let script = ProcessInfo.processInfo.environment["HOPBOX_DEMO"],
              let area = NSScreen.screens.first?.visibleFrame
        else { return }
        // HOPBOX_DEMO_AT="x,y" 로 자리를 정할 수 있다 (화면 구석에 띄워 방해하지 않게)
        let at = (ProcessInfo.processInfo.environment["HOPBOX_DEMO_AT"] ?? "").split(separator: ",").compactMap { Double($0) }
        let point = at.count == 2
            ? NSPoint(x: at[0], y: at[1])
            : NSPoint(x: area.midX, y: area.minY + area.height * 0.3)
        let keys: [String: KeyPick.Key] = ["up": .up, "down": .down, "enter": .enter, "delete": .delete]
        var delay = 0.0
        for step in script.split(separator: ",") {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : ""
            if parts[0] == "wait" {
                delay += Double(argument) ?? 0
                continue
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                switch parts[0] {
                case "show": self.panel.demoShow(at: point, arrival: .drop)
                case "hop": self.panel.demoShow(at: point, arrival: .hop)
                case "hide": self.panel.hide()
                case "list": self.panel.demoShowList()
                case "key": self.panel.press(keys[argument] ?? .digit(Int(argument) ?? 1))
                case "add":
                    let pasteboard = NSPasteboard(name: .init("hopbox-demo"))
                    pasteboard.clearContents()
                    pasteboard.setString(argument.isEmpty ? "새로 담은 글" : argument, forType: .string)
                    self.store.add(from: pasteboard)
                default: break
                }
            }
        }
    }
    #endif

    /// 처음 켰을 때 상자를 한 번 떨어뜨리고 부르는 법과 자동 담기를 알린다.
    /// 메뉴 막대 앱이라 그냥 두면 켜도 아무 일도 일어나지 않는다
    private func welcomeIfFirstRun() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.welcomedKey) else { return }
        defaults.set(true, forKey: Self.welcomedKey)
        // 쓰던 사람이 새 버전으로 올라온 것이면 안내하지 않는다
        guard store.loadState == .missing, let screen = NSScreen.main else { return }

        store.queueNotice("\(Shortcut.saved.displayName) 로 어디서든 불러요")
        store.queueNotice("스크린샷·복사한 이미지는 알아서 담아요")
        store.queueNotice("자동 담기는 메뉴 막대에서 끌 수 있어요")
        if UpdateRules.isTranslocated(Bundle.main.bundlePath) {
            store.queueNotice("응용 프로그램 폴더로 옮겨야 자동 업데이트가 돼요")
        }
        let area = screen.visibleFrame
        panel.show(at: NSPoint(x: area.midX, y: area.minY + area.height * 0.3))
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
                // 등록이 되는 조합인지 한 번 등록해 보고 바로 푼다
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

    // MARK: - 메뉴 막대

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(openItem)
        menu.addItem(NSMenuItem(title: "모두 비우기", action: #selector(clearAll), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(captureFilesItem)
        grantAccessItem.indentationLevel = 1
        grantAccessItem.isHidden = true
        menu.addItem(grantAccessItem)
        menu.addItem(copiedImagesItem)
        retentionItem.submenu = makeRetentionMenu()
        menu.addItem(retentionItem)
        menu.addItem(removeAfterSendItem)
        menu.addItem(followItem)
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "단축키 바꾸기…", action: #selector(changeShortcut), keyEquivalent: ""))
        menu.addItem(.separator())
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(updateItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) && $0.action != nil { $0.target = self } }
        statusItem.menu = menu

        updateStatusIcon()
        captureWatcher.onAccessChange = { [weak self] in self?.updateCaptureItem() }
    }

    private func makeRetentionMenu() -> NSMenu {
        let menu = NSMenu()
        for days in Retention.choices {
            let item = NSMenuItem(title: Retention.title(days: days), action: #selector(chooseRetention(_:)), keyEquivalent: "")
            item.tag = days
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    /// 메뉴 막대 아이콘은 늘 같은 상자다. 새 버전이 있을 때만 점을 찍는다
    private func updateStatusIcon() {
        let symbol = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "택배상자")
        let hasUpdate = updater.availableVersion != nil
        statusItem.button?.image = hasUpdate ? Self.dotted(symbol) : symbol
        statusItem.button?.toolTip = hasUpdate ? "택배상자 · 새 버전이 있어요" : nil
    }

    /// 새 버전이 있다는 점을 아이콘 오른쪽 위에 찍는다. 메뉴 막대 색을 따르도록 템플릿 그림으로 만든다
    private static func dotted(_ symbol: NSImage?) -> NSImage? {
        guard let symbol else { return nil }
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            let dot = NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 6, height: 6)
            // 점 둘레를 비워 상자 그림과 붙어 보이지 않게 한다
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        updateCaptureItem()
        copiedImagesItem.state = captureWatcher.watchesPasteboard ? .on : .off
        removeAfterSendItem.state = store.removesAfterSend ? .on : .off
        followItem.state = UserDefaults.standard.bool(forKey: ShelfPanel.followsSpacesKey) ? .on : .off
        retentionItem.submenu?.items.forEach { $0.state = $0.tag == store.retentionDays ? .on : .off }
    }

    /// 켜 두었는데 폴더를 못 열어 지켜보지 못하는 중이면 까닭을 제목에 적고, 허용하러 가는 항목을 보여 준다
    private func updateCaptureItem() {
        captureFilesItem.state = captureWatcher.watchesFiles ? .on : .off
        switch captureWatcher.folderAccess {
        case .denied: captureFilesItem.title = "\(Self.captureTitle) (폴더 접근 허용 필요)"
        case .missing: captureFilesItem.title = "\(Self.captureTitle) (저장 폴더를 찾을 수 없음)"
        case .off, .watching: captureFilesItem.title = Self.captureTitle
        }
        grantAccessItem.isHidden = captureWatcher.folderAccess != .denied
    }

    @objc private func openFolderAccessSettings() {
        // 시스템 설정 › 개인정보 보호 및 보안 › 파일 및 폴더
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func checkForUpdates() {
        updater.menuAction()
    }

    /// 새 버전이 있으면 메뉴 항목이 "설치" 로, 받는 중이면 눌리지 않게 바뀐다
    private func updateUpdateItem() {
        switch updater.state {
        case .idle: updateItem.title = "업데이트 확인…"
        case .available(let version): updateItem.title = "새 버전 \(version) 설치…"
        case .installing: updateItem.title = "업데이트 받는 중…"
        }
        updateItem.isEnabled = updater.state != .installing
    }

    @objc private func toggleCaptureFiles() {
        captureWatcher.watchesFiles.toggle()
    }

    @objc private func toggleCopiedImages() {
        captureWatcher.watchesPasteboard.toggle()
    }

    @objc private func chooseRetention(_ sender: NSMenuItem) {
        store.retentionDays = sender.tag
    }

    @objc private func toggleRemoveAfterSend() {
        store.removesAfterSend.toggle()
    }

    @objc private func toggleFollow() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: ShelfPanel.followsSpacesKey), forKey: ShelfPanel.followsSpacesKey)
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
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "자동 실행 설정을 바꾸지 못했어요"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
