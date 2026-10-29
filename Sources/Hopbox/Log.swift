import AppKit
import os

/// 다른 앱과 주고받을 때 무엇이 오갔는지 남기는 기록. 내용은 빼고 형식 이름만 남긴다.
/// `log show --last 10m --predicate 'subsystem == "com.haul.hopbox"'` 로 본다
enum Log {
    static let transfer = Logger(subsystem: "com.haul.hopbox", category: "transfer")

    static func types(_ label: String, _ pasteboard: NSPasteboard) {
        let types = (pasteboard.types ?? []).map(\.rawValue).joined(separator: ", ")
        transfer.notice("\(label, privacy: .public): \(types, privacy: .public)")
    }
}
