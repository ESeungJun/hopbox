import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Dock 아이콘 없이 메뉴 막대에만 있는 앱
    app.setActivationPolicy(.accessory)
    // app.delegate 는 약한 참조라, 앱이 도는 동안 delegate 가 살아 있게 붙잡아 둔다
    withExtendedLifetime(delegate) { app.run() }
}
