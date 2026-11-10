import AppKit
import Security
import HopboxCore

/// 새 버전 알림과 설치.
/// 켤 때와 하루에 한 번 GitHub 최신 릴리스를 본다. 저절로 확인했을 때는 창을 띄우지 않고 메뉴 막대 아이콘과
/// 메뉴 항목으로만 알린다 (쓰던 앱에서 포커스를 가져오지 않게). 메뉴에서 "설치" 를 누르면 dmg 를 받아
/// 지금 앱 자리에 바꿔 끼우고 다시 켠다. 받은 앱은 내 Developer ID 서명과 Apple 공증이 확인될 때만 설치한다.
@MainActor
final class Updater {
    struct Release {
        let version: String
        let page: URL
        /// 이 맥에 맞는 dmg. 릴리스에 아직 안 올라왔으면 nil
        let dmg: URL?
    }

    enum State: Equatable {
        case idle
        case available(String)
        case installing
    }

    nonisolated static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    nonisolated private static let latestURL = URL(string: "https://api.github.com/repos/ESeungJun/hopbox/releases/latest")!
    nonisolated private static let downloadPrefix = "https://github.com/ESeungJun/hopbox/releases/download/"
    /// 같은 개발자 팀으로 서명된 dmg, 그 안의 같은 번들 ID 앱만 받는다
    nonisolated private static let teamRequirement = #"anchor apple generic and certificate leaf[subject.OU] = "CCX6HUC3AC""#
    nonisolated private static let appRequirement = #"anchor apple generic and identifier "com.haul.hopbox" and certificate leaf[subject.OU] = "CCX6HUC3AC""#
    nonisolated private static let checkInterval: TimeInterval = 24 * 60 * 60
    /// 같은 버전은 상자 알림으로 한 번만 알린다. 메뉴 표시는 설치할 때까지 남는다
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
    /// 저절로 확인하다 새 버전을 찾았을 때. 다음에 상자를 부르면 알림 자리에 한 번 보여 준다
    var onFound: ((String) -> Void)?

    var availableVersion: String? {
        if case .available(let version) = state { return version }
        return nil
    }

    func start() {
        // Info.plist 없이 실행한 개발 빌드(swift run)는 버전을 몰라 확인하지 않는다
        guard Self.currentVersion != "0" else { return }
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
            guard let latest = try await Self.fetchLatest(), Versioning.isNewer(latest.version, than: Self.currentVersion) else {
                release = nil
                state = .idle
                if manual { show("최신 버전을 쓰고 있어요", "택배상자 \(Self.currentVersion)") }
                return
            }
            guard latest.dmg != nil else {
                // 릴리스는 나왔는데 이 맥용 파일이 아직 안 올라왔다. 다음 확인 때 다시 본다
                release = nil
                state = .idle
                if manual { show("택배상자 \(latest.version) 을 준비하는 중이에요", "잠시 뒤에 다시 확인해 주세요.") }
                return
            }
            release = latest
            state = .available(latest.version)
            let defaults = UserDefaults.standard
            if manual {
                ask(latest)
            } else if defaults.string(forKey: Self.notifiedKey) != latest.version {
                defaults.set(latest.version, forKey: Self.notifiedKey)
                onFound?(latest.version)
            }
        } catch {
            if manual { show("업데이트를 확인하지 못했어요", error.localizedDescription) }
        }
    }

    private func ask(_ release: Release) {
        let answer = show(
            "택배상자 \(release.version) 이 나왔어요",
            "지금 쓰는 버전은 \(Self.currentVersion) 이에요. 업데이트하면 받아서 설치한 뒤 다시 켜요. 담아 둔 것은 그대로 남아요.",
            buttons: ["업데이트", "나중에", "바뀐 점 보기"]
        )
        switch answer {
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
                try await Task.detached { try await Self.downloadAndReplace(release) }.value
                Self.relaunch()
            } catch {
                state = .available(release.version)
                let answer = show(
                    "업데이트하지 못했어요",
                    "\(error.localizedDescription)\n릴리스 페이지에서 직접 받을 수 있어요.",
                    buttons: ["릴리스 페이지 열기", "닫기"]
                )
                if answer == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
            }
        }
    }

    /// 알림 창을 앞으로 띄우고 누른 버튼을 돌려준다. 사용자가 메뉴를 눌러 시작한 흐름에서만 부른다
    @discardableResult
    private func show(_ message: String, _ detail: String, buttons: [String] = []) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal()
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
        let version = payload.tagName.hasPrefix("v") ? String(payload.tagName.dropFirst()) : payload.tagName
        // 이 저장소의 릴리스 파일만 받는다
        let dmg = payload.assets.first { $0.name == dmgName && $0.browserDownloadUrl.absoluteString.hasPrefix(downloadPrefix) }
        return Release(version: version, page: payload.htmlUrl, dmg: dmg?.browserDownloadUrl)
    }

    // MARK: - 설치

    /// dmg 를 받아 서명·공증을 확인하고 연다. 새 앱을 지금 앱 옆에 복사해 다시 서명·공증·버전을 확인한 뒤 지금 앱과 바꿔 끼운다
    nonisolated private static func downloadAndReplace(_ release: Release) async throws {
        guard let source = release.dmg else { throw UpdateError("이 맥에 맞는 설치 파일이 릴리스에 없어요") }
        let current = Bundle.main.bundleURL
        guard current.pathExtension == "app" else { throw UpdateError("앱 번들로 실행 중이 아니에요") }
        let folder = current.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw UpdateError(UpdateRules.unwritableMessage(folder: folder.path))
        }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("hopbox-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // 메모리에 올리지 않고 파일로 받는다. 응답이 60초 동안 없으면 그만둔다
        let dmg = work.appendingPathComponent(dmgName)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 15 * 60
        let (downloaded, response) = try await URLSession(configuration: configuration).download(from: source)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("설치 파일을 받지 못했어요") }
        try FileManager.default.moveItem(at: downloaded, to: dmg)
        // 디스크 이미지를 열기 전에 확인한다. 여는 과정도 공격받을 수 있는 곳이다
        try verify(dmg, requirement: teamRequirement, assessmentType: "open")

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

        try verify(staged, requirement: appRequirement, assessmentType: "execute")
        let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleShortVersionString"] as? String == release.version else { throw UpdateError("받은 앱의 버전이 릴리스와 달라요") }

        do {
            _ = try FileManager.default.replaceItemAt(current, withItemAt: staged)
            replaced = true
        } catch {
            // 바꿔 끼우다 실패하면 원래 앱이 임시 자리에 남아 있을 수 있다. 제자리로 되돌린다
            if !FileManager.default.fileExists(atPath: current.path),
               let original = (error as NSError).userInfo["NSFileOriginalItemLocationKey"] as? URL {
                try? FileManager.default.moveItem(at: original, to: current)
            }
            throw error
        }
    }

    /// 내 Developer ID 서명(requirement)과 Apple 공증을 확인한다. assessmentType 은 dmg 면 open, 앱이면 execute
    nonisolated private static func verify(_ item: URL, requirement text: String, assessmentType: String) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let flags = assessmentType == "execute" ? kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode : 0
        guard SecStaticCodeCreateWithPath(item as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: flags), requirement) == errSecSuccess
        else { throw UpdateError("받은 파일의 서명이 올바르지 않아요") }

        var arguments = ["--assess", "--type", assessmentType, "-vv"]
        if assessmentType == "open" { arguments += ["--context", "context:primary-signature"] }
        let assessment = try run("/usr/sbin/spctl", arguments + [item.path])
        guard assessment.contains("Notarized Developer ID") else { throw UpdateError("받은 파일이 Apple 공증을 받지 않았어요") }
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

    /// 지금 앱이 완전히 끝나기를 기다렸다가 바꿔 끼운 앱을 다시 켠다
    private static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
            Bundle.main.bundleURL.path, String(ProcessInfo.processInfo.processIdentifier),
        ]
        try? process.run()
        NSApp.terminate(nil)
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
