# LocPilot · macOS 15 兼容版

> 上游项目：[Sein-Ding/locpilot](https://github.com/Sein-Ding/locpilot)（GPL-3.0）
> 本仓库是**本地兼容移植分支**，不是替代品。上游的中英文完整文档已原样归档在
> [`docs/upstream-README.md`](docs/upstream-README.md) 与 [`docs/upstream-README.en.md`](docs/upstream-README.en.md)。

一句话：让 LocPilot 能在 **macOS 15（Sequoia）** 上编译、双击运行，并把几个实际使用中卡手的地方修掉。

[**下载 v1.0.2-macOS15**](https://github.com/RichardHuang0001/locpilot-macos15/releases/tag/v1.0.2-macos15) ·
macOS 15.0+ / Apple Silicon · 约 800 KB · GPL-3.0

---

## 一、为什么要这个分支

原作者对这个项目的定位（原文引用）：

> 点一下地图，把 iPhone 的定位传送到那里。
>
> **原生 macOS App**（SwiftUI + MapKit + 系统材质玻璃）· 类 iAnyGo 的 iOS 虚拟定位工具 ·
> iOS 17+ 走 RemoteXPC/DTX 隧道、默认**免 sudo** · **无需越狱**

上游为了启用 macOS 26 的 Liquid Glass，把部署目标钉在 `26.0`，并在文档里写明：

> **要求：Apple Silicon（M1 / M2 / M3 / M4 …）Mac + macOS 26 或更高**
> —— 本版以 macOS 26 SDK 构建，才能启用系统 Liquid Glass 新外观。

在 macOS 15.6 + macOS 15.4 SDK 的机器上实测，这一步不只是"外观回落"：

- **编译直接失败**：`glassEffect(_:in:)` 在 macOS 15 SDK 里**没有这个符号**。
  放进 `#available(macOS 26.0, *)` 也没用 —— `#available` 只做运行时判断，不解决符号解析。
- 因此必须修改源码，而不是改一个版本号。

---

## 二、这个分支做了什么

| # | 项目 | 上游 | 本分支 | 实测收益 |
|---|---|---|---|---|
| 1 | 部署目标 | `macOS 26.0` | **`macOS 15.0`** | 可在 macOS 15 编译运行 |
| 2 | 玻璃控件 | `glassEffect(.regular.interactive())` | `.regularMaterial` + 描边 + 阴影 | 保留圆形/胶囊、毛玻璃、深浅色自适应；仅少"指针交互高光" |
| 3 | 地点搜索 | Nominatim（OpenStreetMap） | **`MKLocalSearch`（系统地图 / 国内高德数据）** | 搜「万象城」：5 条同名 → **17 条含分店**；搜「海底捞」：5 条 → **25 条带门店名** |
| 4 | 连接速度 | 每次连接约 **12 s** | **0.57–0.65 s** | 见下方拆解 |
| 5 | 冷启动 | — | **4.2–4.6 s**（双击→已连上） | 与窗口 / MapKit 初始化并行 |
| 6 | 失败恢复 | 会话失效后只能手动重连 | 自动重试 → 重建会话 → 再试 | 锁屏/切后台不再"点不动" |
| 7 | 本地 API 安全 | 只绑回环，无来源校验 | 增加 Origin / Sec-Fetch-Site 校验 + Host 白名单 | 阻断网页 CSRF 改定位与 DNS rebinding |
| 8 | 打包脚本 | 退出前全局 `pkill -f "locpilot serve"` | 只清理本次自检派生的子进程 | 不会误杀你自己的其它会话 |
| 9 | 错误提示 | 失败原因只写日志 | 显示在手机图标弹框里（可复制） | 不用再猜"为什么连不上" |

### 连接为什么能快 20 倍

先测量再改。原流程 12 s 的真实构成（M1 / iPhone 18 Pro Max / iOS 27.3）：

| 阶段 | 耗时 | 性质 |
|---|---|---|
| `pymobiledevice3 usbmux list` 子进程 | 3.37 s | 纯开销 |
| `pymobiledevice3 mounter auto-mount` 子进程 | 7.65 s | 纯开销，且 DDI 通常已挂载 |
| lockdown + RSD 隧道 + DVT + 定位服务 | 0.34 s | 真正干活 |

**11 秒在等子进程。** 三处改动：

1. **会话进程内执行**：不再为每次连接新起 worker 子进程（子进程要重新导入 `pymobiledevice3`，约 2.6 s）。
2. **惰性挂载**：先直接开 DVT，只有报 `dtservicehub` / `InvalidServiceError` 时才用库调用补挂 DDI 并重试。
3. **进程内枚举设备**：后端本就跑在装了 `pymobiledevice3` 的解释器里，直接 `await usbmux.list_devices()`（0.13 s）。

> 中途还踩过一个坑，一并记录：曾加过"启动预热线程"，结果它与"连接"争抢同一个 Python 导入锁，
> 冷启动反而从 3.8 s 拖到 4.5 s。已移除。

---

## 三、构建与安装

### 直接用（Apple Silicon + macOS 15.0+）

**[⬇︎ LocPilot-1.0.2-macOS15-arm64.dmg](https://github.com/RichardHuang0001/locpilot-macos15/releases/download/v1.0.2-macos15/LocPilot-1.0.2-macOS15-arm64.dmg)**（约 800 KB）

SHA-256：`1c78d495461d38232ea33589e98771c6b570e72028b3f9b01a1b875566d671f7`
（同名 `.sha256` 文件也在 Release 里；下载后可自行核对）

下载后打开 DMG，把 **LocPilot.app** 拖进右侧的「应用程序」文件夹。

首次打开会被 Gatekeeper 拦一次（ad-hoc 签名、无公证）：

- 右键点 App → 打开 → 弹窗里再点「打开」；或
- `xattr -dr com.apple.quarantine /Applications/LocPilot.app`

### 自己编译

需要：Apple Silicon Mac、macOS 15+、Command Line Tools（或完整 Xcode）、Python 3.10+。

```bash
git clone <this-repo> && cd locpilot

bash scripts/setup-engine.sh     # 建 .venv 并安装 pymobiledevice3
bash macos/build.sh --check      # SwiftPM 预检
bash macos/build.sh              # 产出 macos/build/LocPilot.app
bash macos/build.sh --selftest   # 无界面自检（后端健康检查）
bash macos/build.sh --smoke      # 启动冒烟：进程存活 + 后端就绪 + 崩溃报告守卫
bash macos/dist.sh               # 产出 DMG + sha256 + 分发级验证
```

运行原生单元测试（零依赖测试运行器，不需要 XCTest）：

```bash
swift run --package-path macos -c release --disable-sandbox LocPilotTests
```

当前 **231 项全部通过**（SSE 分帧、落针动画状态机、坐标契约等）。

### 定位引擎

App 按以下顺序找 Python 解释器：

1. `LOCPILOT_PYTHON` 环境变量
2. `~/Library/Application Support/LocPilot/venv/bin/python3`
3. 仓库内 `.venv/bin/python`
4. `/opt/homebrew/bin/python3` → `/usr/local/bin/python3` → `/usr/bin/python3`

DMG 内**不含** Python 运行时。首次使用真机功能时，走菜单「引擎 → 安装 / 修复定位引擎…」。
没有引擎时仍可用 mock 引擎体验界面。

---

## 四、使用

1. USB 连接 iPhone，手机上点「信任此电脑」，并在「设置 → 隐私与安全性 → 开发者模式」打开开发者模式（需重启一次并输入锁屏密码）。
2. 打开 App，右上角手机图标变绿即已连接。
3. `⌘F` 搜索地点，回车或点击结果跳转并落针。
4. 点右上角红色 ↺ 或 `⌘⇧C` 恢复真实定位。

右上控件簇说明：

| 位置 | 图标 | 作用 |
|---|---|---|
| 1 | 手机 | 连接状态；点击展开状态弹框（含失败原因） |
| 2 | 放大镜 | 搜索地点（`⌘F`） |
| 3 | 定位箭头 | 跟随定位：位置变化时镜头自动跟随（不改设备定位） |
| 4 | 红色回转箭头 | 恢复真实定位（清除模拟定位） |
| 5–6 | ＋ / － | 缩放 |

关窗口即完全退出：后端进程、设备会话、监听端口一并收掉，不留后台残留，也没有任何开机自启项。

---

## 五、已知限制

1. **没有 Liquid Glass 的指针交互高光**。那是 macOS 26 系统材质自带的效果，macOS 15 上不存在，只能退到 `.regularMaterial`。
2. **iOS 27.3 真机定位链路未做端到端验证**。已确认 `usbmux` 能识别设备、`lockdown` 能配对、用户态 RSD 隧道可建立、DVT 与 `LocationSimulation` 服务可打开；但"下发坐标后手机确实位移"这一步受设备条件限制未复测。
3. **ad-hoc 签名，未公证**。拷到别的 Mac 首次打开会被拦一次（右键打开即可）。
4. **冷启动约 4.5 s**，其中 1.4 s 是 Python 导入 `pymobiledevice3`（每个新进程都要付），属于下限。

---

## 六、许可与致谢

- **License：GPL-3.0**，沿用上游，见 [`LICENSE`](LICENSE) 与 [`NOTICE.md`](NOTICE.md)。
- **关于 MIT**：上游以 GPL-3.0 发布，本项目是其衍生作品，**不能单方面改为 MIT**。
  如需 MIT 授权，须先取得原作者同意。
- 上游项目与全部设计归 [@Sein-Ding](https://github.com/Sein-Ding) 所有；
  本分支只做 macOS 15 兼容移植与使用体验上的改动。
- 第三方组件（pymobiledevice3、libimobiledevice、go-ios 等）的许可与用途见 `NOTICE.md`。

上游完整文档（含逐文件架构说明、协议细节）见 [`docs/upstream-README.md`](docs/upstream-README.md)。
