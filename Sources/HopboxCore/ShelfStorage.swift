import Foundation

/// 상자 목록(items.json)과 보관 폴더(images/)를 읽고 쓴다. 화면을 모른다.
///
/// 목록을 읽지 못했을 때 지키는 것 (윈도우판 `ShelfStore.Load` 와 같다):
/// - 원본을 `items.json.<시각>.bak` 으로 남긴다
/// - 보관 폴더를 정리하지 않는다. 목록에 없다고 지우면 읽지 못한 목록이 가리키던 파일이 사라진다
public final class ShelfStorage {
    public enum LoadState: Equatable {
        /// 목록 파일이 없다 (처음 켰다)
        case missing
        case loaded
        /// 읽었지만 이 버전이 모르는 항목이 섞여 있다. 그 항목은 저장할 때 그대로 돌려 쓴다
        case partial(skipped: Int)
        /// 파일은 있는데 읽거나 해석하지 못했다
        case failed
    }

    public struct LoadResult {
        public var items: [ShelfItem] = []
        public var state = LoadState.missing
        /// 읽지 못한 목록을 남겨 둔 곳
        public var backup: URL?
        /// 저장 폴더가 옮겨져 보관 파일 경로를 고쳤다. 부른 쪽이 저장해야 한다
        public var relocated = false

        /// 목록을 온전히 읽었을 때만 목록에 없는 보관 파일을 지워도 된다
        public var canCleanOrphans: Bool { state == .loaded || state == .missing }
    }

    public let directory: URL
    public let imagesDirectory: URL
    public var listFile: URL { directory.appendingPathComponent("items.json") }

    /// 이 버전이 해석하지 못한 항목. 저장할 때 목록 끝에 그대로 붙인다
    private var preserved: [Any] = []
    private let manager = FileManager.default
    private static let keptBackups = 3

    public init(directory: URL) {
        self.directory = directory
        imagesDirectory = directory.appendingPathComponent("images", isDirectory: true)
    }

    public func prepare() throws {
        try manager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
    }

    // MARK: - 읽기

    public func load(now: Date = Date()) -> LoadResult {
        var result = LoadResult()
        preserved = []
        guard manager.fileExists(atPath: listFile.path) else { return result }

        guard let data = try? Data(contentsOf: listFile),
              let elements = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else {
            result.state = .failed
            result.backup = backUpList(now: now)
            return result
        }

        // 항목마다 따로 해석한다. 하나를 모른다고 목록 전체를 버리지 않는다
        let decoder = JSONDecoder()
        for element in elements {
            if element is [String: Any],
               let raw = try? JSONSerialization.data(withJSONObject: element),
               let item = try? decoder.decode(ShelfItem.self, from: raw) {
                result.items.append(item)
            } else {
                preserved.append(element)
            }
        }
        result.state = preserved.isEmpty ? .loaded : .partial(skipped: preserved.count)

        // 저장 폴더가 옮겨졌으면 보관 파일 경로를 지금 폴더로 고친다.
        // 고치지 않으면 정리할 때 목록에 없는 파일로 보고 지워 버린다
        result.items = result.items.map { item in
            guard item.kind == .image, let url = item.url, !isOwned(url) else { return item }
            let relocated = imagesDirectory.appendingPathComponent(url.lastPathComponent)
            guard manager.fileExists(atPath: relocated.path) else { return item }
            var fixed = item
            fixed.path = relocated.path
            result.relocated = true
            return fixed
        }
        return result
    }

    /// 읽지 못한 목록을 덮어쓰기 전에 옆에 남긴다. 계속 못 읽어도 쌓이지 않게 최근 것만 둔다
    private func backUpList(now: Date) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = directory.appendingPathComponent("items.json.\(formatter.string(from: now)).bak")
        try? manager.removeItem(at: backup)
        guard (try? manager.copyItem(at: listFile, to: backup)) != nil else { return nil }

        let older = backups().sorted { $0.lastPathComponent > $1.lastPathComponent }.dropFirst(Self.keptBackups)
        older.forEach { try? manager.removeItem(at: $0) }
        return backup
    }

    private func backups() -> [URL] {
        let files = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("items.json.") && $0.pathExtension == "bak" }
    }

    // MARK: - 쓰기

    public func save(_ items: [ShelfItem]) throws {
        var data = try JSONEncoder().encode(items)
        if !preserved.isEmpty, var elements = try JSONSerialization.jsonObject(with: data) as? [Any] {
            elements.append(contentsOf: preserved)
            data = try JSONSerialization.data(withJSONObject: elements)
        }
        try data.write(to: listFile, options: .atomic)
    }

    // MARK: - 보관 폴더

    public func isOwned(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == imagesDirectory.standardizedFileURL
    }

    /// 앱이 되돌리기 시간 중에 꺼지면 보관 파일이 남는다. 목록에 없는 것을 지우고 지운 수를 돌려준다.
    /// `LoadResult.canCleanOrphans` 가 참일 때만 부른다
    @discardableResult
    public func removeOrphanImages(keeping items: [ShelfItem]) -> Int {
        let referenced = Set(items.compactMap { $0.kind == .image ? $0.url?.standardizedFileURL.path : nil })
        let files = (try? manager.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for file in files where !referenced.contains(file.standardizedFileURL.path) {
            if (try? manager.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    /// 목록을 읽지 못했을 때 보관 폴더에 남은 파일을 항목으로 되살린다. 최근 것이 앞에 온다.
    /// 목록에 다시 올려 두지 않으면 다음에 켤 때 목록에 없는 파일로 정리된다
    public func adoptOrphans() -> [ShelfItem] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let files = (try? manager.contentsOfDirectory(
            at: imagesDirectory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        return files.compactMap { file -> ShelfItem? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            // 나열 결과는 /private 가 붙은 경로로 올 수 있다. 보관 폴더 기준 경로로 맞춘다
            let path = imagesDirectory.appendingPathComponent(file.lastPathComponent).path
            return ShelfItem(kind: .image, path: path, addedAt: values.contentModificationDate ?? Date())
        }
        .sorted { $0.addedAt > $1.addedAt }
    }

    /// 보관 폴더 안에서 겹치지 않는 경로. 이름이 겹치면 뒤에 짧은 꼬리표를 붙인다
    public func uniqueURL(named name: String) -> URL {
        // 다른 앱이 정해 준 이름이라 폴더 구분자가 들어 있으면 보관 폴더 밖을 가리킬 수 있다
        let safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let clean = safe.isEmpty || safe == "." || safe == ".." ? "파일" : safe
        var url = imagesDirectory.appendingPathComponent(clean)
        if manager.fileExists(atPath: url.path) {
            let base = (clean as NSString).deletingPathExtension
            let ext = (clean as NSString).pathExtension
            let tag = UUID().uuidString.prefix(4)
            url = imagesDirectory.appendingPathComponent(ext.isEmpty ? "\(base) \(tag)" : "\(base) \(tag).\(ext)")
        }
        return url
    }

    /// 보관 폴더가 차지하는 바이트
    public func usage() -> Int64 {
        guard let walker = manager.enumerator(at: imagesDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
