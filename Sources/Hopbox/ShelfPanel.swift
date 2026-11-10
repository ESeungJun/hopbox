import AppKit
import Carbon
import Combine
import SwiftUI
import HopboxCore

/// 단축키를 누른 그 화면(전체화면 앱의 Space 포함) 위에 뜨는 상자.
/// 다른 앱을 비활성화하지 않는 패널이라, 띄워도 전체화면 앱에서 빠져나가지 않는다.
final class ShelfPanel: NSPanel {
    /// 화면(Space)을 옮기면 상자가 따라오는지
    static let followsSpacesKey = "followSpaces"

    private let store: ShelfStore
    private let state = BoxState()
    /// 상자 아이콘 중심의 화면 좌표. 창이 커지고 줄어도 아이콘은 이 자리에 있다
    private var anchor = NSPoint.zero
    private var isApplyingLayout = false
    private var collapseWorkItem: DispatchWorkItem?
    private var departWorkItem: DispatchWorkItem?
    private var itemsObserver: AnyCancellable?

    init(store: ShelfStore) {
        self.store = store
        super.init(
            contentRect: NSRect(origin: .zero, size: BoxLayout().size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        // moveToActiveSpace: 띄울 때 지금 보고 있는 Space 로 옮겨 온다
        // fullScreenAuxiliary: 전체화면 앱 Space 에도 올라갈 수 있다
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        let actions = BoxActions(
            toggleFan: { [weak self] in self?.toggleFan() },
            showList: { [weak self] in self?.setMode(.list) },
            collapse: { [weak self] in self?.setMode(.icon) }
        )
        contentView = ShelfHostingView(store: store, rootView: BoxView(store: store, state: state, actions: actions))

        // 펼친 채로 담거나 빼면 부채꼴 줄 수를 다시 맞춘다
        itemsObserver = store.$items.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] items in
            guard let self else { return }
            if let selected = self.state.selectedIndex, selected >= items.count {
                self.state.selectedIndex = items.isEmpty ? nil : items.count - 1
            }
            guard self.state.mode != .icon else { return }
            self.applyLayout(self.state.mode)
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(didMove), name: NSWindow.didMoveNotification, object: self
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceDidChange), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 뛰어 나가는 중. 창은 아직 보이지만 닫힌 것으로 본다
    private var isDeparting: Bool { departWorkItem != nil }
    /// 사용자가 보기에 상자가 떠 있는지
    var isShown: Bool { isVisible && !isDeparting }

    // MARK: - 띄우기

    func toggle() {
        if isShown && isOnActiveSpace {
            hide()
        } else {
            show()
        }
    }

    /// point 를 주면 그 자리에, 아니면 마우스 옆에 띄운다
    func show(at point: NSPoint? = nil) {
        if isDeparting { finishHide() }
        // 다른 Space 에 떠 있던 상자면 한 번 내렸다가 지금 Space 로 건너온다
        let crossing = isVisible && !isOnActiveSpace
        if crossing { orderOut(nil) }
        guard !isVisible else {
            makeKeyAndOrderFront(nil)
            return
        }
        collapseWorkItem?.cancel()
        anchor = point ?? NSEvent.mouseLocation
        state.mode = .icon
        state.selectedIndex = nil
        applyLayout(.icon)
        store.followMovedOriginals()
        deliver(crossing ? .hop : .drop, opensFan: true, takesKey: true)
    }

    /// 택배가 도착하듯 제자리 위에서 내려앉고, 담긴 게 있으면 바로 열린다.
    /// 창은 움직이지 않고 상자 그림만 움직인다. 창째 옮기면 내용이 따라오지 못해 튀어 보인다
    private func deliver(_ arrival: BoxState.Arrival, opensFan: Bool, takesKey: Bool) {
        alphaValue = 0
        if takesKey {
            makeKeyAndOrderFront(nil)
        } else {
            // 따라올 때는 쓰던 앱의 키 입력을 가져오지 않는다
            orderFrontRegardless()
        }
        state.arrival = arrival
        state.landing += 1
        // 상자가 내려앉기 전 자세를 잡은 다음 창을 보인다
        DispatchQueue.main.async { [weak self] in self?.alphaValue = 1 }
        // 상자가 안 보이는 동안 생긴 일(새 버전, 목록 읽기 실패 등)을 한 번 알린다
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isShown else { return }
            self.store.showNextNotice()
        }
        guard opensFan, !store.items.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.isShown, self.state.mode == .icon else { return }
            self.setMode(.fan)
        }
    }

    #if DEBUG
    /// 개발용: 키 창으로 만들지 않고 지정한 자리에 띄운다 (AppDelegate.runDemo)
    func demoShow(at point: NSPoint, arrival: BoxState.Arrival) {
        if isDeparting { finishHide() }
        orderOut(nil)
        collapseWorkItem?.cancel()
        anchor = point
        state.mode = .icon
        state.selectedIndex = nil
        applyLayout(.icon)
        deliver(arrival, opensFan: arrival == .drop, takesKey: false)
    }

    func demoShowList() {
        setMode(.list)
    }
    #endif

    /// 깡충 뛰어 나간 다음 창을 내린다. animated 가 false 면 바로 내린다
    func hide(animated: Bool = true) {
        collapseWorkItem?.cancel()
        guard isShown else { return }
        guard animated else { return finishHide() }
        let wasOpen = state.mode != .icon
        if wasOpen { state.mode = .icon }
        state.departing += 1
        let work = DispatchWorkItem { [weak self] in self?.finishHide() }
        departWorkItem = work
        let duration = Motion.isReduced ? 0.12 : (wasOpen ? 0.26 : 0.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func finishHide() {
        departWorkItem?.cancel()
        departWorkItem = nil
        orderOut(nil)
    }

    /// 화면(Space)을 옮겼을 때. 설정이 켜져 있고 상자가 떠 있었으면 접힌 채로 새 화면의 같은 자리에 뛰어 들어온다
    @objc private func spaceDidChange() {
        guard UserDefaults.standard.bool(forKey: Self.followsSpacesKey), isShown else { return }
        // 화면 전환 연출이 끝나고 창이 어느 Space 에 있는지 정해진 다음 본다
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.isShown, !self.isOnActiveSpace else { return }
            self.collapseWorkItem?.cancel()
            self.orderOut(nil)
            self.state.mode = .icon
            self.state.selectedIndex = nil
            self.applyLayout(.icon)
            self.deliver(.hop, opensFan: false, takesKey: false)
        }
    }

    // MARK: - 펼치기·접기

    private func toggleFan() {
        setMode(state.mode == .icon ? .fan : .icon)
    }

    private func setMode(_ mode: BoxLayout.Mode) {
        collapseWorkItem?.cancel()
        if mode == .icon {
            // 내용이 사라지는 애니메이션이 끝난 뒤 창을 줄인다
            state.mode = .icon
            state.selectedIndex = nil
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.state.mode == .icon else { return }
                self.applyLayout(.icon)
            }
            collapseWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        } else {
            // 창 크기를 먼저 바꾸고, 다음 차례에 내용만 애니메이션한다.
            // 한 번에 바꾸면 아이콘 자리까지 애니메이션돼 아이콘이 미끄러진다
            applyLayout(mode)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.state.layout.mode == mode else { return }
                self.state.mode = mode
            }
        }
    }

    private func applyLayout(_ mode: BoxLayout.Mode) {
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        // 아이콘이 화면 밖으로 반쯤 나가지 않게 안쪽으로 당긴다
        let inset = BoxLayout.iconArea / 2 + 4
        anchor.x = min(max(anchor.x, visible.minX + inset), visible.maxX - inset)
        anchor.y = min(max(anchor.y, visible.minY + inset), visible.maxY - inset)

        let layout = BoxLayout.make(mode: mode, anchor: anchor, in: visible, itemCount: store.items.count)
        let offset = layout.iconOffsetFromOrigin
        let frame = NSRect(
            origin: NSPoint(x: anchor.x - offset.x, y: anchor.y - offset.y),
            size: layout.size
        )
        isApplyingLayout = true
        state.layout = layout
        setFrame(frame, display: true)
        isApplyingLayout = false
    }

    /// 사용자가 아이콘을 끌어 상자를 옮기면 그 자리를 새 기준점으로 삼는다
    @objc private func didMove() {
        guard !isApplyingLayout else { return }
        let offset = state.layout.iconOffsetFromOrigin
        anchor = NSPoint(x: frame.minX + offset.x, y: frame.minY + offset.y)
    }

    /// 다른 앱을 누르면 펼친 것을 접고 아이콘만 남긴다 (파일을 계속 끌어다 넣을 수 있게)
    override func resignKey() {
        super.resignKey()
        if state.mode != .icon { setMode(.icon) }
    }

    // MARK: - 키보드

    override func cancelOperation(_ sender: Any?) {
        if state.mode != .icon {
            setMode(.icon)
        } else {
            hide()
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 한글 입력 상태에서도 동작하도록 문자 대신 키 코드로 본다
        if flags == .command {
            switch Int(event.keyCode) {
            case kVK_ANSI_V:
                store.add(from: .general)
                return true
            case kVK_ANSI_W:
                hide()
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleKey(event) { return }
        super.sendEvent(event)
    }

    /// 숫자 키 → 숫자 줄 번호. 한글 입력 상태에서도 되도록 키 코드로 본다
    private static let digitKeys: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9, kVK_ANSI_0: 0,
        kVK_ANSI_Keypad1: 1, kVK_ANSI_Keypad2: 2, kVK_ANSI_Keypad3: 3, kVK_ANSI_Keypad4: 4, kVK_ANSI_Keypad5: 5,
        kVK_ANSI_Keypad6: 6, kVK_ANSI_Keypad7: 7, kVK_ANSI_Keypad8: 8, kVK_ANSI_Keypad9: 9, kVK_ANSI_Keypad0: 0,
    ]

    private static func key(for code: Int) -> KeyPick.Key? {
        if let digit = digitKeys[code] { return .digit(digit) }
        switch code {
        case kVK_UpArrow: return .up
        case kVK_DownArrow: return .down
        case kVK_Return, kVK_ANSI_KeypadEnter: return .enter
        case kVK_Delete, kVK_ForwardDelete: return .delete
        default: return nil
        }
    }

    /// 부른 뒤 마우스 없이 꺼내기: 숫자는 그 줄을 복사하고 닫는다. ↑↓ 로 고르고 ↩ 복사, ⌫ 빼기.
    /// 무엇을 할지는 KeyPick(HopboxCore)이 정한다
    private func handleKey(_ event: NSEvent) -> Bool {
        guard isShown, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              let key = Self.key(for: Int(event.keyCode))
        else { return false }
        return press(key)
    }

    @discardableResult
    func press(_ key: KeyPick.Key) -> Bool {
        // 접혀 있을 때 화살표를 누르면 먼저 펼친다 (줄 수가 정해진다)
        if key == .up || key == .down, state.mode == .icon, !store.items.isEmpty { setMode(.fan) }
        let isList = state.layout.mode == .list
        let action = KeyPick.action(
            for: key, itemCount: store.items.count,
            rows: isList ? store.items.count : state.layout.fanRows,
            selected: state.selectedIndex,
            nextIsUp: !isList && state.layout.opensUp
        )
        switch action {
        case .pick(let index): pick(index)
        case .select(let index): state.selectedIndex = index
        case .remove(let index): store.remove(store.items[index])
        case .swallow: break
        case .pass: return false
        }
        return true
    }

    /// 그 줄을 복사하고, 알림이 보일 만큼만 있다가 닫는다
    private func pick(_ index: Int) {
        guard store.items.indices.contains(index) else { return }
        let item = store.items[index]
        state.selectedIndex = index
        store.copyToPasteboard(item)
        // 원본이 없어 복사하지 못했으면 알림이 보이게 열어 둔다
        guard item.exists else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.hide() }
    }
}

/// 상자 창 전체를 드롭 영역으로 쓴다. 드롭과 ⌘V 는 같은 담기 경로를 탄다.
final class ShelfHostingView: NSHostingView<BoxView> {
    private let store: ShelfStore

    init(store: ShelfStore, rootView: BoxView) {
        self.store = store
        super.init(rootView: rootView)
        // 창 크기는 ShelfPanel 이 정한다. 내용 크기에 맞춰 창을 바꾸지 않게 한다
        sizingOptions = []
        registerForDraggedTypes(ShelfStore.droppableTypes)
    }

    @MainActor required init(rootView: BoxView) {
        fatalError("init(rootView:) is not supported")
    }

    @MainActor required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Log.types("끌어오기", sender.draggingPasteboard)
        // 상자에서 끌어낸 것을 다시 상자에 떨어뜨리는 경우는 받지 않는다
        guard sender.draggingSource == nil, store.canAdd(from: sender.draggingPasteboard) else { return [] }
        store.isDropTargeted = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        store.isDropTargeted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        store.isDropTargeted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        store.isDropTargeted = false
        return store.add(from: sender.draggingPasteboard) > 0
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        store.isDropTargeted = false
    }
}
