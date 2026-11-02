import Foundation
import AppKit

// MARK: - 安装引擎：所有部署逻辑

@MainActor
final class Installer {
    static let fm = FileManager.default
    static let home = fm.homeDirectoryForCurrentUser
    static let base = home.appendingPathComponent("Library/Application Support/QuarkMount")
    static let binDir = base.appendingPathComponent("bin")
    static let dataDir = base.appendingPathComponent("data")
    static let mountPoint = home.appendingPathComponent("Quark")
    static let legacyDir = home.appendingPathComponent("quark-mount")
    static let cookieFile = base.appendingPathComponent(".quark-cookie")
    static let passFile = base.appendingPathComponent(".admin-pass")
    static let rcloneConf = base.appendingPathComponent("rclone.conf")
    static let openlistBin = binDir.appendingPathComponent("openlist")
    static let rcloneBin = binDir.appendingPathComponent("rclone")
    static let port = 5244
    static let launchLabel = "com.quark.mount"
    static var retainedProcess: Process?   // 保活 OpenList 子进程引用

    // 组件清单（版本锁定 + 官方 SHA256 锁定；校验和不匹配即拒绝安装）
    struct Asset {
        let name: String          // arm64 文件名（amd64 时自动替换）
        let repo: String
        let tag: String
        let expectMB: Double
        let sha256: String        // 官方发布文件的 SHA256（小写十六进制）
    }

    /// 当前机器架构：arm64 / amd64
    static var arch: String {
        var size: Int = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        let m = String(cString: machine)
        return m.contains("arm64") ? "arm64" : "amd64"
    }

    /// 按架构取资产（Intel 用 amd64 包）
    static func assetFor(_ key: String) -> Asset? {
        guard var a = assets[key] else { return nil }
        if arch == "amd64" {
            if let a2 = assetsAmd64[key] {
                a = a2   // amd64 变体（openlist/rclone，官方哈希已锁定）
            } else {
                // 无 amd64 变体的组件（macFUSE dmg 与架构无关）——必须保留原资产的官方哈希，
                // v1.0.2 在这里把 sha256 清空 → Intel 机三个组件全部零哈希校验（AUDIT HIGH-5）
                a = Asset(name: a.name.replacingOccurrences(of: "arm64", with: "amd64"),
                          repo: a.repo, tag: a.tag, expectMB: a.expectMB, sha256: a.sha256)
            }
        }
        return a
    }

    static let assets: [String: Asset] = [
        "openlist": Asset(name: "openlist-darwin-arm64.tar.gz", repo: "OpenListTeam/OpenList", tag: "v4.2.9", expectMB: 52, sha256: "dac3b46e96f18ec3a06824fbac660d3e23c8a96f0aa40bc2bf2c5fde5b1eaecf"),
        "rclone":   Asset(name: "rclone-v1.75.2-osx-arm64.zip",  repo: "rclone/rclone",           tag: "v1.75.2", expectMB: 34, sha256: "610ab7d48615135dfc60b763858b11a426a0d3d1160c1bb76fb0ae6011b02edd"),
        "macfuse":  Asset(name: "macfuse-5.5.0.dmg",             repo: "macfuse/macfuse",          tag: "macfuse-5.5.0", expectMB: 23, sha256: "92c21ef2db4199bcf5bddc8e6efb57b23ecb9715f74ab38cba2c77ab226d3830"),
    ]
    static let assetsAmd64: [String: Asset] = [
        "openlist": Asset(name: "openlist-darwin-amd64.tar.gz", repo: "OpenListTeam/OpenList", tag: "v4.2.9", expectMB: 52, sha256: "2822e7d63855deacc7b816171ca14aaae59fec97c955d7d4258eedbfe4b881"),
        "rclone":   Asset(name: "rclone-v1.75.2-osx-amd64.zip",  repo: "rclone/rclone",           tag: "v1.75.2", expectMB: 34, sha256: "574e1f31cf1c464e5fb0325cb66fcbdeaf1efa1802bd9b17f13c256fd74b6561"),
    ]
    static let mirrors = ["https://gh-proxy.com/", "https://ghfast.top/", ""]

    // MARK: shell

    static func sh(_ cmd: String) -> (String, Int32) {
        let p = Process()
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", cmd]
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"]
        do { try p.run() } catch { return ("", -1) }
        // 必须先读管道再等退出：子进程输出超过 64KB 内核缓冲会阻塞在写端永不退出，
        // 先 waitUntilExit 再读 = 永久挂起（主线程调用即 UI 冻死）
        var data = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        p.waitUntilExit()
        _ = group.wait(timeout: .now() + 30)
        return (String(decoding: data, as: UTF8.self), p.terminationStatus)
    }

    /// 异步执行 shell（不阻塞 UI 线程）
    static func shAsync(_ cmd: String) async -> (String, Int32) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: sh(cmd))
            }
        }
    }

    static func shOK(_ cmd: String) async -> Bool {
        await shAsync(cmd).1 == 0
    }

    /// 挂载专用运行器：输出走日志文件而非管道。
    /// --daemon 的子进程会继承管道写端，用 sh() 的 readDataToEndOfFile 会永久阻塞。
    static func runMount(_ args: [String], logFile: URL) async -> (String, Int32) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = rcloneBin
                p.arguments = args
                p.standardInput = FileHandle.nullDevice
                if !FileManager.default.fileExists(atPath: logFile.path) {
                    FileManager.default.createFile(atPath: logFile.path, contents: Data())
                }
                if let h = try? FileHandle(forWritingTo: logFile) {
                    try? h.seekToEnd()
                    p.standardOutput = h
                    p.standardError = h
                }
                do {
                    try p.run()
                    p.waitUntilExit()   // --daemon 父进程就绪后即退出
                    cont.resume(returning: ("", p.terminationStatus))
                } catch {
                    cont.resume(returning: (error.localizedDescription, -1))
                }
            }
        }
    }

    static func mkdirs(_ url: URL) {
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func randomPassword(_ n: Int = 20) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<n).compactMap { _ in chars.randomElement() })
    }

    // MARK: Step 0: macFUSE

    static func isMacFuseReady() async -> Bool {
        let (out, _) = await shAsync("pkgutil --pkgs 2>/dev/null | grep -c io.macfuse")
        let installed = out.trimmingCharacters(in: .whitespacesAndNewlines) != "0"
        let loaded = await shAsync("kextstat 2>/dev/null | grep -q macfuse").1 == 0
        return installed && loaded
    }

    static func ensureMacFUSE(state: AppState, prefetch: Prefetch? = nil) async throws {
        if await isMacFuseReady() {
            state.log("macFUSE 已安装且驱动已加载")
            return
        }
        let (pkgOut, _) = await shAsync("pkgutil --pkgs 2>/dev/null | grep -c io.macfuse")
        let installed = pkgOut.trimmingCharacters(in: .whitespacesAndNewlines) != "0"

        if !installed {
            state.log("未检测到 macFUSE，开始下载安装包…")
            guard let a = assetFor("macfuse") else { throw InstallError(message: "组件清单缺失") }
            // 优先用预下载结果（与组件并行下好的），没有再现场下载
            let dmg: URL
            if let pre = try? await prefetch?.result(a.name) { dmg = pre }
            else { dmg = try await download(a, state: state) }
            state.log("挂载 dmg…")
            // 快照对比定位本次挂载的卷：glob + head -1 会选到陈旧 macFUSE 卷（用旧 pkg 重装旧版），
            // attach 后卷尚未出现时又会把竞态误报成「包损坏」
            let before = Set((try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? [])
            let (_, code) = await shAsync("hdiutil attach -nobrowse -quiet '\(dmg.path)'")
            guard code == 0 else { throw InstallError(message: "dmg 挂载失败") }
            var vol = ""
            for _ in 0..<10 {
                let now = (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? []
                if let v = now.first(where: { !before.contains($0) && $0.lowercased().contains("macfuse") }) {
                    vol = "/Volumes/\(v)"
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !vol.isEmpty else {
                _ = await shAsync("hdiutil detach -quiet '\(dmg.path)' 2>/dev/null")
                throw InstallError(message: "dmg 挂载后未找到卷（安装包可能损坏，请重试）")
            }
            let pkg = await shAsync("find '\(vol)' -maxdepth 2 -name '*.pkg' 2>/dev/null | head -1").0
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pkg.isEmpty else {
                _ = await shAsync("hdiutil detach -quiet '\(vol)'")
                throw InstallError(message: "dmg 中未找到 pkg")
            }
            state.log("安装 macFUSE（需要你在弹出框输入密码）…")
            let src = "do shell script \"installer -pkg '\(pkg)' -target /\" with administrator privileges"
            var err: NSDictionary?
            // 授权对话框可能持续数分钟：放后台队列执行，避免阻塞 UI 线程
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    NSAppleScript(source: src)?.executeAndReturnError(&err)
                    cont.resume()
                }
            }
            _ = await shAsync("hdiutil detach -quiet '\(vol)'")
            if err != nil {
                throw InstallError(message: "macFUSE 安装失败：\(err?["NSAppleScriptErrorNumber"] ?? "未知")")
            }
            state.log("macFUSE 安装完成")
        } else {
            state.log("macFUSE 已安装，驱动未加载")
        }

        // 尝试加载 kext
        _ = await shAsync("/Library/Filesystems/macfuse.fs/Contents/Resources/load_macfuse")
        if await shAsync("kextstat 2>/dev/null | grep -q macfuse").1 == 0 {
            state.log("内核驱动已加载")
            return
        }
        // 等待用户批准
        state.log("请在「系统设置 → 隐私与安全性」中点击 macFUSE 旁的「允许」（本窗口会自动检测，最多等 5 分钟）")
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            if await shAsync("kextstat 2>/dev/null | grep -q macfuse").1 == 0 {
                state.log("内核驱动已加载 ✅")
                return
            }
        }
        throw InstallError(message: "macFUSE 驱动未获得批准（请在系统设置→隐私与安全性点允许后重试）")
    }

    // MARK: Step 1: 部署组件

    static func deployComponents(state: AppState, prefetch: Prefetch? = nil) async throws {
        mkdirs(binDir)
        mkdirs(dataDir)
        mkdirs(mountPoint)

        // 预检：磁盘空间（组件 ~110MB + VFS 写缓存上限之外的日常占用，留 400MB 余量）
        // 注意：路径必须内联展开——单引号里的 $HOME 不会展开，df 直接报错，闸门永远是死代码（v1.0.2 实测）
        let (freeOut, _) = await shAsync("df -m \"\(home.path)/Library/Application Support\" | awk 'NR==2{print $4}'")
        if let freeMB = Int(freeOut.trimmingCharacters(in: .whitespacesAndNewlines)), freeMB < 400 {
            throw InstallError(message: "磁盘空间不足（剩余 \(freeMB)MB，至少需要 400MB）")
        }

        // openlist
        if !fm.fileExists(atPath: openlistBin.path) {
            var imported = false
            let legacy = legacyDir.appendingPathComponent("openlist")
            if fm.fileExists(atPath: legacy.path) {
                state.log("从旧部署导入 openlist…")
                do {
                    try fm.copyItem(at: legacy, to: openlistBin)
                    imported = true
                } catch {
                    // 导入失败（损坏/权限/跨卷）不能当作成功——清理后回退到下载
                    state.log("导入失败（\(error.localizedDescription)），改为下载…")
                    try? fm.removeItem(at: openlistBin)
                }
            }
            if !imported {
                state.log("下载 OpenList 组件（\(arch)）…")
                let tar: URL
                if let pre = try? await prefetch?.result(assetFor("openlist")!.name) { tar = pre }
                else { tar = try await download(assetFor("openlist")!, state: state) }
                _ = await shAsync("tar xzf '\(tar.path)' -C '\(base.path)' && mv -f '\(base.path)/openlist' '\(openlistBin.path)'")
            }
        }
        guard fm.fileExists(atPath: openlistBin.path) else { throw InstallError(message: "OpenList 部署失败") }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: openlistBin.path)
        // 导入/解压后的二进制必须真能跑（防止坏包进入后续流程）
        guard await shAsync("'\(openlistBin.path)' version").1 == 0 else {
            try? fm.removeItem(at: openlistBin)
            throw InstallError(message: "OpenList 二进制无法运行，已清理。请重新部署")
        }

        // rclone
        if !fm.fileExists(atPath: rcloneBin.path) {
            var imported = false
            let legacy = legacyDir.appendingPathComponent("rclone-v1.75.2-osx-\(arch)/rclone")
            if fm.fileExists(atPath: legacy.path) {
                state.log("从旧部署导入 rclone…")
                do {
                    try fm.copyItem(at: legacy, to: rcloneBin)
                    imported = true
                } catch {
                    state.log("导入失败（\(error.localizedDescription)），改为下载…")
                    try? fm.removeItem(at: rcloneBin)
                }
            }
            if !imported {
                state.log("下载 rclone 组件（\(arch)）…")
                let zip: URL
                if let pre = try? await prefetch?.result(assetFor("rclone")!.name) { zip = pre }
                else { zip = try await download(assetFor("rclone")!, state: state) }
                _ = await shAsync("cd '\(base.path)' && unzip -o -q '\(zip.path)' && mv -f '\(base.path)/rclone-v1.75.2-osx-\(arch)/rclone' '\(rcloneBin.path)' && rm -rf '\(base.path)/rclone-v1.75.2-osx-\(arch)'")
            }
        }
        guard fm.fileExists(atPath: rcloneBin.path) else { throw InstallError(message: "rclone 部署失败") }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rcloneBin.path)
        guard await shAsync("'\(rcloneBin.path)' version").1 == 0 else {
            try? fm.removeItem(at: rcloneBin)
            throw InstallError(message: "rclone 二进制无法运行，已清理。请重新部署")
        }
        state.log("组件就绪：OpenList + rclone（\(arch)）")
        // 清理下载缓存：安装包解压/导入后即无用，v1.0.2 实测残留 82MB 常驻（资源占用）
        let dlDir = base.appendingPathComponent("downloads")
        if let files = try? fm.contentsOfDirectory(at: dlDir, includingPropertiesForKeys: nil) {
            var freed = 0
            for f in files {
                let sz = (try? fm.attributesOfItem(atPath: f.path)[.size] as? UInt64) ?? 0
                if (try? fm.removeItem(at: f)) != nil { freed += Int(sz) }
            }
            if freed > 0 { state.log("已清理安装包缓存（释放 \(freed / 1_048_576)MB）") }
        }
    }

    // MARK: 下载（多镜像 + 进度 + 完整性校验）

    @discardableResult
    static func download(_ a: Asset, state: AppState, quiet: Bool = false) async throws -> URL {
        let tmp = base.appendingPathComponent("downloads")
        mkdirs(tmp)
        let dest = tmp.appendingPathComponent(a.name)
        // 分片策略：接近下完的视为可疑整文件删掉，未下完的保留供断点续传
        // （v1.0.2 无脑 removeItem → 52MB 包断线即从零重下，AUDIT 声称的 -C - 实际不存在）
        if let sz = try? fm.attributesOfItem(atPath: dest.path)[.size] as? UInt64,
           Double(sz) >= a.expectMB * 1_048_576 * 0.95 {
            try? fm.removeItem(at: dest)
        }
        let expected = a.expectMB * 1_048_576
        var lastErr = "未知错误"

        for (i, mirror) in mirrors.enumerated() {
            let url = mirror + "https://github.com/\(a.repo)/releases/download/\(a.tag)/\(a.name)"
            if !quiet {
                state.progressLabel = "下载 \(a.name)（源\(i + 1)/\(mirrors.count)）"
                state.progress = 0
            }
            guard await curl(url: url, dest: dest, expected: expected, state: state, quiet: quiet, resume: true) else {
                lastErr = "下载中断"
                state.log("镜像 \(i + 1) 下载失败，尝试下一个…")
                continue
            }
            // 1) 体积下限（防截断：不得低于期望的 60%）
            let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? UInt64) ?? 0
            if Double(size) < expected * 0.6 {
                lastErr = "文件不完整（\(size / 1_048_576)MB / 期望约 \(Int(a.expectMB))MB）"
                state.log("镜像 \(i + 1) 文件不完整，尝试下一个…")
                continue
            }
            // 2) SHA256 校验（锁定官方发布值；不匹配 = 拒绝安装，切换镜像）
            if !a.sha256.isEmpty {
                let (sum, code) = await shAsync("shasum -a 256 '\(dest.path)' | awk '{print $1}'")
                let got = sum.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if code != 0 || got != a.sha256.lowercased() {
                    lastErr = "SHA256 校验失败"
                    state.log("⚠️ 镜像 \(i + 1) 文件校验和不匹配（可能被篡改或损坏），已拒绝并切换源")
                    try? fm.removeItem(at: dest)   // 毒文件绝不能给下一镜像续传
                    continue
                }
                state.log("SHA256 校验通过 ✅")
            }
            // 3) 归档完整性（能完整列出条目才算好包）
            let testCmd: String
            if a.name.hasSuffix(".tar.gz") { testCmd = "tar tzf '\(dest.path)' > /dev/null" }
            else if a.name.hasSuffix(".zip") { testCmd = "unzip -t '\(dest.path)' > /dev/null" }
            else if a.name.hasSuffix(".dmg") { testCmd = "hdiutil imageinfo '\(dest.path)' > /dev/null" }
            else { testCmd = "true" }
            if await shAsync(testCmd).1 != 0 {
                lastErr = "归档损坏"
                state.log("镜像 \(i + 1) 的归档损坏，尝试下一个…")
                try? fm.removeItem(at: dest)   // 坏包同样不能续传
                continue
            }
            if !quiet { state.progress = 1 }
            return dest
        }
        // 全镜像失败：保留分片（下次重试可续传），整文件可疑已在上面删过
        throw InstallError(message: "组件下载失败：\(a.name)（\(lastErr)。请检查网络后重试）")
    }

    // MARK: 预下载（安装流程并行化）

    /// 部署一开始就并行下载所有缺失组件：带宽复用好，安装耗时从各组件「总和」降为「最大值」。
    /// 各组件独立 Task 互不拖累；只有取用（await）时才抛错，失败组件的镜像重试在 Task 内完成。
    final class Prefetch {
        fileprivate let tasks: [String: Task<URL, Error>]
        private let names: [String]
        private let expects: [String: Double]
        private let totalExpected: Double
        private let tmpDir: URL

        init(tasks: [String: Task<URL, Error>], names: [String], expects: [String: Double], totalExpected: Double, tmpDir: URL) {
            self.tasks = tasks
            self.names = names
            self.expects = expects
            self.totalExpected = totalExpected
            self.tmpDir = tmpDir
        }

        func cancelAll() { for t in tasks.values { t.cancel() } }

        /// 取某个组件的下载结果；未安排下载（已存在/可导入）返回 nil，调用方走原有路径
        func result(_ name: String) async throws -> URL? {
            guard let t = tasks[name] else { return nil }
            return try await t.value
        }

        /// 聚合进度轮询：各文件已下载字节合计 / 总期望（并发下载时单一进度条不 flicker），下完即停
        func startProgress(state: AppState) -> Task<Void, Never> {
            Task.detached { [weak state] in
                while !Task.isCancelled {
                    var done = 0.0
                    for n in self.names {
                        let sz = (try? FileManager.default.attributesOfItem(atPath: self.tmpDir.appendingPathComponent(n).path)[.size] as? UInt64) ?? 0
                        let exp = self.expects[n] ?? 0
                        done += Double(min(sz, UInt64(exp)))
                    }
                    let frac = self.totalExpected > 0 ? min(1, done / self.totalExpected) : 1
                    await MainActor.run { state?.progress = frac }
                    if self.totalExpected > 0, done >= self.totalExpected { break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
    }

    /// 判断哪些组件缺失并立即启动并行下载（组件已存在/可从旧部署导入的不下载）
    static func prefetchAssets(state: AppState) -> Prefetch {
        let tmp = base.appendingPathComponent("downloads")
        mkdirs(tmp)
        var tasks: [String: Task<URL, Error>] = [:]
        var names: [String] = []
        var expects: [String: Double] = [:]
        var total = 0.0

        func schedule(_ key: String, _ binExists: Bool, _ legacyExists: Bool) {
            guard !binExists, !legacyExists, let a = assetFor(key) else { return }
            names.append(a.name)
            expects[a.name] = a.expectMB * 1_048_576
            total += a.expectMB * 1_048_576
            tasks[a.name] = Task { try await download(a, state: state, quiet: true) }
        }
        schedule("openlist", fm.fileExists(atPath: openlistBin.path),
                 fm.fileExists(atPath: legacyDir.appendingPathComponent("openlist").path))
        schedule("rclone", fm.fileExists(atPath: rcloneBin.path),
                 fm.fileExists(atPath: legacyDir.appendingPathComponent("rclone-v1.75.2-osx-\(arch)/rclone").path))
        // macFUSE：仅未安装（文件系统 bundle 不存在）时才需要 dmg
        if !fm.fileExists(atPath: "/Library/Filesystems/macfuse.fs"), let a = assetFor("macfuse") {
            names.append(a.name)
            expects[a.name] = a.expectMB * 1_048_576
            total += a.expectMB * 1_048_576
            tasks[a.name] = Task { try await download(a, state: state, quiet: true) }
        }
        if !names.isEmpty {
            let mb = Int(total / 1_048_576)
            state.log("开始并行下载 \(names.count) 个组件（共约 \(mb)MB，可同时进行）…")
        }
        return Prefetch(tasks: tasks, names: names, expects: expects, totalExpected: total, tmpDir: tmp)
    }

    private static func curl(url: String, dest: URL, expected: Double, state: AppState, quiet: Bool = false, resume: Bool = false) async -> Bool {
        // 进程句柄盒：取消时能 terminate 掉 curl（v1.0.2 取消部署后 curl 仍在后台下满 15 分钟）
        final class Box { var p: Process?; func terminate() { p?.terminate() } }
        let box = Box()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                    var args = ["-sL", "--fail", "--connect-timeout", "15", "--max-time", "900"]
                    // 断点续传：分片存在且未下完时 -C -（v1.0.2 声称已加实际没有；换镜像同文件字节序一致，SHA256 兜底）
                    if resume, let sz = try? fm.attributesOfItem(atPath: dest.path)[.size] as? UInt64,
                       sz > 0, Double(sz) < expected * 0.95 {
                        args += ["-C", "-"]
                    }
                    args += ["-o", dest.path, url]
                    p.arguments = args
                    p.standardOutput = FileHandle.nullDevice
                    p.standardError = FileHandle.nullDevice
                    p.terminationHandler = { _ in cont.resume(returning: p.terminationStatus == 0) }
                    box.p = p
                    do { try p.run() } catch { cont.resume(returning: false); return }
                    // 进度轮询
                    Task.detached {
                        while true {
                            let sz = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? UInt64) ?? 0
                            let frac = min(1, Double(sz) / max(expected, 1))
                            if !quiet { await MainActor.run { state.progress = frac } }
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            if !p.isRunning { break }
                        }
                    }
                }
            }
        }, onCancel: { box.terminate() })
    }

    // MARK: Step 2: 启动服务 + 账号权限

    static func serviceRunning() async -> Bool {
        // --fail：5xx/4xx 视为异常（服务活着但内部错误时不能当就绪）
        await shAsync("curl -s --fail -o /dev/null --max-time 3 http://127.0.0.1:\(port)/").1 == 0
    }

    /// 启动 OpenList 子进程（持有 Process 引用防释放；FileHandle 不能 close——run() 时要 dup 这个 fd）
    static func launchOpenList(pass: String) throws {
        let p = Process()
        p.executableURL = openlistBin
        p.arguments = ["server"]
        p.currentDirectoryURL = base
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                         "OPENLIST_ADMIN_PASSWORD": pass]
        let logURL = base.appendingPathComponent("openlist.log")
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: Data())
        }
        if let h = try? FileHandle(forWritingTo: logURL) {
            try? h.seekToEnd()
            p.standardOutput = h
            p.standardError = h
        }
        try p.run()
        Installer.retainedProcess = p
    }

    /// 轮询等待服务端口就绪（默认 30s）
    static func waitForService(_ seconds: Int = 30) async -> Bool {
        for _ in 0..<seconds {
            if await serviceRunning() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    static func startService(state: AppState) async throws {
        // 只清理「占着本应用端口(5244)的非本应用 openlist」——用户自用的其他 openlist 实例
        // （不同数据目录/端口）不误杀（v1.0.2 无条件杀全部 'openlist server'，误杀面大且无提示）
        if await shAsync("curl -s -o /dev/null --max-time 2 http://127.0.0.1:\(port)/").1 == 0 {
            let killed = await shAsync("""
                for p in $(pgrep -f 'openlist server' 2>/dev/null); do
                  if ! ps -p $p -o command= 2>/dev/null | grep -q 'Application Support/QuarkMount'; then kill $p 2>/dev/null; echo $p; fi
                done
                """)
            if !killed.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state.log("端口 \(port) 被其他 OpenList 实例占用，已停止（pid \(killed.0.trimmingCharacters(in: .whitespacesAndNewlines))）")
            }
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // 写配置（仅本机监听 + 绝对路径）——每次启动都检查并纠正，不是「仅不存在才写」：
        // 旧版静默失败落盘的 0.0.0.0 配置、用户手动跑过的 openlist 都会让管理界面暴露到局域网
        let conf = dataDir.appendingPathComponent("config.json")
        let json = """
        {
          "scheme": { "address": "127.0.0.1", "http_port": 5244, "https_port": -1, "force_https": false },
          "database": { "type": "sqlite3", "db_file": "\(dataDir.path)/data.db", "table_prefix": "x_" },
          "log": { "enable": true, "name": "\(dataDir.path)/log.log", "max_size": 20 },
          "temp_dir": "\(dataDir.path)/temp",
          "bleve_dir": "\(dataDir.path)/bleve",
          "token_expires_in": 48
        }
        """
        var configCorrected = false
        let configOK: Bool = {
            guard let existing = try? String(contentsOf: conf, encoding: .utf8),
                  let ed = existing.data(using: .utf8),
                  let ej = try? JSONSerialization.jsonObject(with: ed) as? [String: Any],
                  let scheme = ej["scheme"] as? [String: Any] else { return false }
            return (scheme["address"] as? String) == "127.0.0.1" && (scheme["http_port"] as? Int) == port
        }()
        if !configOK {
            do {
                try json.write(to: conf, atomically: true, encoding: .utf8)
                configCorrected = true
            } catch {
                throw InstallError(message: "配置文件写入失败：\(error.localizedDescription)")
            }
        }
        // 配置刚被纠正而服务正在跑（旧配置生效中）→ 重启服务让 127.0.0.1 绑定生效
        if configCorrected, await serviceRunning() {
            state.log("检测到不安全的监听配置，已纠正为 127.0.0.1 并重启服务")
            _ = await shAsync("pkill -f 'Application Support/QuarkMount/bin/openlist' 2>/dev/null")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        // 启动（环境变量方式确保 admin 被创建）
        var pass = ""
        if let s = try? String(contentsOf: passFile, encoding: .utf8), !s.isEmpty {
            pass = s
        } else {
            pass = randomPassword()
            do {
                try pass.write(to: passFile, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passFile.path)
            } catch {
                throw InstallError(message: "管理员密码保存失败：\(error.localizedDescription)")
            }
            // 读回校验：写坏了会让下次部署用新密码登录正在跑的服务（必 401）
            let readBack = (try? String(contentsOf: passFile, encoding: .utf8)) ?? ""
            guard readBack == pass else {
                throw InstallError(message: "管理员密码写入校验失败，请重试")
            }
        }

        if !(await serviceRunning()) {
            state.log("启动 OpenList 服务…")
            do { try launchOpenList(pass: pass) }
            catch { throw InstallError(message: "OpenList 启动失败：\(error.localizedDescription)") }
            guard await waitForService() else {
                let (log, _) = await shAsync("tail -15 '\(base.appendingPathComponent("openlist.log").path)' 2>/dev/null")
                throw InstallError(message: "OpenList 服务启动超时。\(log.prefix(300))")
            }
        }
        state.log("服务已就绪 (127.0.0.1:\(port))")

        // 修复 admin 的 WebDAV 写权限位（OpenList v4 建号缺陷：0x71FF 缺 bit9）
        try await fixAdminPermission(state: state, pass: pass)
    }

    static func apiLogin(_ pass: String) async throws -> String {
        // 最多重试 3 次（429 限频可能因历史失败登录触发，稍等即恢复）
        for attempt in 0..<3 {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/auth/login")!)
            req.timeoutInterval = 10
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["username": "admin", "password": pass])
            let (d, resp) = try await URLSession.shared.data(for: req)
            let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] ?? [:]
            if let token = (j["data"] as? [String: Any])?["token"] as? String {
                return token
            }
            let code = (j["code"] as? Int) ?? (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 429, attempt < 2 {
                try await Task.sleep(nanoseconds: 8_000_000_000)   // 等 8 秒退避
                continue
            }
            if (code == 401 || code == 403), attempt == 0 {
                // 陈旧 openlist 占着端口（卸载半失败/App 被强杀后的孤儿进程）：.admin-pass 已是新密码，
                // 旧实例不认 → 永远 401。杀掉用它自己的密码重启一次再试——否则用户卡死在 401
                // 且没有任何可行动提示（v1.0.2 实测死路）
                _ = await shAsync("pkill -f 'Application Support/QuarkMount/bin/openlist' 2>/dev/null")
                for _ in 0..<5 {
                    if await shAsync("curl -s -o /dev/null --max-time 2 http://127.0.0.1:\(port)/").1 != 0 { break }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                try? launchOpenList(pass: pass)
                _ = await waitForService()
                continue
            }
            throw InstallError(message: "登录 OpenList 失败：\(j["message"] as? String ?? "code \(code)")")
        }
        throw InstallError(message: "登录 OpenList 失败（重试后仍被限频）")
    }

    static func fixAdminPermission(state: AppState, pass: String) async throws {
        let token = try await apiLogin(pass)
        // api() 带 HTTP 状态码返回，区分「请求失败」与「业务错误」
        func api(_ method: String, _ path: String, body: Any? = nil) async throws -> (Int, [String: Any]) {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            req.timeoutInterval = 10
            req.httpMethod = method
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(token, forHTTPHeaderField: "Authorization")
            if let b = body { req.httpBody = try JSONSerialization.data(withJSONObject: b) }
            let (d, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
            return (code, j)
        }
        // 动态定位 admin 用户（不能硬编码 id——不同部署的 admin/guest id 会互换！）
        let (lcode, listResp) = try await api("GET", "/api/admin/user/list")
        guard lcode == 200,
              let users = (listResp["data"] as? [String: Any])?["content"] as? [[String: Any]] else {
            throw InstallError(message: "读取用户列表失败（HTTP \(lcode)）")
        }
        guard let adminBrief = users.first(where: { ($0["role"] as? Int) == 2 || ($0["username"] as? String) == "admin" }),
              let adminId = adminBrief["id"] as? Int else {
            throw InstallError(message: "未找到 admin 用户")
        }
        // 取完整对象再改（list 返回的可能缺字段，直接 POST 会把字段清零）
        let (gcode, got) = try await api("GET", "/api/admin/user/get?id=\(adminId)")
        guard let user = got["data"] as? [String: Any] else {
            throw InstallError(message: "读取 admin 用户失败（HTTP \(gcode)）")
        }
        let perm = (user["permission"] as? Int) ?? 0
        let want = perm | 0x73FF   // OpenList 标准 admin 权限（0-8/12-14 位 + bit9 WebDAV 写）
        if perm == want {
            state.log("admin 权限正常")
            return
        }
        var u = user
        u["permission"] = want
        let (ucode, uresp) = try await api("POST", "/api/admin/user/update", body: u)
        if ucode == 200, (uresp["code"] as? Int) == 200 {
            state.log("已修复 admin 的 WebDAV 写权限（上传/删除需要）")
        } else {
            throw InstallError(message: "admin 权限修复失败：\(uresp["message"] as? String ?? "HTTP \(ucode)")")
        }
    }

    // MARK: Step 3: 挂载

    static func isMounted() -> Bool {
        sh("mount | grep -q ' on \(mountPoint.path) '").1 == 0
    }

    /// 异步版：轮询循环/检测用，避免同步 Process 阻塞主线程
    static func isMountedAsync() async -> Bool {
        await shAsync("mount | grep -q ' on \(mountPoint.path) '").1 == 0
    }

    /// 健康挂载判定：挂载条目存在 **且** rclone 进程活着，两个条件缺一不可。
    /// 只用 mount | grep 会被僵尸挂载骗过——rclone 被 kill -9/崩溃后 macFUSE 条目残留，
    /// ls 报 Device not configured，而所有检查都显示「已挂载」（v1.0.2 稳定性实测复现，
    /// 守护进程因此永不重挂）。守护脚本侧同逻辑修复。
    static func isMountedHealthyAsync() async -> Bool {
        guard await isMountedAsync() else { return false }
        return await shAsync("pgrep -f 'Application Support/QuarkMount/rclone.conf'").1 == 0
    }

    static func writeRcloneConf(state: AppState) async throws {
        let pass = (try? String(contentsOf: passFile, encoding: .utf8)) ?? ""
        let (obscured, code) = await shAsync("'\(rcloneBin.path)' obscure '\(pass.replacingOccurrences(of: "'", with: "'\\''"))'")
        guard code == 0 else { throw InstallError(message: "rclone 密码编码失败") }
        let conf = """
        [quark]
        type = webdav
        url = http://127.0.0.1:\(port)/dav
        vendor = other
        user = admin
        pass = \(obscured.trimmingCharacters(in: .whitespacesAndNewlines))

        """
        try conf.write(to: rcloneConf, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rcloneConf.path)
    }

    /// LaunchAgent plist 是否存在（判断「曾经部署过」的依据）
    static var agentPlistExists: Bool {
        fm.fileExists(atPath: home.appendingPathComponent("Library/LaunchAgents/\(launchLabel).plist").path)
    }

    /// 确保 LaunchAgent 守护进程已加载且在运行（挂载的持有者）
    /// 开机竞态、守护被杀、plist 被改坏时，这里负责把它拉起来
    static func ensureAgentRunning(state: AppState) async {
        let uid = getuid()
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(launchLabel).plist")
        guard fm.fileExists(atPath: plist.path) else { return }   // 未部署：无从拉起
        // 未加载 → 加载
        if await shAsync("launchctl list | grep -q '\(launchLabel)'").1 != 0 {
            _ = await shAsync("launchctl bootstrap gui/\(uid) '\(plist.path)' 2>/dev/null")
        }
        // 未运行 → 唤醒（-k 先停后起，幂等安全）
        if await shAsync("launchctl print gui/\(uid)/\(launchLabel) 2>/dev/null | grep -q 'state = running'").1 != 0 {
            _ = await shAsync("launchctl kickstart -k gui/\(uid)/\(launchLabel) 2>/dev/null")
            state.log("后台守护进程未运行，已唤醒")
        }
    }

    static func mount(state: AppState) async throws {
        // 修复挂载点目录权限（FUSE 卸载后可能留下怪权限）
        _ = await shAsync("mkdir -p '\(mountPoint.path)' && chmod 755 '\(mountPoint.path)'")
        // === 挂载归属权：交给 LaunchAgent 守护进程（launchd 名下）===
        // App 只是控制面板：退出/崩溃/强杀都不影响挂载，重启后由 launchd 恢复
        // 【必须先写 rclone.conf】守护进程随时可能挂载，没有配置它永远挂不上。
        // v1.0.2 曾把唯一写入点放在下方「守护不在场」的兜底路径 → 全新安装必死路
        // （等 60s 后抛「请重启电脑后重试」，而重启/重试走的都是同一条死路）。
        // 详见 docs/AUDIT.md CRITICAL-4。
        try await writeRcloneConf(state: state)
        await ensureAgentRunning(state: state)
        var waited = 0
        while waited < 60 {
            // 健康判定（条目 + rclone 进程都在才算数）：僵尸挂载条目不配就绪
            if await isMountedHealthyAsync() {
                state.log("已挂载到 ~/Quark（后台守护持有，退出 App 不影响）")
                return
            }
            if waited % 15 == 0 { state.log("等待后台守护进程挂载…（\(waited)s）") }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            waited += 1
        }
        // 守护进程还活着却挂不上：不能和它抢（pkill 会误杀它的 rclone），交给它自己恢复
        if await shAsync("pgrep -f 'QuarkMount/start-all.sh'").1 == 0 {
            let (log, _) = await shAsync("tail -5 '\(base.appendingPathComponent("mount.log").path)' 2>/dev/null")
            throw InstallError(message: "后台守护进程 60 秒内未能完成挂载（配置文件已就绪）。请打开 ~/Library/Application Support/QuarkMount/mount.log 查看原因后重试。日志尾部：\(log.prefix(200))")
        }
        // === 兜底：守护进程确实不在（plist 缺失/被禁用），App 自己挂 ===
        state.log("后台守护不可用，由 App 直接挂载")
        // 卸载残留（旧部署的挂载）——优雅优先，强卸载会让 rclone 卡死占住目录
        if await isMountedAsync() {
            state.log("卸载旧挂载以切换到本应用管理…")
            _ = await shAsync("diskutil unmount '\(mountPoint.path)' >/dev/null 2>&1 || umount '\(mountPoint.path)' >/dev/null 2>&1 || true")
            try await Task.sleep(nanoseconds: 2_000_000_000)
            if await isMountedAsync() {
                _ = await shAsync("diskutil unmount force '\(mountPoint.path)' >/dev/null 2>&1 || umount -f '\(mountPoint.path)' >/dev/null 2>&1 || true")
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        // 清掉旧部署的 rclone 挂载进程（daemon 化后 argv 只剩 "rclone"，按进程名精确杀）
        _ = await shAsync("pkill -f 'Application Support/QuarkMount/rclone.conf' 2>/dev/null || true")
        // 端口被非 OpenList 占用 → 明确报错（服务启动阶段已探测过，这里兜底；不用 lsof——本机极慢）
        if await shAsync("curl -s -o /dev/null --max-time 3 http://127.0.0.1:\(port)/").1 != 0 {
            throw InstallError(message: "本地服务 (127.0.0.1:\(port)) 未响应，可能端口被其他程序占用。请检查后重试")
        }
        // 挂载点非空警告：挂载后原文件会被遮住（不丢失，卸载后恢复）
        let (entries, _) = await shAsync("ls -A '\(mountPoint.path)' 2>/dev/null | wc -l | tr -d ' '")
        if let n = Int(entries.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 {
            state.log("⚠️ ~/Quark 目录下原有 \(n) 个文件，挂载后会被暂时遮住（卸载 App 后恢复）")
        }
        let args = ["mount", "quark:/", mountPoint.path,
                    "--config", rcloneConf.path,
                    // —— 性能调优（v1.0.1 起）——
                    // full 缓存：读也进本地缓存，二次打开秒开、视频拖动不卡；缓存有上限按 LRU 淘汰
                    "--vfs-cache-mode", "full",
                    "--cache-dir", base.appendingPathComponent("vfs-cache").path,
                    "--vfs-cache-max-size", "20G",
                    "--vfs-cache-min-free-space", "2G",   // 5G 会在小磁盘上整体停用缓存（AUDIT LOW）
                    "--vfs-cache-poll-interval", "5m",   // 后台缓存检查 1m→5m（省 CPU）
                    // read-ahead 0（v1.1.1 实测调整）：Finder 给每个文件取缩略图只读几十 KB，
                    // 而 read-ahead 64M 会把小文件整个拉下来（实测每文件 5MB、8 文件 40MB，
                    // 开个相册文件夹带宽就被榨干）。关掉后缩略图只拉 64KB/文件（80 倍落差），
                    // 顺序读实测反而更快（10MB/1.25s = 8MB/s）。缓存模式下二次访问仍秒开。
                    "--vfs-read-ahead", "0",
                    "--buffer-size", "8M",              // 32M→8M：多文件并发打开时每句柄缓冲区降 4 倍，RSS 无回归
                    "--transfers", "8",                  // 并行传输（目录列举/多文件更快）
                    "--checkers", "8",
                    "--dir-cache-time", "10m",           // 目录缓存：重复进目录秒开
                    "--attr-timeout", "10m",
                    "--poll-interval", "0",              // 关后台轮询（省请求；变更等目录缓存过期）
                    "--timeout", "30s",                  // 网络超时：卡住最多 30s 失败，不会无限挂起
                    "--contimeout", "10s",
                    "--low-level-retries", "3",          // 快速失败重试（默认 10 次太慢）
                    "--retries", "3",
                    "--no-checksum",                    // 少一次校验请求
                    "--vfs-write-back", "30s",           // 写后 30s 回传：拷贝/保存立即完成不卡
                    "--noapplexattr",
                    "--volname", "Quark",
                    // RC 接口：守护进程经它刷新目录缓存（挂载后预热）。launchd 上下文
                    // 无权限穿越 FUSE 挂载点（实测 EPERM），但可以走 HTTP 让挂载进程自己列举
                    "--rc",
                    "--rc-addr", "127.0.0.1:5573",
                    "--rc-no-auth",
                    "--daemon",
                    "--log-file", base.appendingPathComponent("mount.log").path,
                    "--log-level", "INFO"]

        func attemptMount() async -> Bool {
            let (_, code) = await runMount(args, logFile: base.appendingPathComponent("mount.log"))
            if code != 0 { return false }
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if await isMountedHealthyAsync() { return true }
            }
            return false
        }

        // 记录挂载日志当前行数：EBUSY 判断只认本次尝试的新增日志。
        // v1.0.2 用 tail -10 会取到上一轮残留的 busy 行——实测连续 5 次 SIGKILL 掉刚拉起的
        // 健康 rclone、空转 6 分钟（start-all.log 有据可查）
        let (markOut, _) = await shAsync("wc -l < '\(base.appendingPathComponent("mount.log").path)' 2>/dev/null || echo 0")
        let logMark = Int(markOut.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if await attemptMount() {
            state.log("已挂载到 ~/Quark")
            return
        }
        // 竞态复查：等待期间守护进程可能刚好挂上（别把它的 rclone 当残留杀掉）
        if await isMountedAsync() {
            state.log("已挂载到 ~/Quark（后台守护持有，退出 App 不影响）")
            return
        }
        // EBUSY 恢复：残留的 rclone 守护进程卡在内核退出态占住挂载点（崩溃/强杀后的真实场景）
        // 双重条件：① 本次尝试产生了 busy 日志 ② 确有残留 rclone 进程——避免陈旧日志误杀健康进程
        let (log, _) = await shAsync("tail -n +\(logMark + 1) '\(base.appendingPathComponent("mount.log").path)' 2>/dev/null | tail -20")
        let stuckRclone = await shAsync("pgrep -f 'Application Support/QuarkMount/rclone.conf'").1 == 0
        if log.lowercased().contains("busy"), stuckRclone {
            state.log("挂载点被残留进程占用，正在自动恢复…")
            _ = await shAsync("pkill -9 -f 'Application Support/QuarkMount/rclone.conf' 2>/dev/null || true")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            _ = await shAsync("rmdir '\(mountPoint.path)' 2>/dev/null || true")
            _ = await shAsync("mkdir -p '\(mountPoint.path)' && chmod 755 '\(mountPoint.path)'")
            if await attemptMount() {
                state.log("已挂载到 ~/Quark（自动恢复成功）")
                return
            }
        }
        let (out2, _) = await shAsync("tail -4 '\(base.appendingPathComponent("mount.log").path)' 2>/dev/null")
        throw InstallError(message: "挂载失败：\(out2.prefix(300))")
    }

    // MARK: Step 4: 开机自启

    static func setupAutoStart(state: AppState) async throws {
        // 守护脚本
        let script = base.appendingPathComponent("start-all.sh")
        let sh = """
        #!/bin/bash
        # 夸克网盘守护：kext -> OpenList(循环内健康检查) -> 挂载(后台跑，循环持续照看)
        # 关键设计（v1.1.0 起，v1.1.1 加固，全部来自实测教训）：
        #  1. rclone 必须后台化——前台运行会堵住循环，服务检查永远跑不到
        #  2. 挂载健康 = 条目存在 **且** rclone 进程活着——只用 mount | grep 会被僵尸挂载骗过
        #     （rclone 被 kill -9/崩溃后条目残留、ls 报 Device not configured，守护却永不重挂）
        #  3. 任何故障路径只 log + sleep，绝不 exit——KeepAlive 下 exit = 每秒重启的崩溃循环
        #  4. rclone.conf 是挂载硬前置，缺失时等待而不是反复空跑刷日志
        #  5. 服务健康 = Web UI 活着 **且** WebDAV 真能列举——OpenList 的 SQLite 卡死时
        #     / 返回 200 但 PROPFIND 全部 500（实测毒化 8 小时），只查 / 的守护永远发现不了
        #  6. EBUSY 恢复不要求「有残留进程」——rclone CRITICAL 退出后挂载点 vnode 仍可能
        #     卡死（实测），此时 pgrep 永远为空，加了进程条件反而永不恢复
        #  7. 缓存预热走 rclone RC 接口（HTTP），不走 FUSE——launchd 上下文无权限穿越
        #     挂载点（实测 Operation not permitted），但可以让挂载进程自己列举
        BASE="\(base.path)"
        LOG="$BASE/start-all.log"
        MLOG="$BASE/mount.log"
        MOUNTPT="\(mountPoint.path)"
        RCLONE="$BASE/bin/rclone"
        RCADDR="127.0.0.1:5573"
        PW="$(cat "$BASE/.admin-pass" 2>/dev/null)"
        log(){ echo "[$(date '+%F %T')] $*" >> "$LOG"; }

        # 日志轮换（无界增长：INFO 级 + vfs-cache full 事件量，常驻数月可达数十 MB）
        rotate(){ for f in "$LOG" "$MLOG" "$BASE/openlist.log"; do
            if [ -f "$f" ] && [ "$(stat -f%z "$f" 2>/dev/null || echo 0)" -gt 20971520 ]; then
              mv -f "$f" "$f.1" 2>/dev/null; : > "$f" 2>/dev/null; log "日志轮换：$f"
            fi
          done; }

        # 挂载健康判定：条目 + 进程双条件（僵尸条目不算健康）
        mount_ok(){ mount | grep -q " on $MOUNTPT " && pgrep -f 'Application Support/QuarkMount/rclone.conf' >/dev/null 2>&1; }

        # 服务健康判定：0=健康 1=没起来 2=活着但功能坏（WebDAV 500）。
        # 404=存储还没建（部署中）不算坏；超时/网络波动不重启（避免循环重启）
        svc_ok(){
          curl -s --fail -o /dev/null --max-time 3 http://127.0.0.1:5244/ || return 1
          local code
          code=$(curl -s -o /dev/null --max-time 8 -w '%{http_code}' -X PROPFIND \
            -H "Depth: 0" -u "admin:$PW" http://127.0.0.1:5244/dav/quark/ 2>/dev/null)
          case "$code" in
            207|404) return 0 ;;
            500|502|503) return 2 ;;
            *) return 0 ;;
          esac
        }

        # 挂载后缓存预热：经 rclone RC 接口让挂载进程自己列举根目录 + 各顶层目录。
        # 不用 ls 挂载点——launchd 上下文无权限穿越 FUSE（实测 Operation not permitted）；
        # 也不用 glob——它要对每个条目 stat，同样被权限挡掉（实测空列表）。
        # vfs/refresh 会把列举结果写进挂载进程的目录缓存，用户之后打开 Finder 直接命中。
        warm_cache(){
          (
            sleep 2
            curl -s --max-time 15 -X POST "http://$RCADDR/vfs/refresh?dir=quark/" -o /dev/null 2>&1
            names=$(curl -s --max-time 15 -X POST "http://$RCADDR/operations/list" \
              -H "Content-Type: application/json" -d '{"fs":"quark:","remote":"quark"}' 2>/dev/null \
              | grep -o '"Name": *"[^"]*"' | cut -d'"' -f4)
            n=0
            for name in $names; do
              enc=$(/usr/bin/python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$name" 2>/dev/null)
              [ -z "$enc" ] && continue
              curl -s --max-time 15 -X POST "http://$RCADDR/vfs/refresh?dir=quark/$enc" -o /dev/null 2>&1 &
              n=$((n+1))
              [ $((n % 3)) -eq 0 ] && wait
            done
            wait
            log "缓存预热完成（根目录 + $n 个顶层目录，经 RC）"
          ) >/dev/null 2>&1 &
        }

        if ! kextstat 2>/dev/null | grep -q macfuse; then
          /Library/Filesystems/macfuse.fs/Contents/Resources/load_macfuse >> "$LOG" 2>&1 || log "kext 加载失败"
        fi

        while true; do
          rotate
          # —— 服务健康检查（Web UI + WebDAV 功能双探测）——
          svc_ok; SC=$?
          if [ $SC -ne 0 ]; then
            # 数据目录不存在（卸载残留/被误删）：绝不能 exit——KeepAlive 会立刻重启形成崩溃循环
            if [ ! -d "$BASE" ] || [ ! -x "$BASE/bin/openlist" ]; then
              log "数据目录或组件缺失（$BASE），60s 后重试；如已卸载请删除 LaunchAgent"
              sleep 60
              continue
            fi
            if [ $SC -eq 2 ]; then
              # 活着但功能坏（实测：SQLite 卡死时 PROPFIND 全 500，Web UI 却正常）→ 杀了重启
              log "WebDAV 功能异常（PROPFIND 500），重启 OpenList"
              pkill -f 'Application Support/QuarkMount/bin/openlist' 2>/dev/null
              sleep 1
            fi
            cd "$BASE" || true
            OPENLIST_ADMIN_PASSWORD="$PW" nohup "$BASE/bin/openlist" server >> "$BASE/openlist.log" 2>&1 &
            log "OpenList 启动中…"
            for _ in $(seq 1 30); do
              curl -s --fail -o /dev/null --max-time 2 http://127.0.0.1:5244/ && break
              sleep 1
            done
          fi

          # —— 挂载检查（后台运行，循环继续照看服务）——
          if ! mount_ok; then
            if [ ! -x "$RCLONE" ]; then
              log "rclone 不存在（$RCLONE），60s 后重试"
              sleep 60
              continue
            fi
            # 僵尸挂载清理：条目在但 rclone 进程死了（kill -9/崩溃）——文件系统已不可用，
            # 不清掉条目的话 mount | grep 恒真，永远走不到重挂（v1.0.2 实测卡死在此）
            if mount | grep -q " on $MOUNTPT "; then
              log "检测到无效挂载条目（rclone 进程不在），清理后重挂"
              diskutil unmount force "$MOUNTPT" >/dev/null 2>&1 || umount -f "$MOUNTPT" >/dev/null 2>&1
              sleep 1
            fi
            # rclone.conf 是挂载硬前置：没有它就等，别反复空跑刷日志
            if [ ! -s "$BASE/rclone.conf" ]; then
              log "rclone.conf 缺失，等待配置写入（App 部署会写）…"
              sleep 10
              continue
            fi
            # 记录日志行数：EBUSY 判断只认本次尝试的新增行（陈旧 busy 行会误杀健康 rclone）
            MARK=$(wc -l < "$MLOG" 2>/dev/null || echo 0)
            log "开始挂载"
            "$RCLONE" mount quark:/ "$MOUNTPT" --config "$BASE/rclone.conf" --vfs-cache-mode full --cache-dir "$BASE/vfs-cache" --vfs-cache-max-size 20G --vfs-cache-min-free-space 2G --vfs-cache-poll-interval 5m --vfs-read-ahead 0 --buffer-size 8M --vfs-write-back 30s --transfers 8 --checkers 8 --dir-cache-time 10m --attr-timeout 10m --poll-interval 0 --timeout 30s --contimeout 10s --low-level-retries 3 --retries 3 --no-checksum --noapplexattr --volname Quark --rc --rc-addr "$RCADDR" --rc-no-auth --log-file "$MLOG" --log-level INFO &
            ok=0
            for _ in $(seq 1 30); do
              sleep 1
              if mount_ok; then ok=1; break; fi
            done
            if [ "$ok" = "1" ]; then
              log "挂载成功"
              warm_cache
            else
              log "挂载未就绪"
              # EBUSY 自恢复：本次尝试产生了 busy 行就恢复——不要求残留进程存在
              # （rclone CRITICAL 退出后 vnode 仍卡死是实测场景，加了进程条件反而永不恢复）
              NEWBUSY=$(tail -n +$((MARK + 1)) "$MLOG" 2>/dev/null | tail -20 | grep -ci busy)
              if [ "${NEWBUSY:-0}" -gt 0 ]; then
                log "挂载点被占用，执行恢复"
                pkill -9 -f 'Application Support/QuarkMount/rclone.conf' 2>/dev/null
                sleep 1
                rmdir "$MOUNTPT" 2>/dev/null
                mkdir -p "$MOUNTPT" && chmod 755 "$MOUNTPT"
              fi
            fi
          fi

          sleep 10
        done
        """
        try sh.write(to: script, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        // LaunchAgent
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(launchLabel).plist")
        mkdirs(home.appendingPathComponent("Library/LaunchAgents"))
        let plistXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(launchLabel)</string>
          <key>ProgramArguments</key>
          <array><string>/bin/bash</string><string>\(script.path)</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>StandardOutPath</key><string>\(base.path)/launchd.log</string>
          <key>StandardErrorPath</key><string>\(base.path)/launchd.log</string>
        </dict>
        </plist>
        """
        try plistXML.write(to: plist, atomically: true, encoding: .utf8)
        let uid = getuid()
        _ = await shAsync("launchctl bootout gui/\(uid)/\(launchLabel) 2>/dev/null || true")
        let (bootOut, bootCode) = await shAsync("launchctl bootstrap gui/\(uid) '\(plist.path)' 2>&1")
        guard bootCode == 0 else {
            throw InstallError(message: "开机自启设置失败：\(bootOut.prefix(200))")
        }
        _ = await shAsync("launchctl kickstart -k gui/\(uid)/\(launchLabel) 2>/dev/null || true")
        // 验证真的注册上了
        let (listOut, listCode) = await shAsync("launchctl list | grep \(launchLabel)")
        guard listCode == 0 else {
            throw InstallError(message: "开机自启注册验证失败")
        }
        state.log("已设置开机自启（登录后自动挂载，掉了自动恢复）✅")
    }

    // MARK: 卸载

    static func uninstall(state: AppState) async {
        let uid = getuid()
        // 顺序有讲究：先停开机项（否则守护脚本会把挂载重新拉起来），再卸载，最后才删数据
        _ = await shAsync("launchctl bootout gui/\(uid)/\(launchLabel) 2>/dev/null")
        // bootout 异步生效：轮询几次再判定，否则误报「开机项未能停止」诱发用户无谓重启
        var agentGone = false
        for _ in 0..<4 {
            if await shAsync("launchctl list | grep -q '\(launchLabel)'").1 != 0 { agentGone = true; break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        // 优雅卸载优先；强卸载会让 rclone 卡在内核退出态占住目录
        _ = await shAsync("diskutil unmount '\(mountPoint.path)' >/dev/null 2>&1 || umount '\(mountPoint.path)' >/dev/null 2>&1")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        var unmounted = await shAsync("mount | grep -q ' on \(mountPoint.path) '").1 != 0
        if !unmounted {
            _ = await shAsync("diskutil unmount force '\(mountPoint.path)' >/dev/null 2>&1 || umount -f '\(mountPoint.path)' >/dev/null 2>&1")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            unmounted = await shAsync("mount | grep -q ' on \(mountPoint.path) '").1 != 0
        }
        // 精确打击：只杀用本应用配置的 rclone，绝不误杀用户自己的 rclone 挂载
        _ = await shAsync("pkill -f 'Application Support/QuarkMount/rclone.conf' 2>/dev/null")
        // 必须停掉 OpenList 服务进程：否则孤儿进程占着 5244 和数据目录，下次部署必败
        retainedProcess?.terminate()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        _ = await shAsync("pkill -f 'Application Support/QuarkMount/bin/openlist' 2>/dev/null")
        retainedProcess = nil
        // 等端口释放（最多 5 秒）
        for _ in 0..<5 {
            if await shAsync("curl -s -o /dev/null --max-time 2 http://127.0.0.1:\(port)/").1 != 0 { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        // 数据目录删除（即使上面有步骤失败也继续删——但会把问题如实告诉用户）
        try? fm.removeItem(at: home.appendingPathComponent("Library/LaunchAgents/\(launchLabel).plist"))
        try? fm.removeItem(at: base)
        state.deployed = false
        state.mountOK = false
        state.phase = .idle
        state.uninstalling = false
        if unmounted && agentGone {
            state.log("已卸载：服务停止、挂载卸载、开机项移除、数据目录已删除")
        } else {
            var problems: [String] = []
            if !unmounted { problems.append("挂载未能卸载（~/Quark 仍被占用，重启后消失）") }
            if !agentGone { problems.append("开机项未能停止") }
            state.log("⚠️ 卸载基本完成，但：\(problems.joined(separator: "；"))。数据目录已删除，重启电脑后彻底清净")
        }
    }
}
