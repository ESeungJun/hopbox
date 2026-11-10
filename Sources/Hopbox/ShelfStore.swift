import AppKit
import HopboxCore

struct Toast: Equatable {
    let id = UUID()
    let message: String
    var undoable = false
}

/// 상자에 담긴 것들. 앱을 다시 켜도 남도록 Application Support 에 저장한다.
/// 파일을 읽고 쓰는 일은 `ShelfStorage`(HopboxCore)가 하고, 여기는 담기·꺼내기·빼기 규칙과 알림을 맡는다.
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published var isDropTargeted = false
    @Published private(set) var toast: Toast?
    /// 무언가 담길 때마다 1씩 오른다. 상자 아이콘이 이 값을 보고 들썩인다
    @Published private(set) var addPulse = 0
    /// 다른 앱이 써 주기를 기다리는 파일 약속 묶음 수. 0 보다 크면 상자에 진행 표시가 돈다
    @Published private(set) var receiving = 0
    /// 보관 폴더가 차지하는 바이트. 목록 머리에 보여 준다
    @Published private(set) var usageBytes: Int64 = 0
    private(set) var lastAddedCount = 0
    /// 켤 때 목록을 어떻게 읽었는지
    let loadState: ShelfStorage.LoadState

    private let storage: ShelfStorage
    private let defaults: UserDefaults
    private var toastWorkItem: DispatchWorkItem?
    /// 방금 뺀 항목. 되돌리기 시간이 지나야 보관 파일을 실제로 지운다
    private var pendingRemoval: [ShelfItem] = []
    private var purgeWorkItem: DispatchWorkItem?
    /// 자동으로 담은 클립보드 이미지의 클립보드 번호
    private var capturedChangeCount: Int?
    /// 상자를 띄울 때 한 번 보여 줄 알림 (상자가 안 보일 때 생긴 일)
    private var notices: [String] = []
    /// 눌러서 복사한 그림. 붙여넣는 앱이 달라는 형식을 그때 만들어 준다
    private var copyProvider: PictureProvider?

    /// 변환·복사처럼 오래 걸릴 수 있는 파일 일은 여기서 차례로 한다 (메인 스레드를 막지 않게)
    private let ioQueue = DispatchQueue(label: "com.haul.hopbox.io", qos: .userInitiated)

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let retentionKey = "autoRetentionDays"
    static let removeAfterSendKey = "removeAfterSend"
    /// 이보다 긴 글은 담지 않는다. 담고 뺄 때마다 목록 파일 전체를 다시 쓰기 때문이다
    static let maxTextLength = 1_000_000

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Self.retentionKey: 0, Self.removeAfterSendKey: false])
        storage = ShelfStorage(directory: directory ?? Self.defaultDirectory())
        do {
            try storage.prepare()
        } catch {
            Log.storage.error("보관 폴더를 만들지 못함: \(error.localizedDescription, privacy: .public)")
            notices.append("보관 폴더를 만들지 못했어요")
        }

        var result = storage.load()
        if result.state == .failed {
            // 목록은 못 읽었어도 보관 파일은 남아 있다. 다시 목록에 올려 다음에 정리되지 않게 한다
            result.items = storage.adoptOrphans()
            Log.storage.error("목록을 읽지 못해 보관 파일 \(result.items.count, privacy: .public)개를 다시 올림")
            notices.append("목록을 읽지 못했어요 · 보관한 파일은 남겼어요")
        }
        loadState = result.state
        items = Ordering.pinnedFirst(result.items)
        if result.canCleanOrphans { storage.removeOrphanImages(keeping: items) }
        if result.relocated || (result.state == .failed && !items.isEmpty) { save() }
        purgeExpired()
        refreshUsage()
    }

    /// 기본 저장 폴더. 예전 이름(Parcel)으로 담아 둔 것이 있으면 새 이름으로 옮겨 온다.
    /// 개발·시험 때는 HOPBOX_DATA_DIR 로 다른 폴더를 쓸 수 있다 (실제 보관 폴더를 건드리지 않게)
    private static func defaultDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["HOPBOX_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = support.appendingPathComponent("Hopbox", isDirectory: true)
        let legacy = support.appendingPathComponent("Parcel", isDirectory: true)
        let manager = FileManager.default
        if !manager.fileExists(atPath: current.path), manager.fileExists(atPath: legacy.path) {
            try? manager.moveItem(at: legacy, to: current)
        }
        return current
    }

    // MARK: - 담기

    /// 이미지로 보는 클립보드 형식. 앱마다 png·tiff 말고도 jpeg·gif·heic·webp 로 올린다
    static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff,
        .init("public.jpeg"), .init("com.compuserve.gif"), .init("public.heic"),
        .init("org.webmproject.webp"), .init("com.microsoft.bmp"),
    ]

    /// 끌어다 놓기로 받을 형식. 브라우저·Slack 은 이미지를 "파일 약속(file promise)" 으로 넘긴다
    static let droppableTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .URL, .string] + imageTypes + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) }

    func canAdd(from pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self, NSString.self, NSImage.self, NSFilePromiseReceiver.self], options: nil)
    }

    /// 드롭과 ⌘V 가 같은 경로로 들어온다. 파일 → 파일 약속 → 이미지 → 텍스트 순으로 본다.
    /// 브라우저에서 이미지를 복사하면 주소 글자가 같이 실리므로 이미지를 텍스트보다 먼저 본다.
    /// 다만 서식 있는 텍스트(rtf)가 함께 있으면 엑셀·Pages 처럼 글을 복사한 경우라 텍스트로 담는다.
    /// 돌려주는 수는 받아들인 개수다. 복사·변환이 필요한 것은 뒤에서 끝난 다음 목록에 들어온다
    @discardableResult
    func add(from pasteboard: NSPasteboard) -> Int {
        Log.types("담기", pasteboard)
        let types = pasteboard.types ?? []
        if types.contains(Self.concealedType) {
            showToast("비밀번호처럼 숨겨진 값은 담지 않아요")
            return 0
        }

        if pasteboard.name == .general && pasteboard.changeCount == capturedChangeCount {
            showToast("이미 담겨 있어요")
            return 0
        }

        let fileURLs = Self.fileURLs(in: pasteboard)
        let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        let hasImage = types.contains(where: Self.imageTypes.contains)
        let hasRichText = types.contains(.rtf) || types.contains(.rtfd)
        let string = pasteboard.string(forType: .string)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }

        if !fileURLs.isEmpty {
            let existing = Set(items.compactMap { $0.kind == .file ? $0.path : nil })
            // 스크린샷 미리보기·메신저가 넘겨주는 임시 파일은 곧 지워지므로 상자에 복사해 둔다
            let wanted = fileURLs.filter { TempPath.isTemporary($0) || !existing.contains($0.path) }
            guard !wanted.isEmpty else {
                showToast("이미 담겨 있어요")
                return 0
            }
            guard wanted.contains(where: { TempPath.isTemporary($0) }) else {
                insert(wanted.map(Self.fileItem))
                return wanted.count
            }
            insertWhenReady { [storage] in
                wanted.compactMap { url in
                    TempPath.isTemporary(url) ? storage.keepCopy(of: url).map(ShelfItem.image) : Self.fileItem(url)
                }
            }
            return wanted.count
        }
        if !promises.isEmpty {
            receive(promises)
            return promises.count
        }
        if hasImage, !hasRichText || string == nil, let source = PictureSource(pasteboard) {
            insertWhenReady { [storage] in
                storage.savePicture(source).map { [.image($0)] } ?? []
            }
            return 1
        }
        guard let string else {
            showToast(types.isEmpty ? "복사한 게 없어요" : "담을 수 있는 내용이 없어요")
            return 0
        }
        guard string.count <= Self.maxTextLength else {
            showToast("너무 긴 글은 담지 않아요")
            return 0
        }
        guard items.first(where: { !$0.isPinned })?.text != string else {
            showToast("이미 담겨 있어요")
            return 0
        }
        insert([.text(string)])
        return 1
    }

    /// 스크린샷·화면 기록 파일이 새로 저장됐을 때
    func addCapture(_ url: URL) {
        guard !items.contains(where: { $0.path == url.path }) else { return }
        var item = Self.fileItem(url)
        item.auto = true
        insert([item], message: "캡처를 담았어요")
    }

    /// 클립보드로 찍은 스크린샷이나 다른 앱에서 복사한 이미지. 같은 클립보드를 ⌘V 로 또 담지 않도록 기억해 둔다
    func addCaptureFromPasteboard(_ pasteboard: NSPasteboard) {
        // 앱이 이미지를 임시 파일로 함께 올렸으면 원래 이름과 화질 그대로 보관한다
        let temporary = Self.fileURLs(in: pasteboard).first(where: { TempPath.isTemporary($0) })
        let source = temporary == nil ? PictureSource(pasteboard) : nil
        guard temporary != nil || source != nil else { return }
        capturedChangeCount = pasteboard.changeCount
        insertWhenReady(auto: true, message: "복사한 이미지를 담았어요", failure: nil) { [storage] in
            let saved = temporary.flatMap(storage.keepCopy(of:)) ?? source.flatMap(storage.savePicture)
            return saved.map { [.image($0)] } ?? []
        }
    }

    /// 원본을 가리키는 항목. 원본이 옮겨져도 찾을 수 있게 북마크를 같이 둔다
    private static func fileItem(_ url: URL) -> ShelfItem {
        var item = ShelfItem.file(url)
        item.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return item
    }

    private func insert(_ newItems: [ShelfItem], message: String? = nil) {
        items = Ordering.pinnedFirst(newItems + items)
        let saved = save()
        lastAddedCount = newItems.count
        addPulse += 1
        showToast(saved ? message ?? Wording.added(newItems) : Self.saveFailedMessage)
        refreshUsage()
    }

    /// 복사·변환을 뒤에서 하고 끝나면 목록에 넣는다. failure 가 nil 이면 실패해도 알리지 않는다
    private func insertWhenReady(
        auto: Bool = false, message: String? = nil, failure: String? = "담지 못했어요",
        _ work: @escaping () -> [ShelfItem]
    ) {
        ioQueue.async { [weak self] in
            var made = work()
            if auto { made = made.map { var item = $0; item.auto = true; return item } }
            DispatchQueue.main.async {
                guard let self else { return }
                guard !made.isEmpty else {
                    if let failure { self.showToast(failure) }
                    return
                }
                self.insert(made, message: message)
            }
        }
    }

    static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// 파일 약속을 받아 상자 보관 폴더에 파일을 만든다. 파일은 보내는 앱이 나중에 써 주므로 끝나면 담는다.
    /// 큰 파일은 오래 걸리므로 시간으로 끊지 않고, 받는 폴더의 크기가 한동안 그대로일 때만 포기한다
    private func receive(_ promises: [NSFilePromiseReceiver]) {
        let incoming = storage.imagesDirectory.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        receiving += 1
        showToast("가져오는 중…", sticky: true)
        let group = DispatchGroup()
        var received: [URL] = []
        for promise in promises {
            group.enter()
            promise.receivePromisedFiles(atDestination: incoming, options: [:], operationQueue: Self.promiseQueue) { url, error in
                if let error { Log.transfer.error("파일 약속 실패: \(error.localizedDescription, privacy: .public)") }
                DispatchQueue.main.async {
                    if error == nil { received.append(url) }
                    group.leave()
                }
            }
        }

        var finished = false
        var detector = StallDetector()
        let watch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard !finished else { return timer.invalidate() }
            guard detector.isStalled(size: Self.size(of: incoming)) else { return }
            finished = true
            timer.invalidate()
            try? FileManager.default.removeItem(at: incoming)
            self?.receiving -= 1
            self?.showToast("가져오지 못했어요")
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, !finished else { return }
            finished = true
            watch.invalidate()
            self.receiving -= 1
            // 받은 파일을 보관 폴더로 옮기고 임시 폴더는 지운다
            let kept: [URL] = received.compactMap { url in
                let destination = self.storage.uniqueURL(named: url.lastPathComponent)
                guard (try? FileManager.default.moveItem(at: url, to: destination)) != nil else { return nil }
                Self.markQuarantined(destination)
                return destination
            }
            try? FileManager.default.removeItem(at: incoming)
            guard !kept.isEmpty else { return self.showToast("가져오지 못했어요") }
            self.insert(kept.map(ShelfItem.image))
        }
    }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private static func size(of folder: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// 다른 앱이 넘겨준 파일에 "다른 곳에서 받음" 표시를 붙인다. 보내는 앱이 이미 붙였으면 그대로 둔다
    private static func markQuarantined(_ url: URL) {
        var url = url
        let current = try? url.resourceValues(forKeys: [.quarantinePropertiesKey])
        guard current?.quarantineProperties == nil else { return }
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String]
        try? url.setResourceValues(values)
    }

    // MARK: - 꺼내기

    func copyToPasteboard(_ item: ShelfItem) {
        let pasteboard = NSPasteboard.general
        switch item.kind {
        case .text:
            pasteboard.clearContents()
            pasteboard.setString(item.text ?? "", forType: .string)
        case .file:
            guard item.exists, let url = item.url else { return showToast("원본 파일을 찾을 수 없어요") }
            pasteboard.clearContents()
            pasteboard.writeObjects([url as NSURL])
        case .image:
            guard item.exists, let url = item.url else { return showToast("보관한 파일이 없어요") }
            guard item.isPicture else {
                pasteboard.clearContents()
                pasteboard.writeObjects([url as NSURL])
                break
            }
            // 메신저·문서는 이미지 데이터를, Finder 는 파일을 가져가도록 둘 다 올린다.
            // 파일은 뒤에서 읽고, 다른 형식으로 바꾸는 일은 붙여넣는 앱이 달라고 할 때 한다
            ioQueue.async { [weak self] in
                let provider = PictureProvider(url: url)
                DispatchQueue.main.async {
                    guard let self else { return }
                    let entry = NSPasteboardItem()
                    entry.setString(url.absoluteString, forType: .fileURL)
                    if let provider {
                        self.copyProvider = provider
                        entry.setDataProvider(provider, forTypes: provider.types)
                    }
                    pasteboard.clearContents()
                    pasteboard.writeObjects([entry])
                    self.showToast("복사했어요")
                }
            }
            return
        }
        showToast("복사했어요")
    }

    /// 끌어낼 때 대상 앱에 넘기는 내용. 파일·이미지는 파일 URL 로 넘겨 첨부로 들어가게 한다.
    func pasteboardWriter(for item: ShelfItem) -> NSPasteboardWriting? {
        switch item.kind {
        case .text:
            return item.text.map { $0 as NSString }
        case .file, .image:
            guard item.exists, let url = item.url else { return nil }
            return url as NSURL
        }
    }

    func dragImage(for item: ShelfItem) -> NSImage {
        switch item.kind {
        case .text:
            return NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil) ?? NSImage()
        case .file, .image:
            return Thumbnails.cached(item.path ?? "") ?? NSWorkspace.shared.icon(forFile: item.path ?? "")
        }
    }

    func revealInFinder(_ item: ShelfItem) {
        guard let url = item.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 끌어낸 것을 다른 앱이 받았을 때. 보냈다고 표시하고, 설정이 켜져 있으면 상자에서 뺀다
    func markSent(_ ids: [UUID]) {
        let sent = Set(ids)
        guard items.contains(where: { sent.contains($0.id) }) else { return }
        if removesAfterSend {
            remove(items.filter { sent.contains($0.id) && !$0.isPinned })
            return
        }
        let now = Date()
        items = items.map { item in
            guard sent.contains(item.id) else { return item }
            var marked = item
            marked.sentAt = now
            return marked
        }
        save()
    }

    var removesAfterSend: Bool {
        get { defaults.bool(forKey: Self.removeAfterSendKey) }
        set { defaults.set(newValue, forKey: Self.removeAfterSendKey) }
    }

    // MARK: - 고정

    func togglePin(_ item: ShelfItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].pinned = item.isPinned ? nil : true
        // 고정을 풀면 담은 순서 자리로 돌아간다
        items = items.filter(\.isPinned) + items.filter { !$0.isPinned }.sorted { $0.addedAt > $1.addedAt }
        let saved = save()
        showToast(saved ? (item.isPinned ? "고정을 풀었어요" : "맨 위에 고정했어요") : Self.saveFailedMessage)
    }

    // MARK: - 옮겨진 원본 따라가기

    /// 원본이 다른 폴더로 옮겨지거나 이름이 바뀌었으면 북마크로 새 위치를 찾는다. 상자를 띄울 때 부른다
    func followMovedOriginals() {
        var changed = false
        items = items.map { item in
            guard item.kind == .file, !item.exists, let bookmark = item.bookmark else { return item }
            var stale = false
            guard let found = try? URL(
                resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                relativeTo: nil, bookmarkDataIsStale: &stale
            ) else { return item }
            // 휴지통으로 간 것은 지운 것이다
            guard found.path != item.path, !found.path.contains("/.Trash/"),
                  FileManager.default.fileExists(atPath: found.path)
            else { return item }
            var moved = item
            moved.path = found.path
            if stale { moved.bookmark = try? found.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
            changed = true
            return moved
        }
        if changed { save() }
    }

    // MARK: - 빼기 (되돌리기 가능)

    func remove(_ item: ShelfItem) {
        remove([item])
    }

    func removeAll() {
        remove(items)
    }

    private func remove(_ removed: [ShelfItem]) {
        guard !removed.isEmpty else { return }
        purgePendingRemoval()
        let ids = Set(removed.map(\.id))
        items.removeAll { ids.contains($0.id) }
        pendingRemoval = removed
        let saved = save()
        let message = removed.count == 1 ? "상자에서 뺐어요" : "\(removed.count)개를 비웠어요"
        showToast(saved ? message : Self.saveFailedMessage, undoable: true)

        let work = DispatchWorkItem { [weak self] in self?.purgePendingRemoval() }
        purgeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoSeconds, execute: work)
    }

    func undoRemove() {
        guard !pendingRemoval.isEmpty else { return }
        purgeWorkItem?.cancel()
        items = Ordering.pinnedFirst((items + pendingRemoval).sorted { $0.addedAt > $1.addedAt })
        pendingRemoval = []
        save()
        showToast("되돌렸어요")
    }

    /// 되돌리기 시간이 끝났거나 앱을 끌 때 부른다
    func purgePendingRemoval() {
        purgeWorkItem?.cancel()
        pendingRemoval.forEach(deleteOwnedFile)
        pendingRemoval = []
        refreshUsage()
    }

    /// 상자가 만든 보관 파일만 지운다. 사용자가 담은 원본 파일은 건드리지 않는다.
    private func deleteOwnedFile(of item: ShelfItem) {
        guard item.kind == .image, let url = item.url, storage.isOwned(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 보관 기한

    /// 자동으로 담긴 것을 며칠 둘지. 0 이면 계속 둔다
    var retentionDays: Int {
        get { defaults.integer(forKey: Self.retentionKey) }
        set {
            defaults.set(newValue, forKey: Self.retentionKey)
            purgeExpired()
        }
    }

    /// 기한이 지난 자동 항목을 정리한다. 켤 때와 한 시간마다 부른다. 직접 담은 것·고정한 것은 그대로 둔다
    func purgeExpired(now: Date = Date()) {
        let expired = Retention.expired(items, now: now, days: retentionDays)
        guard !expired.isEmpty else { return }
        let ids = Set(expired.map(\.id))
        items.removeAll { ids.contains($0.id) }
        guard save() else { return }
        expired.forEach(deleteOwnedFile)
        refreshUsage()
        Log.storage.notice("기한이 지난 자동 항목 \(expired.count, privacy: .public)개 정리")
    }

    private func refreshUsage() {
        ioQueue.async { [weak self, storage] in
            let bytes = storage.usage()
            DispatchQueue.main.async { self?.usageBytes = bytes }
        }
    }

    // MARK: - 저장

    private static let saveFailedMessage = "저장하지 못했어요 · 다시 켜면 사라질 수 있어요"

    /// 실패하면 기록을 남기고 false. 부른 쪽이 알림 문구를 바꾼다
    @discardableResult
    private func save() -> Bool {
        do {
            try storage.save(items)
            return true
        } catch {
            Log.storage.error("목록 저장 실패: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - 알림

    static let undoSeconds: TimeInterval = 5

    /// sticky 면 다음 알림이 올 때까지 남는다 (받는 중 표시)
    func showToast(_ message: String, undoable: Bool = false, sticky: Bool = false) {
        toastWorkItem?.cancel()
        toast = Toast(message: message, undoable: undoable)
        guard !sticky else { return }
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWorkItem = work
        let seconds = undoable ? Self.undoSeconds : max(1.6, min(4, Double(message.count) * 0.12))
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// 상자가 안 보일 때 생긴 일은 모아 두었다가 다음에 띄울 때 하나씩 보여 준다
    func queueNotice(_ message: String) {
        guard !notices.contains(message) else { return }
        notices.append(message)
    }

    func showNextNotice() {
        guard !notices.isEmpty else { return }
        showToast(notices.removeFirst())
    }
}

// MARK: - 그림 주고받기

/// 클립보드에서 읽은 그림 데이터. 읽기는 메인 스레드에서, PNG 로 바꾸는 일은 뒤에서 한다
struct PictureSource {
    let data: Data
    let isPNG: Bool

    init?(_ pasteboard: NSPasteboard) {
        if let png = pasteboard.data(forType: .png) {
            data = png
            isPNG = true
        } else if let raw = ShelfStore.imageTypes.lazy.compactMap({ pasteboard.data(forType: $0) }).first {
            data = raw
            isPNG = false
        } else if let tiff = NSImage(pasteboard: pasteboard)?.tiffRepresentation {
            data = tiff
            isPNG = false
        } else {
            return nil
        }
    }

    init(data: Data, isPNG: Bool) {
        self.data = data
        self.isPNG = isPNG
    }

    var png: Data? {
        if isPNG { return data }
        let bitmap = NSBitmapImageRep(data: data) ?? NSImage(data: data)?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        return bitmap?.representation(using: .png, properties: [:])
    }
}

extension ShelfStorage {
    /// 파일을 상자 보관 폴더로 복사한다. 이름이 겹치면 뒤에 짧은 꼬리표를 붙인다
    func keepCopy(of url: URL) -> URL? {
        let destination = uniqueURL(named: url.lastPathComponent)
        return (try? FileManager.default.copyItem(at: url, to: destination)) != nil ? destination : nil
    }

    func savePicture(_ source: PictureSource) -> URL? {
        guard let png = source.png else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = uniqueURL(named: "이미지 \(formatter.string(from: Date())).png")
        return (try? png.write(to: url)) != nil ? url : nil
    }
}

/// 눌러서 복사한 그림을 붙여넣는 앱이 원하는 형식으로 내준다.
/// 파일 내용을 들고 있으므로 복사한 뒤 상자에서 빼도 붙여넣기가 된다
final class PictureProvider: NSObject, NSPasteboardItemDataProvider {
    private let source: PictureSource
    let types: [NSPasteboard.PasteboardType]

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let isPNG = url.pathExtension.lowercased() == "png"
        source = PictureSource(data: data, isPNG: isPNG)
        types = isPNG ? [.png, .tiff] : [.tiff, .png]
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        switch type {
        case .png:
            if let png = source.png { item.setData(png, forType: .png) }
        case .tiff:
            if let tiff = NSImage(data: source.data)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        default:
            break
        }
    }
}
