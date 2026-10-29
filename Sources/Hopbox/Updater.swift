import AppKit
import Security

/// 새 버전 알림과 설치.
/// 켤 때와 하루에 한 번 GitHub 최신 릴리스를 보고, 새 버전이 있으면 알린다. "업데이트" 를 누르면 dmg 를 받아
/// 지금 앱 자리에 바꿔 끼우고 다시 켠다. 받은 앱은 내 Developer ID 서명과 Apple 공증이 확인될 때만 설치한다.
@MainActor
final class Updater {
    struct Release {
        let version: String
        let page: URL
        let dmg: URL
    }

    enum State: Equatable {
        case idle
        case available(String)
        case installing
    }

    nonisolated static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    nonisolated private static let latestURL = URL(string: "https://api.github.com/repos/ESeungJun/hopbox/releases/latest")!
    /// 이 앱과 같은 번들 ID, 같은 개발자 팀으로 서명된 앱만 받는다
    nonisolated private static let requirement = #"anchor apple generic and identifier "com.haul.hopbox" and certificate leaf[subject.OU] = "CCX6HUC3AC""#
    nonisolated private static let checkInterval: TimeInterval = 24 * 60 * 60
    /// 같은 버전은 저절로 한 번만 알린다. 그 뒤로는 메뉴에서 설치할 수 있다
    nonisolated private static let notifiedKey = "notifiedUpdateVersion"
    #if arch(arm64)
    nonisolated private static let dmgName = "Hopbox-macOS-apple-silicon.dmg"
    #else
    nonisolated private static let dmgName = "Hopbox-macOS-intel.dmg"
    #endif

    private(set) var state = State.idle { didSet { onChange?() } }
    private var release: Release?
    private var timer: Timer?
    var onChange: (() -> Void)?
    /// 저절로 알림을 띄워도 되는지. 상자를 쓰는 중에는 띄우지 않는다
    var canInterrupt: () -> Bool = { true }

    func start() {
        Task {
            try? await Task.sleep(for: .seconds(10))
            await check(manual: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(manual: false) }
        }
    }

    /// 메뉴 항목을 누르면: 새 버전을 알고 있으면 설치를 묻고, 아니면 확인한다
    func menuAction() {
        if let release, case .available = state {
            ask(release)
        } else {
            Task { await check(manual: true) }
        }
    }

    func check(manual: Bool) async {
        guard state != .installing else { return }
        do {
            guard let latest = try await Self.fetchLatest(), Self.isNewer(latest.version, than: Self.currentVersion) else {
                release = nil
                state = .idle
                if manual { inform("최신 버전을 쓰고 있어요", "택배상자 \(Self.currentVersion)") }
                return
            }
            release = latest
            state = .available(latest.version)
            let defaults = UserDefaults.standard
            if manual || (defaults.string(forKey: Self.notifiedKey) != latest.version && canInterrupt()) {
                defaults.set(latest.version, forKey: Self.notifiedKey)
                ask(latest)
            }
        } catch {
            if manual { inform("업데이트를 확인하지 못했어요", error.localizedDescription) }
        }
    }

    private func ask(_ release: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "택배상자 \(release.version) 이 나왔어요"
        alert.informativeText = "지금 쓰는 버전은 \(Self.currentVersion) 이에요. 업데이트하면 받아서 설치한 뒤 다시 켜요. 담아 둔 것은 그대로 남아요."
        alert.addButton(withTitle: "업데이트")
        alert.addButton(withTitle: "나중에")
        alert.addButton(withTitle: "바뀐 점 보기")
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(release)
        case .alertThirdButtonReturn: NSWorkspace.shared.open(release.page)
        default: break
        }
    }

    private func install(_ release: Release) {
        guard state != .installing else { return }
        state = .installing
        Task {
            do {
                try await Task.detached { try Self.downloadAndReplace(release) }.value
                Self.relaunch()
            } catch {
                state = .available(release.version)
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "업데이트하지 못했어요"
                alert.informativeText = "\(error.localizedDescription)\n릴리스 페이지에서 직접 받을 수 있어요."
                alert.addButton(withTitle: "릴리스 페이지 열기")
                alert.addButton(withTitle: "닫기")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
            }
        }
    }

    private func inform(_ message: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    // MARK: - 확인

    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
        }

        let tagName: String
        let htmlUrl: URL
        let assets: [Asset]
    }

    nonisolated private static func fetchLatest() async throws -> Release? {
        var request = URLRequest(url: latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("GitHub 에서 릴리스 정보를 받지 못했어요") }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(Payload.self, from: data)
        guard let dmg = payload.assets.first(where: { $0.name == dmgName }) else { return nil }
        let version = payload.tagName.hasPrefix("v") ? String(payload.tagName.dropFirst()) : payload.tagName
        return Release(version: version, page: payload.htmlUrl, dmg: dmg.browserDownloadUrl)
    }

    /// "1.0.10" 이 "1.0.9" 보다 새 버전이다. 숫자 단위로 비교한다
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let parts = { (text: String) in text.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - 설치

    /// dmg 를 받아 열고, 새 앱을 지금 앱 옆에 복사해 서명·공증·버전을 확인한 뒤 지금 앱과 바꿔 끼운다
    nonisolated private static func downloadAndReplace(_ release: Release) throws {
        let current = Bundle.main.bundleURL
        guard current.pathExtension == "app" else { throw UpdateError("앱 번들로 실행 중이 아니에요") }
        let folder = current.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw UpdateError("\(folder.path) 폴더에 쓸 수 없어요")
        }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("hopbox-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let dmg = work.appendingPathComponent(dmgName)
        let data = try Data(contentsOf: release.dmg)
        try data.write(to: dmg)

        let mount = work.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let apps = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard apps.count == 1, let newApp = apps.first else { throw UpdateError("설치 파일 안에서 앱을 찾지 못했어요") }

        // 같은 폴더에 먼저 복사해야 마지막 바꿔 끼우기가 한 번에 된다
        let staged = folder.appendingPathComponent(".hopbox-update-\(UUID().uuidString).app")
        try run("/usr/bin/ditto", [newApp.path, staged.path])
        var replaced = false
        defer { if !replaced { try? FileManager.default.removeItem(at: staged) } }

        try verify(staged, version: release.version)
        _ = try FileManager.default.replaceItemAt(current, withItemAt: staged)
        replaced = true
    }

    /// 내 Developer ID 서명, Apple 공증, 릴리스와 같은 버전인지 확인한다
    nonisolated private static func verify(_ app: URL, version: String) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), requirement) == errSecSuccess
        else { throw UpdateError("받은 앱의 서명이 올바르지 않아요") }

        let assessment = try run("/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", app.path])
        guard assessment.contains("Notarized Developer ID") else { throw UpdateError("받은 앱이 Apple 공증을 받지 않았어요") }

        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleShortVersionString"] as? String == version else { throw UpdateError("받은 앱의 버전이 릴리스와 달라요") }
    }

    /// 프로그램을 실행하고 출력(표준 출력 + 오류)을 돌려준다. 실패하면 던진다
    @discardableResult
    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) 실패: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }

    /// 잠깐 뒤에 바꿔 끼운 앱을 다시 켜고 지금 앱은 끝낸다
    private static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
