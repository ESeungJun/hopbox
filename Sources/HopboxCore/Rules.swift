import Foundation

/// 화면 없이 판정할 수 있는 규칙들.

public enum Versioning {
    /// "1.0.10" 이 "1.0.9" 보다 새 버전이다. 숫자 단위로 비교한다
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let parts = { (text: String) in text.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}

public enum TempPath {
    /// 시스템 임시 폴더·캐시에 있는 파일인지. 곧 지워지므로 상자에 복사해 둔다
    public static func isTemporary(_ url: URL, temporaryDirectory: String = NSTemporaryDirectory()) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        let temporary = URL(fileURLWithPath: temporaryDirectory).resolvingSymlinksInPath().path
        return path.hasPrefix(temporary)
            || path.hasPrefix("/private/var/folders/")
            || path.hasPrefix("/private/tmp/")
            || path.contains("/Library/Caches/")
    }
}

public enum Retention {
    /// 메뉴에 내놓는 보관 기한(일). 0 은 계속 둔다
    public static let choices = [1, 7, 0]

    /// 기한이 지난 자동 항목. 직접 담은 것과 고정한 것은 건드리지 않는다
    public static func expired(_ items: [ShelfItem], now: Date, days: Int) -> [ShelfItem] {
        guard days > 0 else { return [] }
        let limit = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        return items.filter { $0.isAuto && !$0.isPinned && $0.addedAt < limit }
    }

    public static func title(days: Int) -> String {
        days > 0 ? "\(days)일" : "계속"
    }
}

public enum Ordering {
    /// 고정한 것을 맨 위로. 그 안에서는 원래 순서를 지킨다
    public static func pinnedFirst(_ items: [ShelfItem]) -> [ShelfItem] {
        items.filter(\.isPinned) + items.filter { !$0.isPinned }
    }
}

/// 파일 약속을 받는 폴더가 멈췄는지 본다. 크기가 timeout 동안 그대로면 멈춘 것이다.
/// 큰 파일은 오래 걸려도 크기가 계속 늘므로 끊지 않는다
public struct StallDetector {
    public let timeout: TimeInterval
    private var lastSize: Int64
    private var lastChange: Date

    public init(timeout: TimeInterval = 10, now: Date = Date()) {
        self.timeout = timeout
        lastSize = -1
        lastChange = now
    }

    /// 지금 크기를 알려 주면 멈췄는지 돌려준다
    public mutating func isStalled(size: Int64, now: Date = Date()) -> Bool {
        if size != lastSize {
            lastSize = size
            lastChange = now
            return false
        }
        return now.timeIntervalSince(lastChange) >= timeout
    }
}

public enum UpdateRules {
    /// dmg 에서 바로 열면 macOS 가 읽기 전용 임시 경로에서 실행한다
    public static func isTranslocated(_ path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }

    public static func unwritableMessage(folder: String) -> String {
        isTranslocated(folder)
            ? "택배상자를 응용 프로그램 폴더로 옮긴 뒤 다시 열어 주세요"
            : "\(folder) 폴더에 쓸 수 없어요"
    }

    /// 릴리스 태그("v1.0.3")와 앱 버전이 같은지. 다르면 받은 앱을 설치하지 않는다
    public static func tagMatches(_ tag: String, version: String) -> Bool {
        (tag.hasPrefix("v") ? String(tag.dropFirst()) : tag) == version
    }
}

/// 상자가 떠 있을 때 키보드로 꺼내기. 부른 뒤 마우스를 잡지 않아도 끝나게 한다
public enum KeyPick {
    public enum Key: Equatable {
        case digit(Int)
        case up, down
        case enter
        case delete
    }

    public enum Action: Equatable {
        /// 그 줄을 복사하고 상자를 닫는다
        case pick(Int)
        /// 그 줄을 고른다
        case select(Int)
        /// 고른 줄을 상자에서 뺀다
        case remove(Int)
        /// 아무 일도 없지만 키는 먹는다 (없는 줄의 숫자)
        case swallow
        /// 상자가 다루지 않는다
        case pass
    }

    /// rows 는 지금 화면에 보이는 줄 수(부채꼴이면 부채꼴 줄 수, 목록이면 전부).
    /// 부채꼴이 위로 펼쳐져 있으면 ↑ 가 다음 줄이고, 아래로 펼쳐졌거나 목록이면 ↓ 가 다음 줄이다
    public static func action(
        for key: Key, itemCount: Int, rows: Int, selected: Int?, nextIsUp: Bool
    ) -> Action {
        switch key {
        case .digit(let digit):
            return index(digit: digit, count: itemCount).map(Action.pick) ?? .swallow
        case .up, .down:
            let step = (key == .up) == nextIsUp ? 1 : -1
            return move(selected, by: step, count: min(rows, itemCount)).map(Action.select) ?? .swallow
        case .enter:
            guard let selected, selected < itemCount else { return .pass }
            return .pick(selected)
        case .delete:
            guard let selected, selected < itemCount else { return .pass }
            return .remove(selected)
        }
    }

    /// 숫자 키로 고르는 줄. 1~9 는 첫째~아홉째, 0 은 열째. 그 줄이 없으면 nil
    public static func index(digit: Int, count: Int) -> Int? {
        guard (0...9).contains(digit) else { return nil }
        let index = digit == 0 ? 9 : digit - 1
        return index < count ? index : nil
    }

    /// 줄 번호에 붙이는 글자. 열한째부터는 번호가 없다
    public static func label(index: Int) -> String? {
        guard (0..<10).contains(index) else { return nil }
        return index == 9 ? "0" : "\(index + 1)"
    }

    /// ↑↓ 로 옮긴 뒤의 줄. 처음 누르면 끝 줄을 잡고, 끝에서는 멈춘다
    public static func move(_ current: Int?, by step: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return step > 0 ? 0 : count - 1 }
        return min(max(current + step, 0), count - 1)
    }
}

public enum Wording {
    /// 담았을 때 알림. 하나면 이름을 보여 준다 ("+N" 과 겹치지 않게)
    public static func added(_ items: [ShelfItem]) -> String {
        guard items.count == 1, let item = items.first else { return "\(items.count)개 담았어요" }
        let title = item.kind == .text ? "글" : shortened(item.title, to: 18)
        return title.isEmpty ? "1개 담았어요" : "\(title) 담았어요"
    }

    /// 긴 이름은 가운데를 줄인다
    public static func shortened(_ text: String, to limit: Int) -> String {
        guard text.count > limit, limit > 3 else { return text }
        let head = (limit - 1) / 2, tail = limit - 1 - head
        return text.prefix(head) + "…" + text.suffix(tail)
    }

    public static func size(_ bytes: Int64) -> String {
        if bytes < 1024 * 1024 { return "\(max(bytes, 0) / 1024)KB" }
        let megabytes = Double(bytes) / 1024 / 1024
        return megabytes < 1024 ? String(format: "%.0fMB", megabytes) : String(format: "%.1fGB", megabytes / 1024)
    }
}
