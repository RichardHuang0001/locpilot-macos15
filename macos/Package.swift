// swift-tools-version: 5.9
import PackageDescription

// LocPilot 原生 macOS 版：SwiftPM 工程，命令行 swift build 即可构建（不依赖 Xcode）。
// 说明：Command Line Tools 不含 SwiftUI 宏插件，因此源码内不使用 @State / @Bindable，
// 状态统一用 ObservableObject + @StateObject / @Published（属性包装器，CLT 可用）。
let package = Package(
    name: "LocPilot",
    // macOS 15 兼容分支：原版要求 26（为了 Liquid Glass 新外观），
    // 这里降到 15.0，玻璃外观改由 .regularMaterial 实现（见 ControlsCluster.swift 的 GlassChrome）。
    // 用字符串形式而不是 .v15，兼容更早的 swift-tools-version。
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "LocPilotKit", targets: ["LocPilotKit"]),
        .executable(name: "LocPilot", targets: ["LocPilotApp"]),
        // 零依赖测试运行器：Command Line Tools 没有 XCTest，用可执行 target 代替 swift test
        .executable(name: "LocPilotTests", targets: ["LocPilotTests"]),
    ],
    targets: [
        .target(name: "LocPilotKit", path: "Sources/LocPilotKit"),
        .executableTarget(name: "LocPilotApp", dependencies: ["LocPilotKit"], path: "Sources/LocPilotApp"),
        .executableTarget(name: "LocPilotTests", dependencies: ["LocPilotKit"], path: "Sources/LocPilotTests"),
    ]
)
