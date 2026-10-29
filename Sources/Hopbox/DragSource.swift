import AppKit
import SwiftUI

/// 상자 안의 항목을 다른 앱으로 끌어내는 영역.
/// SwiftUI 의 onDrag 는 Finder 로 끌 때 원본을 옮겨 버릴 수 있어서, 복사만 허용하는 AppKit 드래그를 쓴다.
struct DragSource: NSViewRepresentable {
    var writers: () -> [(NSPasteboardWriting, NSImage)]
    var onClick: () -> Void = {}
    var menu: () -> NSMenu? = { nil }

    func makeNSView(context: Context) -> DragSourceView {
        DragSourceView()
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.writers = writers
        view.onClick = onClick
        view.makeMenu = menu
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    var writers: () -> [(NSPasteboardWriting, NSImage)] = { [] }
    var onClick: () -> Void = {}
    var makeMenu: () -> NSMenu? = { nil }

    private var mouseDownEvent: NSEvent?

    // 상자 창은 다른 앱을 활성화한 채로 떠 있으므로 첫 클릭부터 받아야 한다
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // 투명한 뷰는 기본값이 true 라서, 끄지 않으면 항목을 끌 때 창이 대신 끌린다
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, event.isFarFrom(down) else { return }
        mouseDownEvent = nil

        let payload = writers()
        guard !payload.isEmpty else { return }

        let origin = convert(down.locationInWindow, from: nil)
        let draggingItems = payload.enumerated().map { index, entry in
            let item = NSDraggingItem(pasteboardWriter: entry.0)
            let offset = CGFloat(min(index, 4)) * 4
            item.setDraggingFrame(
                NSRect(x: origin.x - 20 + offset, y: origin.y - 20 - offset, width: 40, height: 40),
                contents: entry.1
            )
            return item
        }
        beginDraggingSession(with: draggingItems, event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownEvent != nil { onClick() }
        mouseDownEvent = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeMenu()
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Log.transfer.notice("끌어내기 끝: operation \(operation.rawValue, privacy: .public)")
    }
}

/// 상자 아이콘. 누르면 열고 닫고, 끌면 상자를 옮긴다.
struct WindowHandle: NSViewRepresentable {
    var onClick: () -> Void

    func makeNSView(context: Context) -> WindowHandleView {
        WindowHandleView()
    }

    func updateNSView(_ view: WindowHandleView, context: Context) {
        view.onClick = onClick
    }
}

final class WindowHandleView: NSView {
    var onClick: () -> Void = {}
    private var mouseDownEvent: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, event.isFarFrom(down) else { return }
        mouseDownEvent = nil
        window?.performDrag(with: down)
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownEvent != nil { onClick() }
        mouseDownEvent = nil
    }
}

private extension NSEvent {
    /// 클릭과 끌기를 가르는 기준. 3pt 넘게 움직이면 끌기로 본다
    func isFarFrom(_ other: NSEvent) -> Bool {
        hypot(locationInWindow.x - other.locationInWindow.x, locationInWindow.y - other.locationInWindow.y) > 3
    }
}

/// 클로저로 동작하는 메뉴 항목. 우클릭 메뉴를 SwiftUI 쪽에서 간단히 만들기 위해 쓴다.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func run() { handler() }
}

extension ShelfStore {
    /// 항목 우클릭 메뉴. 목록과 부채꼴이 같이 쓴다
    func contextMenu(for item: ShelfItem) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("복사") { [weak self] in self?.copyToPasteboard(item) })
        if item.kind != .text, item.exists {
            menu.addItem(ClosureMenuItem("Finder에서 보기") { [weak self] in self?.revealInFinder(item) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("상자에서 빼기") { [weak self] in self?.remove(item) })
        return menu
    }

    func dragWriters(for items: [ShelfItem]) -> [(NSPasteboardWriting, NSImage)] {
        items.compactMap { item in pasteboardWriter(for: item).map { ($0, dragImage(for: item)) } }
    }
}
