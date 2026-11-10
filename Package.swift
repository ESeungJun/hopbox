// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Hopbox",
    platforms: [.macOS(.v13)],
    targets: [
        // 화면·클립보드를 모르는 규칙과 저장. 시험은 여기에 붙인다
        .target(name: "HopboxCore", path: "Sources/HopboxCore"),
        .executableTarget(name: "Hopbox", dependencies: ["HopboxCore"], path: "Sources/Hopbox"),
        .testTarget(name: "HopboxCoreTests", dependencies: ["HopboxCore"], path: "Tests/HopboxCoreTests"),
        .testTarget(name: "HopboxTests", dependencies: ["Hopbox", "HopboxCore"], path: "Tests/HopboxTests"),
    ]
)
