import AppKit
import Carbon
import SwiftUI

/// 상자를 부르는 단축키. 키 코드와 Carbon 수정키 조합을 저장한다
struct Shortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int

    /// ⇧⌘F
    static let standard = Shortcut(keyCode: kVK_ANSI_F, modifiers: cmdKey | shiftKey)
    private static let defaultsKey = "shortcut"

    static var saved: Shortcut {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data)
            else { return .standard }
            return shortcut
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey)
        }
    }

    /// 키 입력에서 단축키를 만든다. ⌘·⌥·⌃ 중 하나는 있어야 한다 (⇧ 만으로는 글자 입력과 겹친다)
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.control) { modifiers |= controlKey }
        guard modifiers != 0 else { return nil }
        if flags.contains(.shift) { modifiers |= shiftKey }
        self.init(keyCode: Int(event.keyCode), modifiers: modifiers)
    }

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// "⇧⌘F" 처럼 보이는 이름
    var displayName: String {
        var text = ""
        if modifiers & controlKey != 0 { text += "⌃" }
        if modifiers & optionKey != 0 { text += "⌥" }
        if modifiers & shiftKey != 0 { text += "⇧" }
        if modifiers & cmdKey != 0 { text += "⌘" }
        return text + keyName
    }

    /// 메뉴 항목 옆에 단축키를 보여 주기 위한 값
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags) {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & controlKey != 0 { flags.insert(.control) }
        if modifiers & optionKey != 0 { flags.insert(.option) }
        if modifiers & shiftKey != 0 { flags.insert(.shift) }
        if modifiers & cmdKey != 0 { flags.insert(.command) }
        return (keyName.count == 1 ? keyName.lowercased() : "", flags)
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// 키 이름. 한글 입력 상태여도 영문 자판 기준으로 보여 준다
    private var keyName: String {
        if let name = Self.specialKeys[keyCode] { return name }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "?" }
        let layout = unsafeBitCast(layoutData, to: CFData.self)
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = CFDataGetBytePtr(layout).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { pointer in
            UCKeyTranslate(
                pointer, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars
            )
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

// MARK: - 단축키 바꾸기 창

/// 새 단축키를 눌러 지정하는 작은 창
final class ShortcutRecorderWindow: NSWindow {
    private let model: RecorderModel
    private var monitor: Any?

    /// onRecord 는 등록에 성공하면 true 를 돌려준다
    init(current: Shortcut, onRecord: @escaping (Shortcut) -> Bool, onEnd: @escaping () -> Void) {
        model = RecorderModel(current: current)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "단축키 바꾸기"
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: RecorderView(model: model) { [weak self] in
            self?.apply(.standard, onRecord: onRecord)
        })
        center()

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isKeyWindow else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.close()
                return nil
            }
            guard let shortcut = Shortcut(event: event) else {
                self.model.message = "⌘ · ⌥ · ⌃ 중 하나와 함께 눌러 주세요"
                return nil
            }
            self.apply(shortcut, onRecord: onRecord)
            return nil
        }
        self.onEnd = onEnd
    }

    private var onEnd: () -> Void = {}

    private func apply(_ shortcut: Shortcut, onRecord: (Shortcut) -> Bool) {
        if onRecord(shortcut) {
            model.current = shortcut
            model.message = "\(shortcut.displayName) 로 바꿨어요"
        } else {
            model.message = "\(shortcut.displayName) 는 다른 앱이 쓰고 있어요"
        }
    }

    override func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        super.close()
        onEnd()
    }
}

private final class RecorderModel: ObservableObject {
    @Published var current: Shortcut
    @Published var message = "새 단축키를 누르세요 · esc 로 닫기"

    init(current: Shortcut) {
        self.current = current
    }
}

private struct RecorderView: View {
    @ObservedObject var model: RecorderModel
    var onReset: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("상자를 부르는 단축키")
                .font(.headline)
            Text(model.current.displayName)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))
            Text(model.message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("기본값(\(Shortcut.standard.displayName))으로", action: onReset)
                .disabled(model.current == .standard)
        }
        .padding(20)
        .frame(width: 320, height: 190)
    }
}
