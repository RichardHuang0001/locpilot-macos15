import AppKit
import LocPilotKit
import SwiftUI

@main
struct LocPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // 用单例而不是就地 new：AppDelegate 要在窗口创建前就启动后端（见 startBackendEarly）
    @StateObject private var state = AppState.shared

    init() {
        // 无界面自检入口：LocPilot --selftest（供 build.sh / CI 断言用，不会创建窗口）
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
        }
    }

    var body: some Scene {
        WindowGroup("LocPilot") {
            RootView()
                .environmentObject(state)
                .background(WindowConfigurator())
        }
        // 全面屏：内容铺满整窗，交通灯浮在页面上方（窗口细节由 WindowConfigurator 补齐）
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            // 只清掉"新建窗口"（本应用不需要多窗口），但保留 File 菜单本身 ——
            // 否则整组为空时菜单会消失，⌘W 也就没有绑定，用户只能去点红灯。
            CommandGroup(replacing: .newItem) {
                Button("关闭窗口") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: .command)
            }

            CommandMenu("设备") {
                Button("连接设备") { Task { await state.connect() } }
                    .keyboardShortcut("k", modifiers: .command)
                Button("断开设备") { Task { await state.disconnect() } }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("恢复真实定位") { Task { await state.clearLocation() } }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }

            CommandMenu("地图") {
                Button(state.searchActive ? "关闭搜索" : "搜索地点…") {
                    withAnimation(.easeOut(duration: 0.18)) { state.toggleSearch() }
                }
                .keyboardShortcut("f", modifiers: .command)
            }

            CommandMenu("引擎") {
                Button("安装 / 修复定位引擎…") { state.showInstaller = true }
                Button("打开状态目录") { NSWorkspace.shared.open(BackendController.appSupport) }
            }
        }
    }
}

/// 根视图：后端就绪前显示启动画面，就绪后交给地图。
struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        // ZStack 的身份是稳定的：Group/Splash→Map 的内容切换不会重启 .task
        ZStack {
            if state.backendReady {
                MapScreen()
            } else {
                SplashView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .sheet(isPresented: $state.showInstaller) {
            EngineInstallerView(
                installer: state.installer,
                basePython: state.backend.installationPython() ?? "/usr/bin/python3",
                onClose: { state.showInstaller = false }
            )
        }
        .task { await state.bootstrap() }
        .onAppear { AppDelegate.state = state }
    }
}

/// 启动画面：后端进程拉起 + 健康检查期间显示。
struct SplashView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "location.north.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("LocPilot").font(.largeTitle).bold()
            Text(state.phase.text).foregroundStyle(.secondary)
            if case .failed(let message) = state.phase {
                Text(message).font(.caption).foregroundStyle(.red)
                Button("重试") { Task { await state.bootstrap() } }
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

/// 应用生命周期：负责激活策略与退出时回收后端进程（避免留下孤儿端口）。
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var state: AppState?

    /// 后端在 delegate 初始化时就拉起 —— 这是进程里最早的可用时机（早于窗口、早于 MapKit）。
    /// 后端 0.6s 就绪 + 连接要等 Python 导入 1.4s，这两段必须和界面初始化重叠，
    /// 否则用户要串行等完"界面出来"再等"连接完成"。
    override init() {
        super.init()
        MainActor.assumeIsolated { AppState.shared.startBackendEarly() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 关掉最后一个窗口**不退出**：程序留在程序坞，后端与设备会话保持存活。
    /// 真正的退出只有两条路：程序坞右键 → 退出，或 ⌘Q。
    /// 这样下次从程序坞打开只是"把窗口拿回来"（约 0.3s），不必重付冷启动成本。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 点程序坞图标时把窗口带回来。
    /// 窗口已被关掉（场景销毁）时由 SwiftUI 重建 WindowGroup；我们能做的是：
    /// 先激活应用，再把任何还能用的窗口置前 —— 返回 true 让系统继续走正常流程。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // 这里**只激活、不自己造窗口**：窗口被关掉后由 SwiftUI 重建 WindowGroup，
        // 我们再 orderFront 一次就会多出一个重复窗口（实测过，会出现两个）。
        if flag, let window = sender.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppDelegate.state?.shutdown() }
    }
}
