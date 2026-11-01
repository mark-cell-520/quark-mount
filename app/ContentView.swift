import SwiftUI

// MARK: - 主界面

struct ContentView: View {
    @StateObject private var state = AppState.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            steps
            Divider()
            content
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { state.checkExisting() }
        .sheet(isPresented: $state.showMacFuseHelp) {
            MacFuseHelpView()
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [.blue, .purple],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("夸克网盘")
                    .font(.system(size: 20, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                state.showMacFuseHelp = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 16))
            }
            .buttonStyle(.borderless)
            .help("macFUSE 开通指南")
            if state.phase == .checking {
                ProgressView().scaleEffect(0.6)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        switch state.phase {
        case .idle:      return state.deployed ? "已就绪 · 网盘已挂载到 ~/Quark" : "一键把夸克网盘变成 Mac 本地磁盘"
        case .checking:  return "正在检测当前状态…"
        case .running:   return "正在部署，请勿关闭窗口…"
        case .qr:        return "请用夸克 APP 扫码"
        case .finished:  return "部署完成"
        case .failed:    return "部署中断"
        }
    }

    // MARK: 步骤条

    private var steps: some View {
        HStack(spacing: 0) {
            ForEach(0..<state.stepTitles.count, id: \.self) { i in
                stepDot(i)
                if i < state.stepTitles.count - 1 {
                    Rectangle()
                        .fill(state.stepDone[i] ? Color.green.opacity(0.5) : Color.gray.opacity(0.25))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func stepDot(_ i: Int) -> some View {
        let active = (state.phase == .running || state.phase == .qr) && i == state.stepIndex
        return VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(state.stepDone[i] ? Color.green : (active ? Color.blue : Color.gray.opacity(0.25)))
                    .frame(width: 22, height: 22)
                if state.stepDone[i] {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                } else if active {
                    ProgressView().scaleEffect(0.45)
                } else {
                    Text("\(i + 1)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            Text(state.stepTitles[i])
                .font(.system(size: 9))
                .foregroundColor(state.stepDone[i] || active ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 64)
    }

    // MARK: 中部内容（按相位切换）

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .qr:
            qrView
        case .finished:
            doneView
        case .failed:
            failView
        case .idle where state.deployed:
            readyView
        default:
            progressView
        }
    }

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.phase == .running && !state.progressLabel.isEmpty {
                HStack {
                    Text(state.progressLabel).font(.system(size: 12))
                    Spacer()
                    Text("\(Int(state.progress * 100))%").font(.system(size: 12, weight: .medium))
                }
                ProgressView(value: state.progress)
            }
            logView
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(state.logs) { e in
                        HStack(alignment: .top, spacing: 6) {
                            Text(e.time)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text(e.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(e.text.contains("失败") || e.text.contains("错误") ? .red : .primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .id(e.id)
                    }
                }
                .padding(10)
            }
            // 新日志自动滚到底（长部署过程不用手动拉）。
            // 用 last?.id 而不是 count——logs 满 300 条后 count 不再变化，onChange 失效（v1.0.2 缺陷）
            .onChange(of: state.logs.last?.id) { _ in
                if let last = state.logs.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .cornerRadius(8)
        }
    }

    private var qrView: some View {
        VStack(spacing: 14) {
            Text("用夸克 APP 扫码登录")
                .font(.system(size: 15, weight: .semibold))
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white)
                    .frame(width: 240, height: 240)
                    .shadow(color: .black.opacity(0.15), radius: 8)
                if let img = state.qrImage {
                    Image(nsImage: img)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 210, height: 210)
                        .accessibilityLabel("登录二维码")
                } else {
                    ProgressView()
                        .accessibilityLabel("正在获取二维码")
                }
            }
            Text(state.qrHint)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            // 倒计时展示（v1.0.2 的 qrCountdown 是没有任何视图读取的死状态）
            if state.qrCountdown > 0 {
                Text("二维码 \(state.qrCountdown) 秒后过期")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 10) {
                Button("重新获取二维码") { state.rescan() }
                    .disabled(state.phase != .qr)
                if !state.macfuseReady {
                    Button("打开系统设置") { state.openSecuritySettings() }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var readyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundColor(.green)
                .accessibilityHidden(true)
            Text("一切就绪")
                .font(.system(size: 17, weight: .semibold))
            Text("夸克网盘已挂载在 ~/Quark\n后台守护持有：退出 App 不影响，开机自动挂载，掉线自动恢复")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("打开网盘") { state.openFinder() }
                Button("重新挂载") { state.remount() }
                    .disabled(state.remountTask != nil)
                Button("打开日志") { state.openLogs() }
                // 已就绪的「重新扫码」= 轻量刷新登录（v1.0.2 会整包重部署+拆挂载）
                Button("重新扫码") { state.refreshLogin() }
                    .disabled(state.refreshTask != nil)
                Button("卸载", role: .destructive) { state.uninstall() }
                    .disabled(state.uninstalling)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var doneView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundColor(.green)
                .accessibilityHidden(true)
            Text("部署完成")
                .font(.system(size: 17, weight: .semibold))
            Text("夸克网盘已挂载在 ~/Quark，Finder 左侧可直接访问\n开机自动挂载，掉线自动恢复")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            // v1.0.2 此页只有「打开网盘」，卸载/重扫只能关窗重开——补齐管理入口
            HStack(spacing: 10) {
                Button("打开网盘") { state.openFinder() }
                    .controlSize(.large)
                Button("打开日志") { state.openLogs() }
                Button("重新扫码") { state.refreshLogin() }
                    .disabled(state.refreshTask != nil)
                Button("卸载", role: .destructive) { state.uninstall() }
                    .disabled(state.uninstalling)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var failView: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundColor(.orange)
            Text(state.fatalError ?? "未知错误")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            HStack(spacing: 10) {
                Button("重试") { state.startDeploy() }
                if !state.macfuseReady {
                    Button("打开系统设置") { state.openSecuritySettings() }
                }
            }
            logView
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 底部按钮

    private var footer: some View {
        HStack {
            Text(state.deployed && state.phase == .idle ? "" : statusText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Text("v\(AppState.appVersion)")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.7))
            switch state.phase {
            case .idle, .failed:
                if state.deployed {
                    // 已就绪时「重新部署」会卸载健康挂载：去掉 Return 默认键 + 二次确认
                    // （v1.0.2 误按回车就拆盘，无确认）
                    Button("重新部署") { confirmRedeploy() }
                        .controlSize(.large)
                        .disabled(state.uninstalling)
                } else {
                    Button("开始部署") { state.startDeploy() }
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(state.uninstalling)
                }
            case .checking:
                Button("开始部署") { state.startDeploy() }.disabled(true)
            case .running:
                Button("部署中…") {}.disabled(true)
            case .qr:
                Button("等待扫码…") {}.disabled(true)
            case .finished:
                Button("完成") { closeWindow() }
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var statusText: String {
        switch state.phase {
        case .running: return state.progressLabel.isEmpty ? "部署进行中…" : state.progressLabel
        case .qr: return "等待扫码"
        default: return ""
        }
    }

    // MARK: 辅助

    /// 重新部署确认：会卸载当前挂载并重走全流程
    private func confirmRedeploy() {
        let alert = NSAlert()
        alert.messageText = "重新部署会卸载当前挂载"
        alert.informativeText = "后台守护会重新拉起草挂载，正在上传/下载中的文件会中断，登录状态需要重新确认。确定继续吗？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重新部署")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            state.startDeploy()
        }
    }

    /// 关闭窗口：keyWindow 在 App 失活时为 nil（v1.0.2 死按钮）——回退到可见窗口
    private func closeWindow() {
        if let w = NSApplication.shared.keyWindow { w.close(); return }
        if let w = NSApplication.shared.windows.first(where: { $0.canBecomeKey && $0.isVisible }) { w.close(); return }
        NSApplication.shared.windows.last?.close()
    }
}

// MARK: - macFUSE 开通指南（App 内嵌，用户点右上角 ⓘ 随时查看）

struct MacFuseHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("macFUSE 开通指南")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding(16)
            Divider()
            TabView(selection: $page) {
                stepPage(
                    title: "① 为什么需要它",
                    lines: [
                        "macOS 只支持苹果自己的文件系统。",
                        "要把「网盘」像本地磁盘一样挂载，",
                        "必须有一个第三方文件系统驱动。",
                        "",
                        "macFUSE 就是这个驱动，它以「内核扩展」",
                        "形式运行在系统最底层。",
                    ]).tag(0)
                stepPage(
                    title: "② Apple 强制人工批准",
                    lines: [
                        "正因为它运行在内核态，Apple 要求：",
                        "第三方内核扩展必须由用户本人",
                        "在系统设置里明确批准才会加载。",
                        "",
                        "没批准 = 驱动没运行 = 挂载必然失败。",
                        "任何软件都无法代劳这一步。",
                    ]).tag(1)
                stepPage(
                    title: "③ 开通步骤（90 秒）",
                    lines: [
                        "1. App 自动安装 macFUSE 后，打开：",
                        "    系统设置 → 隐私与安全性",
                        "",
                        "2. 找到「安全性」区域，点击：",
                        "    「来自开发者 Benjamin Fleischer 的",
                        "     系统软件…」旁的【允许】",
                        "",
                        "3. 输入密码确认，无需重启。",
                        "   App 会自动检测并继续。",
                    ]).tag(2)
                stepPage(
                    title: "④ 按钮没出现？",
                    lines: [
                        "「允许」按钮只在安装后 30 分钟内有效，",
                        "过期就消失了。两种办法找回：",
                        "",
                        "A. 终端运行（本 App 也会自动做）：",
                        "   /Library/Filesystems/macfuse.fs/",
                        "   Contents/Resources/load_macfuse",
                        "",
                        "B. 重启 Mac，登录后再去看",
                        "   系统设置 → 隐私与安全性。",
                    ]).tag(3)
                stepPage(
                    title: "⑤ 验证是否成功",
                    lines: [
                        "终端运行：",
                        "",
                        "   kextstat | grep -i fuse",
                        "",
                        "看到 io.macfuse.filesystems.macfuse",
                        "开头的输出 = 驱动已加载，大功告成。",
                        "",
                        "App 的部署流程也会自动检测这一步。",
                    ]).tag(4)
            }
            .tabViewStyle(.automatic)
            .padding(.bottom, 12)
            HStack {
                Button("上一页") { withAnimation { page = max(0, page - 1) } }
                    .disabled(page == 0)
                Spacer()
                Text("\(page + 1) / 5")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                if page < 4 {
                    Button("下一页") { withAnimation { page = min(4, page + 1) } }
                } else {
                    Button("打开系统设置") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
                            NSWorkspace.shared.open(u)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(width: 460, height: 380)
    }

    private func stepPage(title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .padding(.bottom, 6)
            ForEach(lines.indices, id: \.self) { i in
                Text(lines[i])
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(lines[i].hasPrefix("   ") ? .secondary : .primary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }
}
