import AppKit

/// 찍거나 복사한 것을 상자에 자동으로 담는다. 두 가지는 따로 켜고 끈다.
/// - 스크린샷·화면 기록 파일: 스크린샷 저장 폴더(시스템 설정, 기본은 데스크톱)를 지켜본다
/// - 복사한 이미지: 클립보드 스크린샷(⌃⇧⌘4 등)과 Slack·브라우저에서 복사한 이미지
final class ScreenCaptureWatcher {
    static let filesKey = "autoAddScreenCaptures"
    static let pasteboardKey = "autoAddCopiedImages"

    private let store: ShelfStore
    private let folderOverride: URL?
    private var folderSource: DispatchSourceFileSystemObject?
    private var folder: URL?
    private var knownFiles: Set<String> = []
    private var scanWorkItem: DispatchWorkItem?
    private var folderCheckTimer: Timer?
    private var pasteboardTimer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    /// 스크린샷 기본 이름. 시스템 언어에 따라 달라서 둘 다 본다
    private static let capturePrefixes = ["스크린샷", "Screenshot", "화면 기록", "Screen Recording", "스냅샷"]

    /// folder 는 시험용. 비우면 시스템 스크린샷 저장 위치를 쓴다
    init(store: ShelfStore, folder: URL? = nil) {
        self.store = store
        folderOverride = folder
        UserDefaults.standard.register(defaults: [Self.filesKey: true, Self.pasteboardKey: true])
    }

    var watchesFiles: Bool {
        get { UserDefaults.standard.bool(forKey: Self.filesKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.filesKey)
            newValue ? startFiles() : stopFiles()
        }
    }

    var watchesPasteboard: Bool {
        get { UserDefaults.standard.bool(forKey: Self.pasteboardKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.pasteboardKey)
            newValue ? startPasteboard() : stopPasteboard()
        }
    }

    func start() {
        if watchesFiles { startFiles() }
        if watchesPasteboard { startPasteboard() }
    }

    func stop() {
        stopFiles()
        stopPasteboard()
    }

    // MARK: - 스크린샷·화면 기록 파일

    private func startFiles() {
        watchFolder()
        // 저장 위치를 바꾸면(⌘⇧5 옵션 등) 앱을 다시 켜지 않아도 새 폴더를 지켜보도록 가끔 확인한다
        folderCheckTimer?.invalidate()
        folderCheckTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.currentFolder() != self.folder else { return }
            self.watchFolder()
        }
    }

    private func stopFiles() {
        folderSource?.cancel()
        folderSource = nil
        folderCheckTimer?.invalidate()
        folderCheckTimer = nil
    }

    private static let screencaptureDomain = "com.apple.screencapture" as CFString

    /// 다른 앱의 설정이라 캐시된 값이 아닌 최신 값을 읽는다
    private static func screencaptureSetting(_ key: String) -> String? {
        CFPreferencesAppSynchronize(screencaptureDomain)
        return CFPreferencesCopyAppValue(key as CFString, screencaptureDomain) as? String
    }

    private func currentFolder() -> URL {
        if let folderOverride { return folderOverride }
        if let location = Self.screencaptureSetting("location"), !location.isEmpty {
            return URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].standardizedFileURL
    }

    private func watchFolder() {
        folderSource?.cancel()
        folderSource = nil
        let folder = currentFolder()
        self.folder = folder
        // 지켜보기 전부터 있던 파일은 담지 않는다
        knownFiles = Set(listFiles(in: folder).map(\.path))

        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                // 폴더가 지워지거나 옮겨지면 다음 위치 확인 때 다시 붙는다
                self.folderSource?.cancel()
                self.folderSource = nil
                self.folder = nil
            } else {
                self.scheduleScan()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        folderSource = source
    }

    private func listFiles(in folder: URL) -> [URL] {
        let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        return files ?? []
    }

    /// 폴더 변경은 한 번 저장에 여러 번 온다. 잠깐 모았다가 한 번 훑는다
    private func scheduleScan() {
        scanWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        scanWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func scan() {
        guard let folder else { return }
        for file in listFiles(in: folder) where !knownFiles.contains(file.path) {
            knownFiles.insert(file.path)
            if Self.isScreenCapture(file) {
                addWhenWritten(file, previousSize: -1, attempts: 0)
            }
        }
    }

    private static func isScreenCapture(_ url: URL) -> Bool {
        // macOS 는 스크린샷 파일에 이 속성을 붙인다. 이름을 바꿔 저장하도록 설정해도 잡힌다
        if getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0 { return true }
        let name = url.lastPathComponent
        let prefixes = capturePrefixes + [screencaptureSetting("name")].compactMap { $0 }.filter { !$0.isEmpty }
        return prefixes.contains { name.hasPrefix($0) }
    }

    /// 화면 기록은 파일이 다 써질 때까지 크기가 바뀐다. 크기가 멈추면 담는다
    private func addWhenWritten(_ url: URL, previousSize: Int, attempts: Int) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 0 && size == previousSize {
            store.addCapture(url)
            return
        }
        guard attempts < 60 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.addWhenWritten(url, previousSize: size, attempts: attempts + 1)
        }
    }

    // MARK: - 복사한 이미지

    private func startPasteboard() {
        pasteboardTimer?.invalidate()
        lastChangeCount = NSPasteboard.general.changeCount
        pasteboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
    }

    private func stopPasteboard() {
        pasteboardTimer?.invalidate()
        pasteboardTimer = nil
    }

    private func checkPasteboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard Self.isCopiedImage(pasteboard) else { return }
        store.addCaptureFromPasteboard(pasteboard)
    }

    /// 이미지를 복사한 경우만 고른다.
    /// - Finder 에서 파일을 복사하면 파일 아이콘 그림이 같이 실린다 → 사용자 폴더의 파일 URL 이 있으면 제외
    ///   (Slack 등은 복사한 이미지를 임시 파일로도 올리므로, 임시 파일이면 이미지로 본다)
    /// - 엑셀·Pages 는 글을 복사해도 그림을 같이 싣는다 → 서식 있는 텍스트가 있으면 제외
    static func isCopiedImage(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        let excluded: [NSPasteboard.PasteboardType] = [.rtf, .rtfd, .init("org.nspasteboard.ConcealedType")]
        guard types.contains(where: ShelfStore.imageTypes.contains),
              !types.contains(where: excluded.contains)
        else { return false }
        return ShelfStore.fileURLs(in: pasteboard).allSatisfy(ShelfStore.isTemporary)
    }
}
