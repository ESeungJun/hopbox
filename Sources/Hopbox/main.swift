import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Dock 아이콘 없이 메뉴 막대에만 있는 앱
app.setActivationPolicy(.accessory)
app.run()
