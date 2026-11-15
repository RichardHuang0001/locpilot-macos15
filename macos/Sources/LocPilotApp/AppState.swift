import Combine
import Foundation
import LocPilotKit
import MapKit
import SwiftUI

/// 界面唯一状态源：后端生命周期 + 引擎连接 + 当前位置 + 相机。
/// 说明：本机只有 Command Line Tools，SwiftUI 宏插件不可用，因此不使用 @State/@Bindable，
/// 全部状态走 ObservableObject + @Published（属性包装器）。
@MainActor
final class AppState: ObservableObject {
    enum Connection: Equatable {
        case offline
        case connecting
        case online
        case failed(String)

        var isOnline: Bool { self == .online }
    }

    @Published private(set) var phase: BackendController.Phase = .idle
    @Published private(set) var connection: Connection = .offline
    @Published private(set) var deviceName: String?
    /// 最近一次连接失败的原因。启动时只写这里，**不弹提示**；用户点开手机图标才看到。
    @Published private(set) var lastError: String?
    /// 手机图标的小弹框显隐（点图标展开）
    @Published var devicePopoverShown = false
    @Published private(set) var position: LatLon?

    /// 地图上的大头针位置与名称（动画状态在 PinAnimator 里）。
    struct Marker: Equatable {
        var lat: Double
        var lon: Double
        var label: String
    }
    @Published private(set) var marker: Marker?

    /// 大头针动画状态机。组件只管怎么动，这里只管什么时候动。
    let pin = PinAnimator()

    /// 落针动画期间不要让事件流改写标记位置
    var isPinAnimating: Bool {
        switch pin.phase {
        case .dropping, .landed, .processing: return true
        default: return false
        }
    }
    @Published private(set) var lastMessage: String?
    @Published var camera: MapCameraPosition = .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
                           latitudinalMeters: 8000, longitudinalMeters: 8000))
    /// 当前可见区域：由 Map 的 onMapCameraChange 回填。MapCameraPosition 是 struct，
    /// 取不回 region，所以缩放/定位都以这个值为基准。
    @Published private(set) var visibleRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
        latitudinalMeters: 8000, longitudinalMeters: 8000)
    @Published var showInstaller = false
    /// 鼠标是否停在窗口顶部：用于浮现半透明标题栏提示。
    @Published private(set) var titlebarHovered = false

    /// 顶部悬停状态由拖拽热区回调驱动（进入快、离开稍慢，避免边缘抖动闪烁）。
    func setTitlebarHovered(_ hovering: Bool) {
        guard titlebarHovered != hovering else { return }
        withAnimation(.easeOut(duration: hovering ? 0.15 : 0.25)) { titlebarHovered = hovering }
    }

    /// 是否"跟随定位"：打开后，只要定位变化，镜头就自动跟过去（Apple 地图定位键的语义）。
    @Published private(set) var followsPosition = false

    var hasPosition: Bool { position != nil }
    @Published private(set) var backendReady = false

    /// 手机图标的状态色：连上绿色泛光；未连接黄色泛光；后端自身失败才用红色。
    var statusColor: Color {
        if case .failed = phase { return .red }
        return connection.isOnline ? .green : .yellow
    }

    // 说明：连接失败的具体原因只写日志，不在界面上展示（用户要求界面极简）。

    /// 单例：AppDelegate 需要在窗口创建前就拿到它并启动后端，
    /// 所以不能再只依赖 SwiftUI 的 @StateObject 初始化时机。
    static let shared = AppState()

    let backend = BackendController()
    let installer = EngineInstaller()

    private var client: EngineClient?
    private var eventTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var selectionID = UUID()
    private var teleportTask: Task<LatLon, Error>?

    init(client: EngineClient? = nil) {
        self.client = client
    }

    // MARK: - 生命周期

    private var didBootstrap = false

    /// 尽早拉起后端：在 window 创建前调用。
    /// 后端要 0.6s 才 HTTP 就绪、连接还要再等 Python 导入 pymobiledevice3（约 1.4s），
    /// 这些都该和"窗口 / MapKit 初始化"并行，而不是排在它后面。
    func startBackendEarly() {
        backend.start()
        phase = backend.phase
    }

    func bootstrap() async {
        // 只跑一次：SwiftUI 的 .task 在视图身份变化时会重启，
        // 而重复 connect 会把后端刚建好的连接关掉（session.connect 先 close 再 open）。
        guard !didBootstrap else { return }
        didBootstrap = true
        backend.start()
        phase = backend.phase
        guard await backend.waitUntilHealthy() else {
            phase = backend.phase
            connection = .failed("后端启动失败")
            backend.stop()
            didBootstrap = false
            return
        }
        phase = .running
        backendReady = true
        let client = EngineClient(baseURL: backend.baseURL)
        self.client = client
        startEventStream(client)
        // 自动连接策略：默认 auto；验收/调试可用环境变量强制指定，
        // 避免脚本在插着真机时误连用户手机。
        if ProcessInfo.processInfo.environment["LOCPILOT_AUTOCONNECT"] != "0" {
            // 启动时静默连接：成功就绿，没设备就黄，绝不弹提示
            await connect(engine: Self.preferredEngine, silent: true)
        }
    }

    func shutdown() {
        invalidateSelection()
        eventTask?.cancel()
        backend.stop()
    }

    // MARK: - 事件流

    private func startEventStream(_ client: EngineClient) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await snapshot in client.events() {
                guard let self else { return }
                await MainActor.run { self.apply(snapshot) }
            }
        }
    }

    private func apply(_ snapshot: StatusSnapshot) {
        deviceName = snapshot.engine.device?.name
        position = snapshot.position
        connection = snapshot.engine.opened ? .online : (snapshot.error == nil ? .offline : .failed(snapshot.error ?? ""))
        if let pos = snapshot.position {
            // 后端已经有位置（例如刚连上或别的客户端设过）：针直接落下，不再播动效
            if !isPinAnimating, marker == nil || (!isPinAnimating && (marker?.lat != pos.lat || marker?.lon != pos.lon)) {
                marker = Marker(lat: pos.lat, lon: pos.lon, label: marker?.label ?? "")
                Task { [weak self] in await self?.resolveLabel(lat: pos.lat, lon: pos.lon) }
            }
        } else if !isPinAnimating {
            marker = nil
        }
        // 跟随定位：只要位置真的变了就把镜头带过去（用户手动平移不会被抢，因为位置没变）
        if followsPosition, let pos = snapshot.position, pos != lastFollowTarget {
            lastFollowTarget = pos
            centerCamera(on: pos, spanMeters: max(currentSpanMeters, 1500))
        }
        // 相机只由用户操作驱动；事件流不抢镜头，否则每次状态推送地图都会跳回去。
        // 例外：首次拿到位置时居中一次，让用户一打开就看到手机在哪。
        if !didInitialCenter, let pos = snapshot.position {
            didInitialCenter = true
            moveCamera(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: pos.lat, longitude: pos.lon),
                                          latitudinalMeters: 4000, longitudinalMeters: 4000),
                       duration: 0.6)
        }
    }

    private var didInitialCenter = false

    // MARK: - 动作

    func toggleConnection() {
        if connection.isOnline { Task { await disconnect() } } else { Task { await connect() } }
    }

    /// 连接设备。silent = true 用于启动时的自动连接：失败只记状态，不弹提示。
    func connect(engine: String = "auto", silent: Bool = false) async {
        guard let client else { return }
        invalidateSelection()
        _ = try? await teleportTask?.value
        connection = .connecting
        do {
            let result = try await client.connect(engine: engine)
            deviceName = result.device?.name
            connection = .online
            lastError = nil
            log("connect(engine: \(engine)) -> \(result.engine) / \(result.device?.name ?? "-")")
            if !silent, let notes = result.notes, !notes.isEmpty { flash(notes.joined(separator: " ")) }
            await refresh()
        } catch {
            connection = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            log("connect 失败: \(error.localizedDescription)")
            // 一律不把后端原文抛到界面：设备没插是常态，状态由手机图标（黄色泛光 + 小弹框）表达。
            // 具体原因只写日志。silent 仅用于区分是否记录启动期日志。
            _ = silent
        }
    }

    func disconnect() async {
        guard let client else { return }
        invalidateSelection()
        _ = try? await teleportTask?.value
        do {
            try await client.disconnect()
            connection = .offline
            position = nil
            marker = nil
            deviceName = nil
        } catch {
            lastError = error.localizedDescription
            log("断开失败: \(error.localizedDescription)")
            flash("断开失败")
        }
    }

    func teleport(lat: Double, lon: Double) async {
        do {
            try await performTeleport(lat: lat, lon: lon)
        } catch {
            log("传送失败: \(error.localizedDescription)")
            flash("传送失败")
        }
    }

    /// 纯业务调用：只负责把坐标发给后端。动画状态由调用方决定。
    private func performTeleport(lat: Double, lon: Double, selection token: UUID? = nil) async throws {
        // 已下发的请求先完成；新选择只影响尚未下发的动作与 UI 回调。
        let previous = teleportTask
        let task = Task { [weak self] () throws -> LatLon in
            _ = try? await previous?.value
            try Task.checkCancellation()
            guard let self else { throw CancellationError() }
            if let token, token != self.selectionID { throw CancellationError() }
            guard let client = self.client else { throw EngineError.backend("后端尚未就绪") }
            return try await client.teleport(lat: lat, lon: lon).position
        }
        teleportTask = task
        let result = try await task.value
        try Task.checkCancellation()
        if let token, token != selectionID { throw CancellationError() }
        position = result
    }

    func teleport(to coordinate: CLLocationCoordinate2D) async {
        await teleport(lat: coordinate.latitude, lon: coordinate.longitude)
    }

    func clearLocation() async {
        guard let client else { return }
        invalidateSelection()
        _ = try? await teleportTask?.value
        do {
            try await client.clear()
            position = nil
            marker = nil
            followsPosition = false      // 没有定位了，跟随自然失效
            lastFollowTarget = nil
        } catch {
            log("恢复真实定位失败: \(error.localizedDescription)")
            flash("恢复失败")
        }
    }

    func refresh() async {
        guard let client else { return }
        if let snapshot = try? await client.status() { apply(snapshot) }
    }

    // MARK: - 相机

    /// 定位键：有定位时切换"跟随"；没有定位时给一句提示（按键本身也会置灰）。
    func toggleFollow() {
        guard let position else {
            flash("还没有设定位置，点一下地图即可")
            return
        }
        followsPosition.toggle()
        if followsPosition {
            lastFollowTarget = position
            centerCamera(on: position, spanMeters: max(currentSpanMeters, 1500))
        }
    }

    private var lastFollowTarget: LatLon?

    private func centerCamera(on position: LatLon, spanMeters: Double) {
        didInitialCenter = true
        moveCamera(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: position.lat, longitude: position.lon),
            latitudinalMeters: spanMeters, longitudinalMeters: spanMeters),
                   duration: 0.45)
    }

    func focusOnPosition() {
        guard let position else { flash("还没有设定位置，点一下地图即可"); return }
        didInitialCenter = true
        let span = currentSpanMeters
        moveCamera(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: position.lat, longitude: position.lon),
                                      latitudinalMeters: max(span, 1500), longitudinalMeters: max(span, 1500)),
                   duration: 0.45)
    }

    /// 点击地图：先落针并显示地址，落稳后才下发定位。
    /// 点击地图：先落针（圆环 → 下落 → 冲击 → processing），落稳后由业务发起定位，
    /// 再按结果驱动成功 / 失败动画。成功失败绝不写死在动画里。
    func selectLocation(lat: Double, lon: Double) async {
        let token = UUID()
        selectionID = token
        pin.reset()
        marker = Marker(lat: lat, lon: lon, label: "")
        Task { [weak self] in await self?.resolveLabel(lat: lat, lon: lon) }

        await pin.dropPin()                           // 结束时进入 .processing
        guard token == selectionID, !Task.isCancelled else { return }

        do {
            try await performTeleport(lat: lat, lon: lon, selection: token)
            guard token == selectionID, !Task.isCancelled else { return }
            await pin.succeed()          // 成功反馈只由大头针变绿 + ✓ 表达
        } catch {
            guard token == selectionID, !Task.isCancelled, !(error is CancellationError) else { return }
            // 设备锁屏、切到别的 App、隧道抖动，都会让 DVT 会话**静默**失效，
            // 表现就是"刚才还好好的，忽然点不动了" —— 这是用户说的"不稳定"。
            // 先原样重试一次（多数是瞬时抖动）；仍失败就重建会话再试，
            // 而不是让用户自己发现要去点"重新连接"。
            if await retryTeleport(lat: lat, lon: lon, token: token) {
                await pin.succeed()
                return
            }
            log("传送失败: \(error.localizedDescription)")
            flash("传送失败")
            await pin.fail()
        }
    }

    /// 失败自愈：先重试一次，仍失败则重建会话后再试一次。
    private func retryTeleport(lat: Double, lon: Double, token: UUID) async -> Bool {
        for attempt in 0..<2 {
            guard token == selectionID, !Task.isCancelled else { return false }
            if attempt == 1, await rebuildSession() == false { return false }
            if (try? await performTeleport(lat: lat, lon: lon, selection: token)) != nil { return true }
        }
        return false
    }

    /// 重建与设备的会话（断开 → 重连）。连不上就如实写回状态，不假装成功。
    private func rebuildSession() async -> Bool {
        guard let client else { return false }
        log("会话可能已失效，正在重建…")
        try? await client.disconnect()
        do {
            let result = try await client.connect(engine: Self.preferredEngine)
            deviceName = result.device?.name
            connection = .online
            lastError = nil
            log("会话已重建: \(result.device?.name ?? "-")")
            return true
        } catch {
            connection = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            log("重建会话失败: \(error.localizedDescription)")
            return false
        }
    }

    private func invalidateSelection() {
        selectionID = UUID()
        pin.reset()
    }

    /// 逆地理编码取"最近的街道/建筑名"填到落针标签上；失败就保持空白。
    private func resolveLabel(lat: Double, lon: Double) async {
        guard let client else { return }
        guard let place = try? await client.reverse(lat: lat, lon: lon), let label = place.shortLabel, !label.isEmpty else { return }
        guard var current = marker, abs(current.lat - lat) < 1e-9, abs(current.lon - lon) < 1e-9 else { return }
        current.label = label
        withAnimation(.easeOut(duration: 0.25)) { marker = current }   // 名称淡入，而不是硬切
    }

    /// 地图把当前可见区域回填进来（连续回调）。
    func updateVisibleRegion(_ region: MKCoordinateRegion) {
        visibleRegion = region
    }

    /// 缩放以"用户当前看到的跨度"为基准：触控板缩放后再点按钮也符合预期。
    /// 必须走 moveCamera：直接赋值相机是瞬移，放大缩小会"啪"地跳过去，很生硬。
    func zoom(factor: Double) {
        let span = min(max(visibleRegion.span.latitudeDelta * 111_000 * factor, 250), 600_000)
        moveCamera(MKCoordinateRegion(center: visibleRegion.center, latitudinalMeters: span, longitudinalMeters: span))
    }

    /// 相机统一入口：所有视角变化都带过渡，避免瞬移。
    /// 用 .smooth 而不是弹簧：缩放带过冲会看起来像"弹了一下"，不像系统地图。
    /// 默认 0.25s = 缩放按钮的手感（用户指定）。
    private func moveCamera(_ target: MKCoordinateRegion, duration: Double = 0.25) {
        withAnimation(.smooth(duration: duration)) {
            camera = .region(target)
        }
    }

    private var currentSpanMeters: Double { visibleRegion.span.latitudeDelta * 111_000 }

    // MARK: - 地点搜索

    /// 搜索面板显隐：⌘F 或右上控件簇的放大镜切换。
    @Published var searchActive = false
    @Published var searchQuery = ""
    @Published private(set) var searchResults: [SearchItem] = []
    @Published private(set) var searchError: String?
    @Published private(set) var searching = false

    private var searchTask: Task<Void, Never>?

    func toggleSearch() {
        searchActive.toggle()
        if !searchActive { clearSearch() }
    }

    func closeSearch() {
        guard searchActive else { return }
        searchActive = false
        clearSearch()
    }

    func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchQuery = ""
        searchResults = []
        searchError = nil
        searching = false
    }

    /// 输入变化时调用，280ms 防抖：`MKLocalSearch` 每次都是一趟网络往返，逐字发没意义。
    func searchQueryDidChange() {
        searchTask?.cancel()
        let keyword = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            searchResults = []
            searchError = nil
            searching = false
            return
        }
        searching = true
        searchError = nil
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled, let self else { return }

            // 1) 首选系统地图（国内为高德数据）：POI 密度和地图上看到的一致
            var items = await LocalPlaceSearch.search(keyword, in: self.visibleRegion)
            guard !Task.isCancelled else { return }
            guard self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == keyword else { return }

            // 2) 兜底：系统一条都没给时才问后端（OSM），避免两个数据源混排、质量参差
            if items.isEmpty, let client = self.client,
               let remote = try? await client.search(keyword, limit: 10) {
                items = remote.map { hit in
                    let title = (hit.name?.isEmpty == false ? hit.name : hit.displayName) ?? "未命名地点"
                    let subtitle = hit.displayName.flatMap { $0 == title ? nil : $0 }
                    return SearchItem(title: title, subtitle: subtitle, lat: hit.lat, lon: hit.lon)
                }
            }

            guard !Task.isCancelled else { return }
            guard self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == keyword else { return }
            self.searchResults = Array(Self.dedupe(items).prefix(8))
            self.searchError = self.searchResults.isEmpty ? "没找到「" + keyword + "」" : nil
            self.searching = false
        }
    }

    /// 合并同名且挨在一起的条目。
    /// 系统地图也会把同一个商场（不同出入口、不同楼层）拆成多条，
    /// 名称相同且相距 < 250m 视为同一条，保留第一条。
    static func dedupe(_ items: [SearchItem]) -> [SearchItem] {
        var kept: [SearchItem] = []
        for item in items {
            let isDuplicate = kept.contains { other in
                other.title == item.title && distance(other, item) < 250
            }
            if !isDuplicate { kept.append(item) }
        }
        return kept
    }

    private static func distance(_ a: SearchItem, _ b: SearchItem) -> Double {
        let dLat = (a.lat - b.lat) * 111_000
        let dLon = (a.lon - b.lon) * 111_000 * cos(a.lat * .pi / 180)
        return (dLat * dLat + dLon * dLon).squareRoot()
    }

    /// 选中一条结果：先把镜头带过去，再落针下发。
    /// 顺序重要 —— 没连设备时下发会失败，但用户至少能看到地点在哪。
    func choose(_ item: SearchItem) async {
        let span = max(currentSpanMeters, 2_000)
        moveCamera(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: item.lat, longitude: item.lon),
            latitudinalMeters: span,
            longitudinalMeters: span))
        searchActive = false
        clearSearch()
        await selectLocation(lat: item.lat, lon: item.lon)
    }

    // MARK: - 提示

    private func flash(_ text: String) {
        lastMessage = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            await MainActor.run { if self?.lastMessage == text { self?.lastMessage = nil } }
        }
    }

    /// LOCPILOT_ENGINE=auto|mock|pymobiledevice3|libimobiledevice|goios，缺省 auto。
    static var preferredEngine: String {
        let value = ProcessInfo.processInfo.environment["LOCPILOT_ENGINE"]?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? "auto" : value
    }

    /// 轻量日志：从命令行启动时直接进 stderr，便于排障（原生没有网页控制台）。
    private func log(_ message: String) {
        FileHandle.standardError.write(("[LocPilot] " + message + "\n").data(using: .utf8)!)
    }

    static func format(lat: Double, lon: Double) -> String {
        String(format: "%.6f, %.6f", lat, lon)
    }
}
