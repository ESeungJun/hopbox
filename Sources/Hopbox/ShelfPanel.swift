import AppKit
import Carbon
import Combine
import SwiftUI

/// 단축키를 누른 그 화면(전체화면 앱의 Space 포함) 위에 뜨는 상자.
/// 다른 앱을 비활성화하지 않는 패널이라, 띄워도 전체화면 앱에서 빠져나가지 않는다.
final class ShelfPanel: NSPanel {
    private let store: ShelfStore
    private let state = BoxState()
    /// 상자 아이콘 중심의 화면 좌표. 창이 커지고 줄어도 아이콘은 이 자리에 있다
    private var anchor = NSPoint.zero
    private var isApplyingLayout = false
    private var collapseWorkItem: DispatchWorkItem?
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
        itemsObserver = store.$items.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, self.state.mode != .icon else { return }
            self.applyLayout(self.state.mode)
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(didMove), name: NSWindow.didMoveNotification, object: self
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - 띄우기

    func toggle() {
        if isVisible && isOnActiveSpace {
            hide()
        } else {
            show()
        }
    }

    func show() {
        // 다른 Space 에 떠 있던 창이면 한 번 내렸다가 지금 Space 로 다시 띄운다
        if isVisible && !isOnActiveSpace { orderOut(nil) }
        guard !isVisible else {
            makeKeyAndOrderFront(nil)
            return
        }
        collapseWorkItem?.cancel()
        anchor = NSEvent.mouseLocation
        state.mode = .icon
        applyLayout(.icon)
        deliver()
    }

    /// 택배가 도착하듯 제자리 위에서 살며시 내려앉고, 담긴 게 있으면 바로 열린다.
    /// 창은 움직이지 않고 상자 그림만 움직인다. 창째 옮기면 내용이 따라오지 못해 튀어 보인다
    private func deliver() {
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        state.landing += 1
        // 상자가 내려앉기 전 자세를 잡은 다음 창을 보인다
        DispatchQueue.main.async { [weak self] in self?.alphaValue = 1 }
        guard !store.items.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.isVisible, self.state.mode == .icon else { return }
            self.setMode(.fan)
        }
    }

    func hide() {
        collapseWorkItem?.cancel()
        orderOut(nil)
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
