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

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    func log(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        logs.append(LogEntry(time: f.string(from: Date()), text: s))
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
        if Installer.isMounted() {
            log("卸载现有挂载（交由本应用管理）…")
            // 先优雅卸载（让 rclone 自行退出），失败才强卸载（强卸载可能使进程卡死占住目录）
            _ = await Installer.shAsync("diskutil unmount '\(Installer.mountPoint.path)' >/dev/null 2>&1 || umount '\(Installer.mountPoint.path)' >/dev/null 2>&1 || true")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Installer.isMounted() {
                _ = await Installer.shAsync("diskutil unmount force '\(Installer.mountPoint.path)' >/dev/null 2>&1 || umount -f '\(Installer.mountPoint.path)' >/dev/null 2>&1 || true")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        // daemon 化后 argv 只剩 "rclone"，按进程名精确杀（-f 模式匹配不到）
        _ = await Installer.shAsync("pkill -x rclone 2>/dev/null || true")
        // 停掉非本应用的 openlist（旧版手动部署），保留本应用的
        _ = await Installer.shAsync("""
            for p in $(pgrep -f 'openlist server' 2>/dev/null); do
              if ! ps -p $p -o command= 2>/dev/null | grep -q 'Application Support/QuarkMount'; then kill $p 2>/dev/null; fi
            done
            """)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    // MARK: 入口

    func checkExisting() {
        // 防重入：部署中/扫码中不重复检测（多窗口 onAppear 会并发触发）
        guard phase == .idle || phase == .checking || phase == .finished || phase == .failed else { return }
        phase = .checking
        Task { await Self.detect() }
    }

    static func detect() async {
        let s = AppState.shared
        // 检测期间状态被别处改动（用户点了开始/另一窗口）则放弃本次结果
        guard s.phase == .checking else { return }
        s.macfuseReady = await Installer.isMacFuseReady()
        s.mountOK = Installer.isMounted()
        let cookieState = await QuarkAuth.hasValidCookie()
        s.cookieValid = (cookieState == .valid)
        let svc = await Installer.serviceRunning()
        s.deployed = s.mountOK && svc && s.cookieValid
        guard s.phase == .checking else { return }
        if cookieState == .networkError {
            // 网络抖动 ≠ 未部署：绝不能据此走自动部署（takeover 会卸载正常挂载）
            s.phase = .idle
            s.log("⚠️ 登录状态检查失败（网络不通），已保留现状。请联网后重试")
            return
        }
        s.log("检测完成：macFUSE \(s.macfuseReady ? "就绪" : "未就绪")，服务 \(svc ? "运行中" : "未运行")，挂载 \(s.mountOK ? "正常" : "未挂载")，登录 \(s.cookieValid ? "有效" : "无效")")
        s.phase = .idle
        // 未部署则自动开始（一键体验：打开即用）
        if !s.deployed {
            s.log("未检测到完整部署，自动开始一键部署")
            s.startDeploy()
        }
    }

    func startDeploy() {
        // 防重入：已有部署任务在跑则忽略
        guard phase == .idle || phase == .failed || phase == .qr else { return }
        guard deployTask == nil else { return }
        fatalError = nil
        resetSteps()
        phase = .running
        deployTask = Task { await runAll() }
    }

    private func runAll() async {
        defer { deployTask = nil }   // 收尾必清，允许下次部署
        do {
            await takeover()
            enterStep(0)
            try await Installer.ensureMacFUSE(state: self)
            finishStep(0)

            enterStep(1)
            try await Installer.deployComponents(state: self)
            finishStep(1)

            enterStep(2)
            try await Installer.startService(state: self)
            finishStep(2)

            enterStep(3)
            try await QuarkAuth.ensureCookie(state: self)   // 内部可能切到 .qr 相位
            finishStep(3)

            enterStep(4)
            try await Installer.mount(state: self)
            finishStep(4)

            enterStep(5)
            try await Installer.setupAutoStart(state: self)
            finishStep(5)

            phase = .finished
            log("全部完成 ✅ 打开 Finder 左侧「Quark」即可访问网盘")
        } catch let e as InstallError {
            fatalError = e.message
            phase = .failed
            log("失败：\(e.message)")
        } catch {
            fatalError = error.localizedDescription
            phase = .failed
            log("失败：\(error.localizedDescription)")
        }
    }

    // MARK: 辅助动作

    func openFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Installer.mountPoint.path)
        NSWorkspace.shared.open(Installer.mountPoint)
    }

    func openSecuritySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(u)
        }
    }

    func rescan() {
        qrImage = nil
        qrHint = ""
        startDeploy()
    }

    func uninstall() {
        Task { await Installer.uninstall(state: self) }
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
