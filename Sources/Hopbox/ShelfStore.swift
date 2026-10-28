import AppKit

struct ShelfItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case file   // 원본 파일을 가리키기만 한다 (복사하지 않음)
        case image  // 붙여넣은 이미지. 상자 폴더에 png 로 저장해 파일처럼 끌어낼 수 있게 한다
        case text
    }

    let id: UUID
    let kind: Kind
    var path: String?
    var text: String?
    /// 텍스트 미리보기. 긴 텍스트를 화면을 그릴 때마다 다듬지 않도록 담을 때 한 번 만든다
    var preview: String?
    var textLength: Int?
    let addedAt: Date

    var url: URL? { path.map { URL(fileURLWithPath: $0) } }

    var exists: Bool {
        guard let path else { return kind == .text }
        return FileManager.default.fileExists(atPath: path)
    }

    /// 목록·부채꼴에 보이는 이름
    var title: String {
        switch kind {
        case .text: return preview ?? ShelfItem.makePreview(text ?? "")
        case .file, .image: return url?.lastPathComponent ?? ""
        }
    }

    static func file(_ url: URL) -> ShelfItem {
        ShelfItem(id: UUID(), kind: .file, path: url.path, addedAt: Date())
    }

    static func image(_ url: URL) -> ShelfItem {
        ShelfItem(id: UUID(), kind: .image, path: url.path, addedAt: Date())
    }

    static func text(_ string: String) -> ShelfItem {
        ShelfItem(
            id: UUID(), kind: .text, text: string,
            preview: makePreview(string), textLength: string.count, addedAt: Date()
        )
    }

    private static func makePreview(_ string: String) -> String {
        String(string.prefix(300))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct Toast: Equatable {
    let id = UUID()
    let message: String
    var undoable = false
}

/// 상자에 담긴 것들. 앱을 다시 켜도 남도록 Application Support 에 저장한다.
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published var isDropTargeted = false
    @Published private(set) var toast: Toast?
    /// 무언가 담길 때마다 1씩 오른다. 상자 아이콘이 이 값을 보고 들썩인다
    @Published private(set) var addPulse = 0
    private(set) var lastAddedCount = 0

    private let directory: URL
    private let imagesDirectory: URL
    private var listFile: URL { directory.appendingPathComponent("items.json") }
    private var toastWorkItem: DispatchWorkItem?
    /// 방금 뺀 항목. 되돌리기 시간이 지나야 이미지 파일을 실제로 지운다
    private var pendingRemoval: [ShelfItem] = []
    private var purgeWorkItem: DispatchWorkItem?
    /// 자동으로 담은 클립보드 이미지의 클립보드 번호
    private var capturedChangeCount: Int?

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        imagesDirectory = self.directory.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        load()
        removeOrphanImages()
    }

    /// 기본 저장 폴더. 예전 이름(Parcel)으로 담아 둔 것이 있으면 새 이름으로 옮겨 온다
    private static func defaultDirectory() -> URL {
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

    func canAdd(from pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self, NSString.self, NSImage.self], options: nil)
    }

    /// 드롭과 ⌘V 가 같은 경로로 들어온다. 파일 → 이미지 → 텍스트 순으로 본다.
    /// 브라우저에서 이미지를 복사하면 주소 글자가 같이 실리므로 이미지를 텍스트보다 먼저 본다.
    /// 다만 서식 있는 텍스트(rtf)가 함께 있으면 엑셀·Pages 처럼 글을 복사한 경우라 텍스트로 담는다.
    @discardableResult
    func add(from pasteboard: NSPasteboard) -> Int {
        let types = pasteboard.types ?? []
        if types.contains(Self.concealedType) {
            showToast("비밀번호처럼 숨겨진 값은 담지 않아요")
            return 0
        }

        if pasteboard.name == .general && pasteboard.changeCount == capturedChangeCount {
            showToast("이미 담겨 있어요")
            return 0
        }

        let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        let hasImage = types.contains(.png) || types.contains(.tiff)
        let hasRichText = types.contains(.rtf) || types.contains(.rtfd)
        let string = pasteboard.string(forType: .string)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }

        var newItems: [ShelfItem] = []
        var isDuplicate = false

        if !fileURLs.isEmpty {
            let existing = Set(items.compactMap { $0.kind == .file ? $0.path : nil })
            newItems = fileURLs.filter { !existing.contains($0.path) }.map(ShelfItem.file)
            isDuplicate = newItems.isEmpty
        } else if hasImage, !hasRichText || string == nil, let imageURL = saveImage(from: pasteboard) {
            newItems = [.image(imageURL)]
        } else if let string {
            if items.first?.text == string {
                isDuplicate = true
            } else {
                newItems = [.text(string)]
            }
        }

        guard !newItems.isEmpty else {
            showToast(isDuplicate ? "이미 담겨 있어요" : "담을 수 있는 내용이 없어요")
            return 0
        }
        insert(newItems, message: "\(newItems.count)개 담았어요")
        return newItems.count
    }

    /// 스크린샷·화면 기록 파일이 새로 저장됐을 때
    func addCapture(_ url: URL) {
        guard !items.contains(where: { $0.path == url.path }) else { return }
        insert([.file(url)], message: "캡처를 담았어요")
    }

    /// 클립보드로 찍은 스크린샷이나 다른 앱에서 복사한 이미지. 같은 클립보드를 ⌘V 로 또 담지 않도록 기억해 둔다
    func addCaptureFromPasteboard(_ pasteboard: NSPasteboard) {
        guard let imageURL = saveImage(from: pasteboard) else { return }
        capturedChangeCount = pasteboard.changeCount
        insert([.image(imageURL)], message: "복사한 이미지를 담았어요")
    }

    private func insert(_ newItems: [ShelfItem], message: String) {
        items.insert(contentsOf: newItems, at: 0)
        save()
        lastAddedCount = newItems.count
        addPulse += 1
        showToast(message)
    }

    private func saveImage(from pasteboard: NSPasteboard) -> URL? {
        let pngData: Data?
        if let data = pasteboard.data(forType: .png) {
            pngData = data
        } else if let tiff = pasteboard.data(forType: .tiff) ?? NSImage(pasteboard: pasteboard)?.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) {
            pngData = bitmap.representation(using: .png, properties: [:])
        } else {
            pngData = nil
        }
        guard let pngData else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = formatter.string(from: Date())
        var url = imagesDirectory.appendingPathComponent("이미지 \(stamp).png")
        if FileManager.default.fileExists(atPath: url.path) {
            url = imagesDirectory.appendingPathComponent("이미지 \(stamp) \(UUID().uuidString.prefix(4)).png")
        }
        do {
            try pngData.write(to: url)
            return url
        } catch {
            return nil
        }
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
            // 메신저·문서는 이미지 데이터를, Finder 는 파일을 가져가도록 둘 다 올린다
            guard let url = item.url, let data = try? Data(contentsOf: url) else {
                return showToast("이미지 파일이 없어요")
            }
            let entry = NSPasteboardItem()
            entry.setData(data, forType: .png)
            if let tiff = NSImage(data: data)?.tiffRepresentation {
                entry.setData(tiff, forType: .tiff)
            }
            entry.setString(url.absoluteString, forType: .fileURL)
            pasteboard.clearContents()
            pasteboard.writeObjects([entry])
        }
        showToast("복사했어요 · ⌘V 로 붙여넣기")
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
        save()
        showToast(removed.count == 1 ? "상자에서 뺐어요" : "\(removed.count)개를 비웠어요", undoable: true)

        let work = DispatchWorkItem { [weak self] in self?.purgePendingRemoval() }
        purgeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoSeconds, execute: work)
    }

    func undoRemove() {
        guard !pendingRemoval.isEmpty else { return }
        purgeWorkItem?.cancel()
        items = (items + pendingRemoval).sorted { $0.addedAt > $1.addedAt }
        pendingRemoval = []
        save()
        showToast("되돌렸어요")
    }

    /// 되돌리기 시간이 끝났거나 앱을 끌 때 부른다
    func purgePendingRemoval() {
        purgeWorkItem?.cancel()
        pendingRemoval.forEach(deleteOwnedFile)
        pendingRemoval = []
    }

    /// 상자가 만든 이미지 파일만 지운다. 사용자가 담은 원본 파일은 건드리지 않는다.
    private func deleteOwnedFile(of item: ShelfItem) {
        guard item.kind == .image, let url = item.url, isOwnedImage(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func isOwnedImage(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == imagesDirectory.standardizedFileURL
    }

    /// 앱이 되돌리기 시간 중에 꺼지면 이미지 파일이 남는다. 켤 때 목록에 없는 이미지를 정리한다.
    private func removeOrphanImages() {
        let referenced = Set(items.compactMap { $0.kind == .image ? $0.url?.standardizedFileURL.path : nil })
        let files = (try? FileManager.default.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !referenced.contains(file.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - 저장

    private func load() {
        guard let data = try? Data(contentsOf: listFile),
              let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data)
        else { return }
        // 저장 폴더가 옮겨졌으면 붙여넣은 이미지 경로를 지금 폴더로 고친다.
        // 고치지 않으면 바로 뒤 정리에서 목록에 없는 파일로 보고 지워 버린다
        var moved = false
        items = decoded.map { item in
            guard item.kind == .image, let url = item.url, !isOwnedImage(url) else { return item }
            let relocated = imagesDirectory.appendingPathComponent(url.lastPathComponent)
            guard FileManager.default.fileExists(atPath: relocated.path) else { return item }
            var fixed = item
            fixed.path = relocated.path
            moved = true
            return fixed
        }
        if moved { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: listFile, options: .atomic)
    }

    // MARK: - 알림

    static let undoSeconds: TimeInterval = 5

    func showToast(_ message: String, undoable: Bool = false) {
        toastWorkItem?.cancel()
        toast = Toast(message: message, undoable: undoable)
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (undoable ? Self.undoSeconds : 1.6), execute: work)
    }
}
