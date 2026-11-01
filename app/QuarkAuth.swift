import Foundation
import AppKit

// MARK: - 夸克扫码登录（CAS 接口）+ cookie 校验

@MainActor
final class QuarkAuth {
    static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    static let qrURLPrefix = "https://su.quark.cn/4_eMHBJ"

    // MARK: 对外入口：确保有可用 cookie（优先复用旧部署的）

    /// cookie 检查结果三态：valid=有效 / invalid=失效 / networkError=检查失败（网络不通）
    enum CookieState {
        case valid, invalid, networkError
    }

    static func ensureCookie(state: AppState) async throws {
        // 1. 已部署目录里的 cookie
        if let c = readCookie(), await validate(c) == .valid {
            state.log("复用已保存的登录状态")
            try writeCookie(c)
            try await addStorage(state: state)
            return
        }
        // 2. 旧版手动部署的 cookie
        let legacy = Installer.legacyDir.appendingPathComponent(".quark-cookie")
        if let c = try? String(contentsOf: legacy, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !c.isEmpty, await validate(c) == .valid {
            state.log("从旧部署导入登录状态")
            try writeCookie(c)
            try await addStorage(state: state)
            return
        }
        // 3. 扫码
        state.phase = .qr
        state.qrImage = nil
        state.qrHint = "正在获取二维码…"
        let cookie = try await qrLogin(state: state)
        state.phase = .running
        state.qrImage = nil
        try writeCookie(cookie)
        state.log("登录成功，cookie 已保存")
        try await addStorage(state: state)
    }

    /// 写 cookie 文件（600 权限）；失败必须抛出，不能静默
    static func writeCookie(_ c: String) throws {
        do {
            try c.write(to: Installer.cookieFile, atomically: true, encoding: .utf8)
            try Installer.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Installer.cookieFile.path)
        } catch {
            throw InstallError(message: "登录状态保存失败：\(error.localizedDescription)")
        }
    }

    static func hasValidCookie() async -> CookieState {
        guard let c = readCookie() else { return .invalid }
        return await validate(c)
    }

    private static func readCookie() -> String? {
        guard let c = try? String(contentsOf: Installer.cookieFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty else { return nil }
        return c
    }

    // MARK: 扫码流程

    static func qrLogin(state: AppState) async throws -> String {
        // 1. token
        let rid = UUID().uuidString
        guard let tokenURL = URL(string: "https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin?client_id=532&v=1.2&request_id=\(rid)") else {
            throw InstallError(message: "二维码接口地址错误")
        }
        var req = URLRequest(url: tokenURL)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        let (td, _) = try await URLSession.shared.data(for: req)
        let tj = (try? JSONSerialization.jsonObject(with: td) as? [String: Any]) ?? [:]
        guard tj["status"] as? Int == 2000000,
              let token = ((tj["data"] as? [String: Any])?["members"] as? [String: Any])?["token"] as? String else {
            throw InstallError(message: "获取二维码失败：夸克接口无响应")
        }

        // 2. 二维码图片
        let qrText = "\(qrURLPrefix)?token=\(token)&client_id=532&ssb=weblogin&uc_param_str=&uc_biz_str=S%3Acustom%7COPT%3ASAREA%400%7COPT%3AIMMERSIVE%401%7COPT%3ABACK_BTN_STYLE%400"
        state.qrImage = makeQR(qrText)
        state.qrHint = "请用夸克 APP 扫描上方二维码，并在手机上确认登录"
        state.log("二维码已生成，等待扫码（3 分钟有效）")

        // 3. 轮询
        let deadline = Date().addingTimeInterval(180)
        var ticket: String?
        var left = 180
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            left -= 2
            state.qrCountdown = max(0, left)
            guard let pollURL = URL(string: "https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken?client_id=532&v=1.2&token=\(token)&request_id=\(UUID().uuidString)") else { continue }
            var preq = URLRequest(url: pollURL)
            preq.setValue(ua, forHTTPHeaderField: "User-Agent")
            preq.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
            guard let (pd, _) = try? await URLSession.shared.data(for: preq),
                  let pj = (try? JSONSerialization.jsonObject(with: pd) as? [String: Any]) else { continue }
            let st = pj["status"] as? Int ?? 0
            if st == 2000000 {
                ticket = ((pj["data"] as? [String: Any])?["members"] as? [String: Any])?["service_ticket"] as? String
                state.qrHint = "扫码成功，正在获取登录凭证…"
                break
            } else if st == 50004002 {
                state.qrHint = "二维码已过期"
                throw InstallError(message: "二维码已过期，请重新开始")
            } else if st == 50004001 {
                state.qrHint = "等待扫码…（\(max(0, left)) 秒后过期）"
            }
        }
        guard let ticket else {
            throw InstallError(message: "扫码超时，请重新开始")
        }

        // 4. 换 cookie
        clearQuarkCookies()
        guard let infoURL = URL(string: "https://pan.quark.cn/account/info?st=\(ticket)&lw=scan") else {
            throw InstallError(message: "登录接口地址错误")
        }
        var ireq = URLRequest(url: infoURL)
        ireq.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (_, _) = try await URLSession.shared.data(for: ireq)
        var cookie = collectQuarkCookies()
        guard !cookie.isEmpty else {
            throw InstallError(message: "登录失败：未获取到 cookie")
        }

        // 5. 补 __puus（失败重试一次；缺失会导致下载 403，必须尽量拿到）
        var puusOK = false
        for attempt in 0..<2 {
            if let cfgURL = URL(string: "https://drive-pc.quark.cn/1/clouddrive/config?pr=ucpro&fr=pc&uc_param_str=") {
                var creq = URLRequest(url: cfgURL)
                creq.setValue(ua, forHTTPHeaderField: "User-Agent")
                creq.setValue("https://pan.quark.cn", forHTTPHeaderField: "Referer")
                creq.setValue(cookie, forHTTPHeaderField: "Cookie")
                if let (_, resp) = try? await URLSession.shared.data(for: creq),
                   (resp as? HTTPURLResponse)?.statusCode == 200 {
                    puusOK = true
                    let extra = collectQuarkCookies()
                    if extra.count > cookie.count { cookie = extra }
                    break
                }
            }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        }
        if !puusOK {
            state.log("⚠️ 补充登录凭据(__puus)失败，部分下载可能受限；如遇问题请重新扫码")
        }

        // 6. 校验
        guard await validate(cookie) == .valid else {
            throw InstallError(message: "登录失败：cookie 校验未通过，请重试")
        }
        return cookie
    }

    // MARK: cookie 工具

    /// 验证 cookie：valid=可用 / invalid=已失效 / networkError=网络不通（无法判断）
    static func validate(_ cookie: String) async -> CookieState {
        guard let url = URL(string: "https://drive.quark.cn/1/clouddrive/file/sort?pr=ucpro&fr=pc&pdir_fid=0&_page=1&_size=5&_sort=file_type:asc,file_name:asc") else { return .invalid }
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://pan.quark.cn", forHTTPHeaderField: "Referer")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.timeoutInterval = 15
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return .networkError      // 请求失败 = 网络问题，不是 cookie 失效
        }
        return (j["code"] as? Int) == 0 ? .valid : .invalid
    }

    private static func clearQuarkCookies() {
        let storage = HTTPCookieStorage.shared
        for c in storage.cookies ?? [] where c.domain.contains("quark.cn") {
            storage.deleteCookie(c)
        }
    }

    private static func collectQuarkCookies() -> String {
        let storage = HTTPCookieStorage.shared
        let parts = (storage.cookies ?? [])
            .filter { $0.domain.contains("quark.cn") }
            .map { "\($0.name)=\($0.value)" }
        return parts.joined(separator: "; ")
    }

    // MARK: 二维码图片（CoreImage，零依赖）

    static func makeQR(_ text: String) -> NSImage? {
        guard let data = text.data(using: .ascii) else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage else { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }

    // MARK: 添加夸克存储（幂等；任何失败都抛出，绝不静默「假完成」）

    static func addStorage(state: AppState) async throws {
        guard let c = readCookie() else {
            throw InstallError(message: "登录状态文件缺失，无法配置存储")
        }
        let pass = (try? String(contentsOf: Installer.passFile, encoding: .utf8)) ?? ""
        let token: String
        do { token = try await Installer.apiLogin(pass) }
        catch { throw InstallError(message: "本地服务登录失败，无法配置存储：\(error.localizedDescription)") }

        func api(_ method: String, _ path: String, body: Any? = nil) async throws -> (Int, [String: Any]) {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(Installer.port)\(path)")!)
            req.httpMethod = method
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(token, forHTTPHeaderField: "Authorization")
            if let b = body { req.httpBody = try JSONSerialization.data(withJSONObject: b) }
            let (d, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
            return (code, j)
        }

        let addition: [String: Any] = [
            "cookie": c,
            "root_folder_id": "0",
            "order_by": "none",
            "order_direction": "asc",
            "use_transcoding_address": false,
            "only_list_video_file": false,
        ]
        let additionStr = (try? JSONSerialization.data(withJSONObject: addition))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        // 找已有的 Quark 存储
        let (_, list) = try await api("GET", "/api/admin/storage/list")
        let existing = ((list["data"] as? [String: Any])?["content"] as? [[String: Any]] ?? [])
            .filter { ($0["driver"] as? String) == "Quark" }

        if let old = existing.first, let oldId = old["id"] as? Int {
            // 优先原地更新（不删旧配置——删了建失败就没有退路）
            var body = old
            body["addition"] = additionStr
            let (ucode, uresp) = try await api("POST", "/api/admin/storage/update?id=\(oldId)", body: body)
            if ucode == 200, (uresp["code"] as? Int) == 200 {
                state.log("夸克存储已更新（登录状态已刷新）")
                return
            }
            state.log("存储更新接口不可用（HTTP \(ucode)），改用删除重建…")
            let (dcode, dresp) = try await api("POST", "/api/admin/storage/delete?id=\(oldId)")
            guard dcode == 200, (dresp["code"] as? Int) == 200 else {
                throw InstallError(message: "移除旧存储失败：\(dresp["message"] as? String ?? "HTTP \(dcode)")")
            }
        }

        let body: [String: Any] = [
            "mount_path": "/quark",
            "order": 0,
            "driver": "Quark",
            "cache_expiration": 0,
            "web_proxy": false,
            "addition": additionStr,
        ]
        let (ccode, cresp) = try await api("POST", "/api/admin/storage/create", body: body)
        guard ccode == 200, (cresp["code"] as? Int) == 200 else {
            throw InstallError(message: "夸克存储添加失败：\(cresp["message"] as? String ?? "HTTP \(ccode)")")
        }
        state.log("夸克网盘存储已添加")
    }
}
