import SwiftUI
import AppKit

// MARK: - 全局状态（MainActor，SwiftUI 直接绑定）

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Phase: Equatable {
        case idle           // 未开始
        case checking       // 检测现有部署
        case running        // 部署中
        case qr             // 等待扫码
        case finished       // 完成
        case failed         // 失败
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let time: String
        let text: String
    }

    let stepTitles = ["检测 macFUSE", "部署组件", "启动服务", "登录夸克", "挂载网盘", "开启自启"]

    @Published var phase: Phase = .idle
    @Published var stepIndex = 0            // 当前步骤 0..5
    @Published var stepDone = [Bool](repeating: false, count: 6)
    @Published var logs: [LogEntry] = []
    @Published var progress: Double = 0     // 下载进度 0..1
    @Published var progressLabel = ""
    @Published var qrImage: NSImage? = nil
    @Published var qrHint = ""
    @Published var qrCountdown = 0
    @Published var fatalError: String? = nil
    @Published var deployed = false         // 检测到已部署
    @Published var macfuseReady = false
    @Published var mountOK = false
    @Published var cookieValid = false
    @Published var showMacFuseHelp = false  // macFUSE 开通指南弹窗

    var deployTask: Task<Void, Never>?      // 进行中的部署任务（防重入）
    var deployGeneration = 0                // 部署代际：旧任务的结果不得改写新任务状态
    var remountTask: Task<Void, Never>?     // 重新挂载任务（进行中禁用按钮）
    var refreshTask: Task<Void, Never>?     // 刷新登录任务（轻量扫码）
    var uninstallTask: Task<Void, Never>?   // 卸载任务（忙态互斥）
    @Published var uninstalling = false     // 卸载进行中：禁部署/重挂/检测，防并发互删

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func log(_ s: String) {
        logs.append(LogEntry(time: Self.timeFmt.string(from: Date()), text: s))
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }

    func resetSteps() {
        stepIndex = 0
        stepDone = [Bool](repeating: false, count: 6)
    }

    func enterStep(_ i: Int) {
        stepIndex = i
        progress = 0
        log("── \(stepTitles[i]) ──")
    }

    func finishStep(_ i: Int) {
        stepDone[i] = true
        stepIndex = min(i + 1, stepTitles.count - 1)
    }

    // MARK: 接管旧部署（防止旧 rclone 拿旧凭证狂试新服务触发登录限频）

    private func takeover() async {
        if await Installer.isMountedAsync() {
            log("卸载现有挂载（交由本应用管理）…")
            // 先优雅卸载（让 rclone 自行退出），失败才强卸载（强卸载可能使进程卡死占住目录）
            _ = await Installer.shAsync("diskutil unmount '\(Installer.mountPoint.path)' >/dev/null 2>&1 || umount '\(Installer.mountPoint.path)' >/dev/null 2>&1 || true")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if await Installer.isMountedAsync() {
                _ = await Installer.shAsync("diskutil unmount force '\(Installer.mountPoint.path)' >/dev/null 2>&1 || umount -f '\(Installer.mountPoint.path)' >/dev/null 2>&1 || true")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        // daemon 化后 argv 只剩 "rclone"，按进程名精确杀（-f 模式匹配不到）
        _ = await Installer.shAsync("pkill -f 'Application Support/QuarkMount/rclone.conf' 2>/dev/null || true")
        // 停掉非本应用的 openlist（旧版手动部署），保留本应用的——但只杀占着本应用端口(5244)的，
        // 用户自用的其他 openlist 实例（不同数据目录/端口）不误杀（v1.0.2 无条件全杀）
        if await Installer.shAsync("curl -s -o /dev/null --max-time 2 http://127.0.0.1:5244/").1 == 0 {
            _ = await Installer.shAsync("""
                for p in $(pgrep -f 'openlist server' 2>/dev/null); do
                  if ! ps -p $p -o command= 2>/dev/null | grep -q 'Application Support/QuarkMount'; then kill $p 2>/dev/null; fi
                done
                """)
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    // MARK: 入口

    func checkExisting() {
        // 防重入：部署中/扫码中/卸载中不重复检测（多窗口 onAppear 会并发触发）
        guard !uninstalling, phase == .idle || phase == .checking || phase == .finished || phase == .failed else { return }
        phase = .checking
        Task { await Self.detect() }
    }

    static func detect() async {
        let s = AppState.shared
        // 检测期间状态被别处改动（用户点了开始/另一窗口）则放弃本次结果
        guard s.phase == .checking else { return }
        // 四项检测并行（cookie 校验是网络请求，慢时不能拖累本地项；启动更快）
        // 挂载用健康判定（条目 + rclone 进程）：僵尸条目不配算「已挂载」
        async let macfuseR = Installer.isMacFuseReady()
        async let mountR = Installer.isMountedHealthyAsync()
        async let cookieR = QuarkAuth.hasValidCookie()
        async let svcR = Installer.serviceRunning()
        let (mf, mo, ck, sv) = await (macfuseR, mountR, cookieR, svcR)
        guard s.phase == .checking else { return }
        let cookieState = ck
        if cookieState == .networkError {
            // 网络抖动 ≠ 未部署：绝不能据此走自动部署（takeover 会卸载正常挂载）。
            // 早退必须发生在改写 cookieValid/deployed 之前——否则一次网络抖动就把
            // 就绪页静默降级成「开始部署」，诱导用户对健康挂载做重部署（v1.0.2 缺陷）
            s.phase = .idle
            s.log("⚠️ 登录状态检查失败（网络不通），已保留现状。请联网后重试")
            return
        }
        s.macfuseReady = mf
        s.mountOK = mo
        s.cookieValid = (cookieState == .valid)
        let svc = sv
        s.deployed = s.mountOK && svc && s.cookieValid
        s.log("检测完成：macFUSE \(s.macfuseReady ? "就绪" : "未就绪")，服务 \(svc ? "运行中" : "未运行")，挂载 \(s.mountOK ? "正常" : "未挂载")，登录 \(s.cookieValid ? "有效" : "无效")")
        s.phase = .idle
        // 未部署则自动开始（一键体验：打开即用）
        if !s.deployed {
            // 轻量恢复：登录还有效、只是挂载/服务没上（开机竞态、守护被杀）→ 唤醒守护进程即可，
            // 不必重新部署（takeover 会卸载正常挂载，代价大）。
            // 前提是「曾经部署过」（plist 存在）——全新安装直接走部署，不能在这儿等
            if s.cookieValid, Installer.agentPlistExists {
                let gen = s.deployGeneration   // 等待期间用户可能点了「开始部署」（代际+1）
                s.log("挂载未就绪但登录有效，尝试唤醒后台守护进程…")
                await Installer.ensureAgentRunning(state: s)
                var recovered = false
                for _ in 0..<60 {
                    // 用户开始了新部署 → 丢弃本次恢复结果，别踩新任务的状态
                    guard gen == s.deployGeneration, s.phase == .idle else { return }
                    if await Installer.isMountedHealthyAsync(), await Installer.serviceRunning() {
                        recovered = true
                        break
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                guard gen == s.deployGeneration else { return }
                if recovered {
                    s.mountOK = true
                    s.deployed = true
                    s.phase = .idle        // 走 readyView 常驻就绪页（不是「部署完成」一次性页）
                    s.log("后台守护已恢复：挂载 ✅ 服务 ✅")
                    return
                }
            }
            s.log("未检测到完整部署，自动开始一键部署")
            s.startDeploy()
        }
    }

    func startDeploy() {
        guard !uninstalling, phase == .idle || phase == .failed || phase == .qr else { return }
        // 取消旧任务（重新扫码场景）；用 generation 防止旧任务的 catch/defer 踩新任务的状态
        deployTask?.cancel()
        deployGeneration += 1
        let gen = deployGeneration
        fatalError = nil
        resetSteps()
        phase = .running
        deployTask = Task { await runAll(generation: gen) }
    }

    private func runAll(generation: Int) async {
        // 只有「仍是当前代」才清理/改写状态，旧任务晚到的结果一律丢弃
        defer { if generation == deployGeneration { deployTask = nil } }
        do {
            // 网络闸门：cookie 校验不通时绝不 takeover（那会卸载健康的挂载），直接中止
            let cs = await QuarkAuth.hasValidCookie()
            if cs == .networkError {
                log("⚠️ 网络不通，无法验证登录状态，已中止（现有挂载未动）。请联网后重试")
                phase = .idle
                return
            }
            await takeover()
            // 磁盘预检（下载前就要拦：组件 ~143MB，另留日常余量）
            let (freeOut, _) = await Installer.shAsync("df -m '$HOME/Library/Application Support' | awk 'NR==2{print $4}'")
            if let freeMB = Int(freeOut.trimmingCharacters(in: .whitespacesAndNewlines)), freeMB < 400 {
                throw InstallError(message: "磁盘空间不足（剩余 \(freeMB)MB，至少需要 400MB）")
            }
            // 并行预下载：macFUSE 安装需要管理员交互的这段时间里，组件已在后台下好
            let prefetch = Installer.prefetchAssets(state: self)
            let progressTask = prefetch.startProgress(state: self)
            defer { prefetch.cancelAll(); progressTask.cancel() }

            enterStep(0)
            try await Installer.ensureMacFUSE(state: self, prefetch: prefetch)
            finishStep(0)

            enterStep(1)
            try await Installer.deployComponents(state: self, prefetch: prefetch)
            finishStep(1)

            enterStep(2)
            try await Installer.startService(state: self)
            finishStep(2)

            enterStep(3)
            try await QuarkAuth.ensureCookie(state: self)   // 内部可能切到 .qr 相位
            finishStep(3)

            // 顺序要紧：先装好开机自启（守护进程是挂载的持有者），再挂载——
            // 否则全新部署时挂载落在 App 自己的 rclone 头上（App 退出/崩溃会带走它）
            enterStep(4)
            try await Installer.setupAutoStart(state: self)
            finishStep(4)

            enterStep(5)
            try await Installer.mount(state: self)
            finishStep(5)

            phase = .finished
            log("全部完成 ✅ 打开 Finder 左侧「Quark」即可访问网盘")
        } catch {
            // 已被新一轮部署取代（重新扫码）→ 静默退出，不改写新任务的状态
            guard generation == deployGeneration else { return }
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                phase = .idle
                log("已取消本次操作")
                return
            }
            let msg = (error as? InstallError)?.message ?? error.localizedDescription
            fatalError = msg
            phase = .failed
            log("失败：\(msg)")
        }
    }

    // MARK: 辅助动作

    func openFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Installer.mountPoint.path)
        NSWorkspace.shared.open(Installer.mountPoint)
    }

    func openLogs() {
        NSWorkspace.shared.selectFile(Installer.base.appendingPathComponent("mount.log").path, inFileViewerRootedAtPath: Installer.base.path)
        NSWorkspace.shared.open(Installer.base)
    }

    func openSecuritySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(u)
        }
    }

    func rescan() {
        qrImage = nil
        qrHint = ""
        if deployed, phase == .idle {
            // 已就绪时的「重新扫码」= 只刷新登录（换 cookie + 更新存储配置）。
            // v1.0.2 会走整包重部署：卸载健康挂载、进度条归零、数秒后才重新出二维码（名不副实）
            refreshLogin()
            return
        }
        // startDeploy 内部会取消旧任务并按新代际重启
        startDeploy()
    }

    /// 轻量刷新登录：扫码 → 换 cookie → 更新存储配置。不动挂载/组件/守护进程
    func refreshLogin() {
        guard !uninstalling, phase == .idle, refreshTask == nil else { return }
        phase = .qr
        log("刷新登录：请用夸克 APP 扫描新二维码")
        refreshTask = Task {
            do {
                try await QuarkAuth.refreshLogin(state: self)
                log("✅ 登录状态已刷新（挂载未动）")
            } catch {
                if error is CancellationError {
                    log("已取消刷新登录")
                } else {
                    let msg = (error as? InstallError)?.message ?? error.localizedDescription
                    fatalError = msg
                    log("刷新登录失败：\(msg)")
                }
            }
            qrImage = nil
            if phase == .qr { phase = .idle }
            refreshTask = nil
        }
    }

    func uninstall() {
        // 忙态 + 互斥：卸载进行中（数秒无反馈窗口）禁止再触发部署/重挂/检测——
        // v1.0.2 无此保护，用户连点「卸载」「重新部署」会并发互删对方刚建好的状态
        guard !uninstalling else { return }
        uninstalling = true
        deployTask?.cancel()
        remountTask?.cancel()
        refreshTask?.cancel()
        phase = .idle
        log("开始卸载：停止服务 → 卸载挂载 → 移除开机项 → 删除数据…")
        uninstallTask = Task { await Installer.uninstall(state: self) }
    }

    /// 重新挂载：唤醒后台守护进程等它挂（App 自己永不当挂载的主人）
    func remount() {
        guard !uninstalling, phase == .idle || phase == .finished else { return }
        guard remountTask == nil else { return }
        log("正在重新挂载（唤醒后台守护进程）…")
        remountTask = Task {
            await Installer.ensureAgentRunning(state: self)
            var ok = false
            for _ in 0..<60 {
                // 健康判定（条目 + 进程）：僵尸条目不算挂载成功
                if await Installer.isMountedHealthyAsync() { ok = true; break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if ok {
                mountOK = true
                // deployed 判定前重新校验 cookie——detect 时的 cookieValid 可能是数小时前的陈旧值
                let cs = await QuarkAuth.hasValidCookie()
                if cs == .networkError {
                    deployed = true   // 网络不通时保守保留，不误降级
                    log("✅ 已重新挂载到 ~/Quark（登录状态检查不通，未改动）")
                } else {
                    cookieValid = (cs == .valid)
                    deployed = await Installer.serviceRunning() && cookieValid
                    log("✅ 已重新挂载到 ~/Quark（后台守护持有，退出 App 不影响）")
                }
            } else {
                // 失败必须清脏状态：否则界面停在「一切就绪」而 Finder 打不开（v1.0.2 缺陷）
                mountOK = false
                deployed = false
                log("❌ 重新挂载失败。请查看 ~/Library/Application Support/QuarkMount/start-all.log")
            }
            remountTask = nil
        }
    }
}

// MARK: - 错误类型

struct InstallError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - App 入口

@main
struct QuarkMountApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 580, minHeight: 660)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 580, height: 660)
    }
}
