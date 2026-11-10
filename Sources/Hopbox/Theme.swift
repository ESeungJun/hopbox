import AppKit
import HopboxCore
import SwiftUI

/// 상자 그림에서 뽑은 색. 강조색을 시스템 파랑 대신 테이프색으로 쓴다
enum Theme {
    /// 골판지
    static let cardboard = Color(red: 0.85, green: 0.64, blue: 0.37)
    /// 테이프. 강조(테두리·화살표·"+N")에 쓴다
    static let tape = Color(red: 0.80, green: 0.50, blue: 0.18)
    /// 운송장 빨강. 개수 배지와 "보냄" 도장
    static let waybill = Color(red: 0.86, green: 0.24, blue: 0.2)
    static let dust = Color(red: 0.8, green: 0.72, blue: 0.6)
    /// 메모지
    static let note = Color(red: 1, green: 0.97, blue: 0.82)

    /// 이름표 왼쪽 띠. 종류를 색으로 가른다
    static func stripe(for kind: ShelfItem.Kind) -> Color {
        switch kind {
        case .file: return cardboard
        case .image: return tape
        case .text: return Color(red: 0.95, green: 0.82, blue: 0.36)
        }
    }
}

enum Motion {
    /// 시스템 설정 › 손쉬운 사용 › 디스플레이 › 동작 줄이기.
    /// 켜져 있으면 떨어지고 튀는 연출 대신 짧은 페이드와 테두리 강조를 쓴다
    static var isReduced: Bool {
        #if DEBUG
        // 개발용: 시스템 설정을 바꾸지 않고 동작 줄이기 화면을 본다
        if ProcessInfo.processInfo.environment["HOPBOX_REDUCE_MOTION"] != nil { return true }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// 상자 그림. 앱 묶음의 Resources 에 든 png 를 쓰고, 없으면(시험 실행 등) SF Symbol 로 대신한다
enum BoxArt {
    static let closed = load("box-closed")
    static let open = load("box-open")

    private static func load(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }
}
