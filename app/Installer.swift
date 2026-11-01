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
            a = Asset(name: a.name.replacingOccurrences(of: "arm64", with: "amd64"),
                      repo: a.repo, tag: a.tag, expectMB: a.expectMB, sha256: "")
            // amd64 的校验和见 assetsAmd64（未锁定版本不提供校验，退化为体积+解压测试）
            if let a2 = assetsAmd64[key] { a = a2 }
        }
        return a
    }

    static let assets: [String: Asset] = [
        "openlist": Asset(name: "openlist-darwin-arm64.tar.gz", repo: "OpenListTeam/OpenList", tag: "v4.2.9", expectMB: 52, sha256: "dac3b46e96f18ec3a06824fbac660d3e23c8a96f0aa40bc2bf2c5fde5b1eaecf"),
        "rclone":   Asset(name: "rclone-v1.75.2-osx-arm64.zip",  repo: "rclone/rclone",           tag: "v1.75.2", expectMB: 34, sha256: "610ab7d48615135dfc60b763858b11a426a0d3d1160c1bb76fb0ae6011b02edd"),
        "macfuse":  Asset(name: "macfuse-5.5.0.dmg",             repo: "macfuse/macfuse",          tag: "macfuse-5.5.0", expectMB: 23, sha256: "92c21ef2db4199bcf5bddc8e6efb57b23ecb9715f74ab38cba2c77ab226d3830"),
    ]
    static let assetsAmd64: [String: Asset] = [
        "openlist": Asset(name: "openlist-darwin-amd64.tar.gz", repo: "OpenListTeam/OpenList", tag: "v4.2.9", expectMB: 52, sha256: ""),
        "rclone":   Asset(name: "rclone-v1.75.2-osx-amd64.zip",  repo: "rclone/rclone",           tag: "v1.75.2", expectMB: 34, sha256: ""),
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
        p.waitUntilExit()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        return (String(decoding: d, as: UTF8.self), p.terminationStatus)
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

    static func ensureMacFUSE(state: AppState) async throws {
        if await isMacFuseReady() {
            state.log("macFUSE 已安装且驱动已加载")
            return
        }
        let (pkgOut, _) = await shAsync("pkgutil --pkgs 2>/dev/null | grep -c io.macfuse")
        let installed = pkgOut.trimmingCharacters(in: .whitespacesAndNewlines) != "0"

        if !installed {
            state.log("未检测到 macFUSE，开始下载安装包…")
            guard let a = assetFor("macfuse") else { throw InstallError(message: "组件清单缺失") }
            let dmg = try await download(a, state: state)
            state.log("挂载 dmg…")
            let (_, code) = await shAsync("hdiutil attach -nobrowse -quiet '\(dmg.path)'")
            guard code == 0 else { throw InstallError(message: "dmg 挂载失败") }
            // 找到 pkg
            let vol = await shAsync("ls -d /Volumes/*[Mm]ac[Ff]use* 2>/dev/null | head -1").0
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pkg = await shAsync("find '\(vol)' -maxdepth 2 -name '*.pkg' 2>/dev/null | head -1").0
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pkg.isEmpty else {
                _ = await shAsync("hdiutil detach -quiet '\(vol)'")
                throw InstallError(message: "dmg 中未找到 pkg")
            }
            state.log("安装 macFUSE（需要你在弹出框输入密码）…")
            let src = "do shell script \"installer -pkg '\(pkg)' -target /\" with administrator privileges"
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
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

    static func deployComponents(state: AppState) async throws {
        mkdirs(binDir)
        mkdirs(dataDir)
        mkdirs(mountPoint)

        // 预检：磁盘空间（组件 ~110MB + VFS 写缓存上限 10G 之外的日常占用，留 400MB 余量）
        let (freeOut, _) = await shAsync("df -m '$HOME/Library/Application Support' | awk 'NR==2{print $4}'")
        if let freeMB = Int(freeOut.trimmingCharacters(in: .whitespacesAndNewlines)), freeMB < 400 {
            throw InstallError(message: "磁盘空间不足（剩余 \(freeMB)MB，至少需要 400MB）")
        }

        // openlist
        if !fm.fileExists(atPath: openlistBin.path) {
            let legacy = legacyDir.appendingPathComponent("openlist")
            if fm.fileExists(atPath: legacy.path) {
                state.log("从旧部署导入 openlist…")
                try? fm.copyItem(at: legacy, to: openlistBin)
            } else {
                state.log("下载 OpenList 组件（\(arch)）…")
                let tar = try await download(assetFor("openlist")!, state: state)
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
            let legacy = legacyDir.appendingPathComponent("rclone-v1.75.2-osx-\(arch)/rclone")
            if fm.fileExists(atPath: legacy.path) {
                state.log("从旧部署导入 rclone…")
                try? fm.copyItem(at: legacy, to: rcloneBin)
            } else {
                state.log("下载 rclone 组件（\(arch)）…")
                let zip = try await download(assetFor("rclone")!, state: state)
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
    }

    // MARK: 下载（多镜像 + 进度 + 完整性校验）

    @discardableResult
    static func download(_ a: Asset, state: AppState) async throws -> URL {
        let tmp = base.appendingPathComponent("downloads")
        mkdirs(tmp)
        let dest = tmp.appendingPathComponent(a.name)
        try? fm.removeItem(at: dest)
        let expected = a.expectMB * 1_048_576
        var lastErr = "未知错误"

        for (i, mirror) in mirrors.enumerated() {
            let url = mirror + "https://github.com/\(a.repo)/releases/download/\(a.tag)/\(a.name)"
            state.progressLabel = "下载 \(a.name)（源\(i + 1)/\(mirrors.count)）"
            state.progress = 0
            guard await curl(url: url, dest: dest, expected: expected, state: state) else {
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
                continue
            }
            state.progress = 1
            return dest
        }
        try? fm.removeItem(at: dest)
        throw InstallError(message: "组件下载失败：\(a.name)（\(lastErr)。请检查网络后重试）")
    }

    private static func curl(url: String, dest: URL, expected: Double, state: AppState) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                p.arguments = ["-sL", "--fail", "--connect-timeout", "15", "--max-time", "900",
                               "-o", dest.path, url]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                p.terminationHandler = { _ in cont.resume(returning: p.terminationStatus == 0) }
                do { try p.run() } catch { cont.resume(returning: false); return }
                // 进度轮询
                Task.detached {
                    while true {
                        let sz = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? UInt64) ?? 0
                        let frac = min(1, Double(sz) / max(expected, 1))
                        await MainActor.run { state.progress = frac }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if !p.isRunning { break }
                    }
                }
            }
        }
    }

    // MARK: Step 2: 启动服务 + 账号权限

    static func serviceRunning() async -> Bool {
        await shAsync("curl -s -o /dev/null --max-time 3 http://127.0.0.1:\(port)/").1 == 0
    }

    static func startService(state: AppState) async throws {
        // 停掉非本应用的 openlist（旧版手动部署），保留本应用的（pgrep 精确匹配，不用 lsof——本机 lsof 极慢）
        _ = await shAsync("""
            for p in $(pgrep -f 'openlist server' 2>/dev/null); do
              if ! ps -p $p -o command= 2>/dev/null | grep -q 'Application Support/QuarkMount'; then kill $p 2>/dev/null; fi
            done
            """)
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // 写配置（仅本机监听 + 绝对路径）
        let conf = dataDir.appendingPathComponent("config.json")
        if !fm.fileExists(atPath: conf.path) {
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
            try? json.write(to: conf, atomically: true, encoding: .utf8)
        }

        // 启动（环境变量方式确保 admin 被创建）
        var pass = ""
        if let s = try? String(contentsOf: passFile, encoding: .utf8), !s.isEmpty {
            pass = s
        } else {
            pass = randomPassword()
            try? pass.write(to: passFile, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passFile.path)
        }

        if !(await serviceRunning()) {
            state.log("启动 OpenList 服务…")
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
                // 注意：不能 close——Process 启动时要 dup 这个 fd；Process 会强引用它
            }
            do {
                try p.run()
            } catch {
                throw InstallError(message: "OpenList 启动失败：\(error.localizedDescription)")
            }
            Installer.retainedProcess = p   // 防止 Process 被提前释放
            // 等待端口
            var ok = false
            for _ in 0..<30 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                if await serviceRunning() { ok = true; break }
            }
            guard ok else { throw InstallError(message: "OpenList 服务启动超时") }
        }
        state.log("服务已就绪 (127.0.0.1:\(port))")

        // 修复 admin 的 WebDAV 写权限位（OpenList v4 建号缺陷：0x71FF 缺 bit9）
        try await fixAdminPermission(state: state, pass: pass)
    }

    static func apiLogin(_ pass: String) async throws -> String {
        // 最多重试 3 次（429 限频可能因历史失败登录触发，稍等即恢复）
        for attempt in 0..<3 {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/auth/login")!)
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
            throw InstallError(message: "登录 OpenList 失败：\(j["message"] as? String ?? "code \(code)")")
        }
        throw InstallError(message: "登录 OpenList 失败（重试后仍被限频）")
    }

    static func fixAdminPermission(state: AppState, pass: String) async throws {
        let token = try await apiLogin(pass)
        // api() 带 HTTP 状态码返回，区分「请求失败」与「业务错误」
        func api(_ method: String, _ path: String, body: Any? = nil) async throws -> (Int, [String: Any]) {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
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

    static func writeRcloneConf(state: AppState) async throws {
        let pass = (try? String(contentsOf: passFile, encoding: .utf8)) ?? ""
        let (obscured, code) = await shAsync("'\(rcloneBin.path)' obscure '\(pass)'")
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

    static func mount(state: AppState) async throws {
        // 修复挂载点目录权限（FUSE 卸载后可能留下怪权限）
        _ = await shAsync("mkdir -p '\(mountPoint.path)' && chmod 755 '\(mountPoint.path)'")
        // 已是本应用管理的挂载才跳过
        let ours = await shAsync("pgrep -f 'rclone.*QuarkMount/rclone.conf'").1 == 0
        if isMounted() && ours {
            state.log("已挂载，跳过")
            return
        }
        // 卸载残留（旧部署的挂载）——优雅优先，强卸载会让 rclone 卡死占住目录
        if isMounted() {
            state.log("卸载旧挂载以切换到本应用管理…")
            _ = await shAsync("diskutil unmount '\(mountPoint.path)' >/dev/null 2>&1 || umount '\(mountPoint.path)' >/dev/null 2>&1 || true")
            try await Task.sleep(nanoseconds: 2_000_000_000)
            if isMounted() {
                _ = await shAsync("diskutil unmount force '\(mountPoint.path)' >/dev/null 2>&1 || umount -f '\(mountPoint.path)' >/dev/null 2>&1 || true")
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        // 清掉旧部署的 rclone 挂载进程（daemon 化后 argv 只剩 "rclone"，按进程名精确杀）
        _ = await shAsync("pkill -x rclone 2>/dev/null || true")
        // 端口被非 OpenList 占用 → 明确报错（服务启动阶段已探测过，这里兜底；不用 lsof——本机极慢）
        if await shAsync("curl -s -o /dev/null --max-time 3 http://127.0.0.1:\(port)/").1 != 0 {
            throw InstallError(message: "本地服务 (127.0.0.1:\(port)) 未响应，可能端口被其他程序占用。请检查后重试")
        }
        // 挂载点非空警告：挂载后原文件会被遮住（不丢失，卸载后恢复）
        let (entries, _) = await shAsync("ls -A '\(mountPoint.path)' 2>/dev/null | wc -l | tr -d ' '")
        if let n = Int(entries.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 {
            state.log("⚠️ ~/Quark 目录下原有 \(n) 个文件，挂载后会被暂时遮住（卸载 App 后恢复）")
        }
        try await writeRcloneConf(state: state)

        let args = ["mount", "quark:/", mountPoint.path,
                    "--config", rcloneConf.path,
                    "--vfs-cache-mode", "writes",
                    "--vfs-cache-max-size", "10G",
                    "--vfs-write-back", "30s",
                    "--dir-cache-time", "10m",
                    "--noapplexattr",
                    "--volname", "Quark",
                    "--daemon",
                    "--log-file", base.appendingPathComponent("mount.log").path,
                    "--log-level", "INFO"]

        func attemptMount() async -> Bool {
            let (_, code) = await runMount(args, logFile: base.appendingPathComponent("mount.log"))
            if code != 0 { return false }
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if isMounted() { return true }
            }
            return false
        }

        if await attemptMount() {
            state.log("已挂载到 ~/Quark")
            return
        }
        // EBUSY 恢复：残留的 rclone 守护进程卡在内核退出态占住挂载点（崩溃/强杀后的真实场景）
        let (log, _) = await shAsync("tail -4 '\(base.appendingPathComponent("mount.log").path)' 2>/dev/null")
        if log.lowercased().contains("busy") {
            state.log("挂载点被残留进程占用，正在自动恢复…")
            _ = await shAsync("pkill -9 -x rclone 2>/dev/null || true")
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
        # 夸克网盘守护：kext -> OpenList -> 挂载（掉了自动重挂）
        BASE="\(base.path)"
        LOG="$BASE/start-all.log"
        log(){ echo "[$(date '+%F %T')] $*" >> "$LOG"; }

        if ! kextstat 2>/dev/null | grep -q macfuse; then
          /Library/Filesystems/macfuse.fs/Contents/Resources/load_macfuse >> "$LOG" 2>&1 || log "kext 加载失败"
        fi
        if ! curl -s -o /dev/null --max-time 3 http://127.0.0.1:5244/; then
          cd "$BASE" || exit 1
          OPENLIST_ADMIN_PASSWORD="$(cat "$BASE/.admin-pass")" nohup "$BASE/bin/openlist" server >> "$BASE/openlist.log" 2>&1 &
          for _ in $(seq 1 30); do curl -s -o /dev/null --max-time 2 http://127.0.0.1:5244/ && break; sleep 1; done
          log "OpenList 已启动"
        fi
        RCLONE="$BASE/bin/rclone"
        MOUNTPT="\(mountPoint.path)"
        while true; do
          if mount | grep -q " on $MOUNTPT "; then sleep 30; continue; fi
          log "开始挂载"
          "$RCLONE" mount quark:/ "$MOUNTPT" \\
            --config "$BASE/rclone.conf" \\
            --vfs-cache-mode writes --vfs-cache-max-size 10G --vfs-write-back 30s \\
            --dir-cache-time 10m --noapplexattr --volname Quark \\
            --log-file "$BASE/mount.log" --log-level INFO
          code=$?
          log "挂载退出(code=$code)"
          # EBUSY 自恢复：残留守护进程占住挂载点 → 清理后重建目录节点
          if [ "$code" != "0" ] && tail -4 "$BASE/mount.log" 2>/dev/null | grep -qi "busy"; then
            log "挂载点被占用，执行恢复"
            pkill -9 -x rclone 2>/dev/null
            sleep 1
            rmdir "$MOUNTPT" 2>/dev/null
            mkdir -p "$MOUNTPT" && chmod 755 "$MOUNTPT"
          fi
          sleep 5
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
        _ = await shAsync("launchctl bootout gui/\(uid)/\(launchLabel) 2>/dev/null || true")
        _ = await shAsync("diskutil unmount '\(mountPoint.path)' >/dev/null 2>&1 || umount '\(mountPoint.path)' >/dev/null 2>&1 || true")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        _ = await shAsync("diskutil unmount force '\(mountPoint.path)' >/dev/null 2>&1 || umount -f '\(mountPoint.path)' >/dev/null 2>&1 || true")
        _ = await shAsync("pkill -x rclone 2>/dev/null || true")
        try? fm.removeItem(at: home.appendingPathComponent("Library/LaunchAgents/\(launchLabel).plist"))
        try? fm.removeItem(at: base)
        state.deployed = false
        state.mountOK = false
        state.phase = .idle
        state.log("已卸载：服务停止、挂载卸载、开机项移除、数据目录已删除")
    }
}
