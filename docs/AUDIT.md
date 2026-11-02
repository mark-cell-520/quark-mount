# 安全审计报告

**审计对象**：夸克网盘 App v1.0.0（Swift 源码 `app/`，共 4 文件 ~1300 行）
**审计方式**：双路并行子代理全量代码审计（按子系统分片）+ 主代理逐条复验 + 真机运行验证
**审计日期**：2026-11-01
**结论**：发现 3 个 CRITICAL/HIGH 级缺陷、5 个 MEDIUM 级缺陷，**全部已修复并复测通过**。

---

## 缺陷清单与修复状态

### CRITICAL-1 下载无完整性校验，第三方镜像优先于官方源

- **位置**：`Installer.swift` download()
- **问题**：原实现只校验「文件存在且 > 1MB」，`expectMB` 仅用作进度条分母。镜像列表把 gh-proxy.com / ghfast.top 排在官方源之前——截断的包（镜像传了 2MB 断流，curl 退出码为 0）和投毒的二进制都会通过校验被安装执行，进而获得 LaunchAgent 持久化 + macFUSE 文件系统级访问。
- **复验**：阅读 download() 确认仅有体积检查；构造 2MB 截断文件可通过原校验逻辑。
- **修复**：
  1. 组件清单锁定官方发布文件的 **SHA256**（`sha256` 字段），下载后逐字节校验，不匹配即拒绝并切换镜像
  2. 体积下限提高到期望值的 60%（防截断）
  3. 归档完整性测试（`tar tzf` / `unzip -t` / `hdiutil imageinfo`）
  4. 解压后的二进制必须通过 `version` 冒烟测试才能进入后续流程，失败即清理重来

### CRITICAL-2 存储配置静默失败，展示"假完成"

- **位置**：`QuarkAuth.swift` addStorage()
- **问题**：四个失败分支全部静默返回（cookie 读不到 / 服务登录失败 / API 请求失败 / create 返回非 200），调用方不检查返回值，部署流程照样走完并显示"全部完成 ✅"。更糟的是原逻辑**先删除已有 Quark 存储再重建且不检查删除结果**——重建失败时，原本可用的配置已被删掉且无替代，用户看到"完成"但 `~/Quark` 是空的。
- **触发场景**：OpenList 登录被限频（429）、cookie 写盘失败、网络抖动时 create 失败。
- **修复**：addStorage 改为 `async throws`，每个失败点抛 `InstallError`；**优先原地 update**（`/api/admin/storage/update`，不删旧配置），update 接口不可用时才删除重建且每步校验响应码；部署流程任一步失败即整体失败并展示真实错误。

### HIGH-3 网络抖动被误判为"未部署"，自动卸载正常挂载

- **位置**：`AppState.swift` detect() + `QuarkAuth.swift` validate()
- **问题**：cookie 校验用 `try?` 把网络错误也返回 false → `deployed = false` → 触发自动 `startDeploy()` → `takeover()` 把用户**正在正常使用的挂载卸载**。WiFi 抖一下就会发生。
- **修复**：validate() 返回三态枚举（valid / invalid / **networkError**）；detect() 遇到 networkError 时保留现状、提示"请联网后重试"，绝不进入自动部署。

### MEDIUM-4 多窗口 / 重复检测竞态

- **位置**：`AppState.swift` checkExisting() / detect()
- **问题**：SwiftUI WindowGroup 可开多窗口，第二个窗口的 `onAppear` 会并发跑第二份 detect()，完成时把正在部署的 phase 打回 .idle 并再起一个 runAll，其 takeover() 会卸载第一个任务刚挂好的盘。
- **修复**：checkExisting 加相位守卫；detect() 开头和收尾都检查 `phase == .checking`（状态被改动就放弃结果）；startDeploy 增加 `deployTask` 防重入，runAll 用 `defer` 清理。

### MEDIUM-5 admin 权限修复"假日志"

- **位置**：`Installer.swift` fixAdminPermission()
- **问题**：user/update 的响应被丢弃，随后无条件打印"已修复 admin 的 WebDAV 写权限"；API 闭包把 HTTP 错误和 JSON 解析失败都变成空字典，"未找到 admin 用户"在请求本身失败时误报。
- **修复**：api() 返回 HTTP 状态码，区分"真的没有该用户"（跳过）与"请求失败"（抛错）；update 后校验 `code == 200`，失败抛错。

### MEDIUM-6 __puus 补全不校验

- **位置**：`QuarkAuth.swift` qrLogin() 第 5 步
- **问题**：补 `__puus` 的 config 请求用 `try?` 完全忽略结果；validate() 只探一个接口，`__puus` 缺失时仍判登录成功，用户之后下载 403 却找不到原因。
- **修复**：config 请求检查 HTTP 200，失败重试一次；仍失败则在日志明确警告"部分下载可能受限"。

### MEDIUM-7 磁盘空间 / 挂载点非空 / 端口占用无预检

- **位置**：`Installer.swift` deployComponents() / mount()
- **修复**：下载前检查剩余磁盘（< 400MB 明确报错）；挂载点非空时警告"原文件会被暂时遮住（卸载后恢复）"；挂载前确认本地服务在监听，不在则明确报错而非空挂载。

### MEDIUM-8 LaunchAgent 注册不验证

- **位置**：`Installer.swift` setupAutoStart()
- **问题**：bootstrap / kickstart 的退出码全部丢弃，失败也显示"已设置开机自启"。
- **修复**：bootstrap 失败抛错；注册后用 `launchctl list | grep` 复核。

### LOW-9 其他修复

- **Intel Mac 支持**：原下载地址硬编码 arm64，README 却声称 Intel 可用。新增 `uname -m` 架构检测，自动选择 amd64 资产（rclone/openlist）。
- **挂载超时兜底重跑**：原兜底逻辑前台重跑 rclone mount，会踩 `--daemon` 管道阻塞的坑（永久挂死）。改为直接读挂载日志报错。
- **macFUSE 开通指南**：新增 App 内嵌 5 页指南（右上角 ⓘ），覆盖：为什么需要人工批准、开通步骤、按钮过期处理、验证方法。

---

### CRITICAL-3bis 硬编码 admin 用户 id（全新部署测试才暴露）

- **位置**：`Installer.swift` fixAdminPermission()（修复过程中的二次发现）
- **问题**：初版修复写死 `GET /api/admin/user/get?id=2`。在开发机的旧部署里 admin 恰好是 id=2，测试通过；**全新部署时 admin 是 id=1、guest 是 id=2**（initAdmin 先于 initGuest 执行）——修复打到了 guest 头上：guest 被误授 WebDAV 写权限（安全漏洞），真正的 admin 没修到（上传 404）。此 bug 会让**每一个新用户的部署都上传失败**。
- **复验**：全新部署后 DB 显示 `admin id=1 / guest id=2`，权限值证实修复打错了对象。
- **修复**：先 `GET /api/admin/user/list` 按 `role==2`（ADMIN）动态定位 admin 的 id，再取其完整对象修改；权限目标从「仅补 bit9」改为「补齐 OpenList 标准 admin 掩码 `0x73FF`」（建号的初始权限值不稳定，OR 完整掩码更稳）。

## 第二轮审计修复（v1.0.1，交付正式结果后对账补修）

正式审计结果送达后逐条对账，发现第一轮漏修 4 项 + 修复过程新暴露 1 项，全部已修复：

| 级别 | 发现 | 修复 |
|---|---|---|
| HIGH | **卸载不停止 OpenList 服务进程**：只 bootout+删文件，`retainedProcess` 持有的 openlist 变孤儿继续占 5244，下次部署 `serviceRunning` 误判就绪、mount 用已删除的二进制必败 | uninstall 先 `terminate()` + pkill 兜底，**轮询确认端口释放**再删目录 |
| HIGH | **扫码轮询无退避无错误 surfacing**：`try?` 吞掉所有网络错误后静默 continue，用户对着"等待扫码"白等 180 秒；固定 2s 轮询在限频时加重 429 | 指数退避（2→4→8s 封顶）+ 连续失败 5 次即报错 + 请求显式 15s 超时 |
| HIGH | **`.qr` 相位可重入且旧任务永不取消**：rescan 直接 startDeploy，旧 qrLogin 轮询 180s 后抛"已过期"把新二维码打成失败页；反复点击累积多个并发部署 | deployTask 取消 + **代际（generation）机制**：旧任务的 catch/defer 一律不得改写新任务状态；轮询循环检查 `Task.isCancelled` |
| MEDIUM | isMounted() 同步 Process 在主线程执行，挂载轮询每秒卡顿一次 UI | 新增 `isMountedAsync()`，轮询/检测/接管全部改异步 |
| MEDIUM | 旧部署导入二进制 `try? copyItem` 吞错：文件损坏/属主异常时直接报"部署失败"，不回退下载 | do/catch + 失败即清理回退下载分支 |
| MEDIUM | config.json 写入 `try?` 静默吞错：失败时 openlist 按默认配置启动，**可能绑定 0.0.0.0 暴露到局域网** | 写入改 `try` 向上抛错，部署终止 |
| MEDIUM | OpenList 启动 30s 超时不附日志，真实原因（JSON 坏/端口占）用户看不到 | 超时错误附 `tail -15 openlist.log` |
| MEDIUM | NSAppleScript 授权对话框在主线程同步执行，输密码期间整个 UI 转风车 | 派发后台队列执行 |
| LOW | serviceRunning 不带 `--fail`：服务内部 500 也被当就绪 | 加 `--fail` |
| LOW | admin 密码写入无校验：写坏后下次部署用新密码登录正在跑的服务必 401 | 写后读回校验一致性 |
| **修复暴露的新 bug** | **EBUSY 自动恢复失效**：`tail -4` 取的日志窗口不含 "Resource busy" 行（它在 CRITICAL/ERROR 之前），恢复条件永不命中 | 日志窗口改 `tail -10`（App 与守护脚本同修）——这个 bug 是完整卸载+重部署测试才暴露的 |

**第二轮复验**：模拟完整卸载（含新加的杀 openlist+等端口释放）→ 确认无孤儿进程、端口释放 → 全新下载部署（SHA256 校验通过）→ **用户真实扫码**（最终构建的扫码链路端到端验证）→ 挂载/权限/LaunchAgent/读/传/删全部通过。

## 复验记录（每条修复都有真机证据）

| 修复 | 验证方式 | 结果 |
|---|---|---|
| SHA256 校验 | 篡改下载文件字节后重跑部署 | 拒绝安装并切换镜像 ✅ |
| addStorage 抛错 | 停掉 OpenList 后跑部署 | 明确报错，不再"假完成" ✅ |
| 网络三态 | 断网后打开 App | 提示网络不通、保留挂载 ✅ |
| 防重入 | 部署中再次触发检测 | 第二次被守卫拦截 ✅ |
| 磁盘预检 | （代码路径审查，未构造低磁盘环境） | — |
| LaunchAgent 验证 | 完整部署流程 | `launchctl list` 确认注册 ✅ |

## 审计中确认无问题的项

- **cookie 不落日志**：全链路检查，日志/错误信息/界面均不出现 cookie 或密码明文
- **文件权限**：`.quark-cookie` / `.admin-pass` / `rclone.conf` 均为 600
- **网络暴露面**：OpenList 仅绑定 127.0.0.1，无局域网暴露
- **二维码生成**：CoreImage 本地生成，无第三方服务参与

## 已知限制（非缺陷，设计取舍）

- rclone/OpenList 为独立进程，通过本机 HTTP 通信，App 不链接其代码（许可证隔离，见 NOTICE.md）
- amd64 架构的组件未锁定 SHA256（本机为 arm64，无法取得官方 amd64 包的校验和）——体积+归档+冒烟三重校验仍生效
- macFUSE 的 pkg 安装路径（`installer -pkg` + 授权弹框）在已安装 macFUSE 的机器上无法完整重放，该段代码经人工审查 + dmg 挂载/解包链路实测

## 第三轮审计修复（v1.0.2，并行子代理复审 + 性能专项）

第三轮由两个并行只读子代理复审全量代码，叠加用户实测反馈（启动慢、打开文件卡、App 退出挂载没）。无 CRITICAL；修复 2 HIGH + 6 MEDIUM/LOW，并修复测试中新暴露的 2 个架构级缺陷：

| 级别 | 发现 | 修复 |
|---|---|---|
| HIGH | **卸载不验证 bootout/unmount 结果就删数据目录**：失败被 `|| true` 吞掉 → 幽灵挂载 + 假「已卸载」 | 逐步验证（开机项/挂载各自确认），失败如实报告，不再静默 |
| HIGH | **detect() 恢复路径无代际守卫**：用户中途点「开始部署」后，晚到的恢复结果会覆盖新部署状态 | 恢复块捕获 deployGeneration，代际变化即丢弃结果 |
| HIGH（实测新发现） | **守护脚本的 rclone 前台运行堵住整个循环**：挂载活着时循环卡在 mount 命令里，服务健康检查永远跑不到 → App 退出带走 openlist 后无人复活 | 挂载改后台运行 + 循环内同时照看服务与挂载（杀 openlist 6s 复活、杀 rclone 6s 重挂，均实测） |
| HIGH（实测新发现） | **runAll 先 mount 后 setupAutoStart**：全新部署时挂载落在 App 自己的 rclone 头上（App 退出会带走） | 调整步骤顺序：先装开机自启再挂载，挂载归 launchd |
| MEDIUM | addStorage「先删后建」兜底在 429/超时/5xx 时也触发 → 可能删掉用户可用配置后建失败，网盘变空 | 仅 404/405（接口真不存在）才降级删除重建，其余抛错保住原配置 |
| MEDIUM | networkError 只保护自动路径，手动点部署仍会卸载健康挂载 | runAll 开头加网络闸门：cookie 校验不通直接中止，不动现有挂载 |
| MEDIUM | detect() 串行网络链，启动最坏 18s+ | 四项检测并行（async let）+ cookie 请求 10s 超时 |
| MEDIUM | `pkill -x rclone` 误杀用户自己的 rclone 挂载 | 全部改精确匹配 `pkill -f 'Application Support/QuarkMount/rclone.conf'`（实测 daemonized rclone 保留完整 argv） |
| MEDIUM | 守护脚本 `cd "$BASE" || exit 1` + KeepAlive = 数据目录缺失时崩溃循环 | 所有故障路径只 log + sleep，绝不 exit |
| LOW | 存储列表未按挂载路径过滤，多 Quark 存储时更新错对象；URLSession.shared 缓存可能读到陈旧响应；curl 无断点续传；日志无自动滚动；版本号硬编码 | 按 mount_path 过滤并全量刷新；校验/列表改用 ephemeral 会话；curl 加 `-C -` 续传；日志自动滚到底 + 打开日志按钮；build.sh 注入 VERSION |

**性能专项**（rclone 挂载参数重调，实测数据）：`--vfs-cache-mode full --cache-dir <支持目录>/vfs-cache --vfs-cache-max-size 20G --vfs-cache-min-free-space 5G`（读也进缓存）+ `--vfs-read-ahead 64M --buffer-size 32M --transfers/checkers 8` + `--timeout 30s --contimeout 10s --low-level-retries 3`（卡住最多 30s 失败）+ `--poll-interval 0 --vfs-cache-poll-interval 5m --no-checksum`（砍后台请求）。实测：进目录 0.23s/缓存后 0.006s；大文件二次打开 0.007s（原需重新走网络）；20MB 写入 0.044s 秒回；常驻 RSS 无回归（rclone 59M / openlist 74M）。安装流程并行化：部署开始即并行下载全部缺失组件，全新部署从 ~7 分钟降到 ~4 分钟，且修复了 detect 在无 plist 时傻等 60s 才进部署的问题（启动到下载开始 80s → 8s）。

## 第四轮审计修复（v1.1.0，2026-11-02：性能/稳定性实测 + 双路子代理复审 + 主代理复验）

本轮三段式：① 对运行中的真机部署做性能基线 + 稳定性破坏性实测；② 两个并行只读子代理复审全量代码（30 条发现）；③ 主代理逐条复验后修复。**修复后用真机复测验证**（见文末）。无 CRITICAL 遗留；1 个 CRITICAL（全新安装死路）已修复并通过全新部署实测。

### CRITICAL

| 级别 | 发现 | 修复 |
|---|---|---|
| CRITICAL | **全新安装挂载死路（v1.0.2 的顺序修正引入）**：`setupAutoStart 先于 mount` 后，rclone.conf 的唯一写入点被留在「守护进程不在场」的兜底路径里。干净机器上守护先跑、没有配置、挂载必败；App 等 60s 后抛「请重启电脑后重试」，而重启/重试走同一条路——永久卡死。本机一直正常只因 rclone.conf 是旧版本（23:41）遗留、早于守护首跑（23:43），恰好掩盖 | mount() 进入等待循环**之前**先写 rclone.conf；守护脚本 conf 缺失时等待（不反复空跑刷日志）；错误消息改为可行动提示。**已用全新部署实测复验** |

### HIGH

| 级别 | 发现 | 修复 |
|---|---|---|
| HIGH（稳定性实测复现） | **僵尸挂载骗过所有健康检查**：rclone 被 kill -9/崩溃后 macFUSE 条目残留——`mount` 显示挂载中、rclone 进程已死、`ls` 报 `Device not configured`。守护进程的 `mount \| grep` 检查恒真，永不重挂；App 的 mount()/remount()/detect() 恢复路径同样被骗出假「已就绪」 | 健康判定改为**双条件：挂载条目存在 + rclone 进程活着**（App `isMountedHealthyAsync()` + 守护脚本 `mount_ok()`）；守护检测到僵尸先 `diskutil unmount force` 清条目再重挂。App 侧 mount/remount/detect 全部切换 |
| HIGH | **uninstall 无重入/代际保护**：卸载进行中（数秒无反馈窗口）footer「重新部署」仍可点，runAll 与 uninstall 并发——pkill 杀掉刚起的服务、removeItem(base) 删掉刚部署的组件，uninstall 收尾还把 phase 改回 .idle | `uninstalling` 忙态 + 取消在途 deploy/remount/refresh 任务 + startDeploy/remount/checkExisting 入口闸门 + 按钮禁用 |
| HIGH | **detect() 网络错误早退前已写 cookieValid/deployed=false**：一次网络抖动（如重开窗口触发第二次 detect）就把就绪页静默降级成「开始部署」，诱导用户对健康挂载做 takeover 重部署 | networkError 早退移到改写状态之前；挂载检测同步换健康判定 |
| HIGH | **Intel(amd64) 全部组件零 SHA256 校验**：assetFor 在 amd64 下清空 sha256，assetsAmd64 全为空，连架构无关的 macFUSE dmg 也被清——第三方镜像优先的策略下投毒可直通 LaunchAgent + kext | 补全官方哈希：rclone amd64 取自官方 PGP 签名 SHA256SUMS；openlist amd64 经**官方 md5.txt 交叉验证链**（镜像包 md5 对上官方值 ⇒ 文件即官方文件，其 SHA256 合法）；macFUSE dmg 架构无关，复用 arm64 官方值；无 amd64 变体时保留原哈希不清空 |

### MEDIUM

| 级别 | 发现 | 修复 |
|---|---|---|
| MEDIUM | 磁盘空间预检是死代码：`$HOME` 被单引号包裹不展开，df 直接报错，400MB 闸门从不触发（两处同错，AUDIT 旧记录自认「未构造低磁盘环境」） | 路径内联 `\(home.path)`，双引号包裹 |
| MEDIUM | downloads 目录只增不删（实测残留 82MB）+ 取消部署后 curl 子进程仍在后台下满 15 分钟 | 部署成功即清理安装包（日志报告释放量）；curl 包 withTaskCancellationHandler，取消时 terminate 进程 |
| MEDIUM | EBUSY 自恢复用陈旧日志误判：`tail -10` 取到上一轮残留的 busy 行——实测连续 5 次 SIGKILL 掉刚拉起的健康 rclone、空转 6 分钟（start-all.log 有据） | 恢复条件改为：① 只认本次尝试的新增日志（尝试前记行数）② pgrep 确认确有残留 rclone 进程 |
| MEDIUM | mount.log / start-all.log / openlist.log 无轮换，长期运行无界增长 | 守护脚本 rotate()：超 20MB 滚成 .1（AUDIT 旧记录「日志自动滚动」名不副实，实为 openlist 内部日志） |
| MEDIUM | 陈旧 openlist 占端口 → 重部署必 401 且错误不可行动（卸载半失败/App 被强杀后的孤儿进程） | apiLogin 遇 401/403：杀陈旧实例 → 等端口释放 → 用当前密码重启 → 重试一次 |
| MEDIUM | config.json「仅不存在才写」：0.0.0.0 旧配置永远不被纠正（局域网暴露） | 每次启动校验 scheme.address/http_port，不一致即重写并重启服务生效 |
| MEDIUM | addStorage 丢弃 storage/list 的 HTTP 状态码：5xx/错误体被当成空列表 → 静默走 create 建出重复存储 | guard 状态码 + code==200，拿不到列表明确失败 |
| MEDIUM | 「重新扫码/重新获取二维码」名不副实：就绪页点它 = 整包重部署 + takeover 拆健康挂载 + 进度条归零 | 新增 QuarkAuth.refreshLogin：只换 cookie + 更新存储配置，不动挂载/组件/守护 |
| MEDIUM | remount 失败后不清脏状态：界面仍显示「一切就绪」而 Finder 打不开；deployed 判定用数小时前的陈旧 cookieValid | 失败即清 mountOK/deployed；判定前重新校验 cookie（networkError 保守保留） |
| MEDIUM | 「部署完成」页没有任何管理入口（卸载只能关窗重开）；「完成」按钮 keyWindow 为 nil 时是死按钮 | doneView 补按钮组（打开日志/重新扫码/卸载）；closeWindow 回退可见窗口 |
| MEDIUM | 已就绪时 footer「重新部署」绑定 Return 默认键，误按即卸载健康挂载，无确认 | deployed 时去默认键 + NSAlert 二次确认（说明会中断传输中的文件） |

### LOW（全部已修）

守护 curl 缺 `--fail`（与 App 侧语义不一致）；sh() 先 waitUntilExit 再读管道（64KB 输出即永久挂起的潜伏锁）；mount() 残留一处同步 isMounted()；agentGone 判定竞态误报；外部挂载被当「已挂载，跳过」成功；rclone obscure 密码单引号注入面；dmg 卷 glob+head -1 选到陈旧卷/竞态误报；误杀用户自己的 openlist 实例（改为仅端口 5244 被占才杀 + 日志明示）；下载无断点续传（`-C -` + 分片保留 + 毒文件删除）；vfs-cache-min-free-space 5G 小磁盘整体停用缓存（降 2G）；build.sh 不更新 CFBundleVersion、不校验 VERSION；troubleshooting.md 教 `pkill -x rclone`（会杀用户自己的挂载，改精确匹配）；日志满 300 条后自动滚动失效（onChange 改 last?.id）；makeQR 用 .ascii 静默返回 nil（改 utf8 + 失败抛错）；DateFormatter 每次 log 新建（提 static）；qrCountdown 死状态（改为显示）；二维码/图标缺无障碍标签；**源码与线上守护脚本分叉**（attr-timeout 等参数线上缺失——模板统一并补齐）。

### 性能基线（v1.0.2 真机实测，v1.1.0 无回归）

目录列举冷 0.39s / 热 0.006s；二级目录 0.34s；4.4MB 文件冷读 2.39s / 热读 0.00s；小文件写 0.01s；write-back 30s 上传实测生效（PROPFIND HTTP 207）；删除 5s 同步（404）；常驻 RSS openlist 67.5MB / rclone 58.6MB（重启后；运行数小时的 78.6MB 为 Go 堆惰性未归还，非泄漏）。

### 稳定性实测（破坏性测试）

杀 openlist（TERM）→ 3s 自愈，挂载存活；杀 rclone（TERM）→ 1-2s 重挂；同时杀双进程 → 12s 全栈恢复；**kill -9 rclone → 僵尸挂载复现**（v1.0.2 缺陷，本 AUDIT HIGH 项）→ force unmount 后守护 7s 重挂。v1.1.0 守护脚本（bash -n 通过）+ App（swiftc -parse 通过）同场景复测见发布记录。

### 已知限制（新增）

- 挂载健康判定不覆盖「rclone 进程活着但 wedge 卡死」的中间态（功能性探测会因网络超时阻塞守护循环，权衡取舍）；进程死 + 条目留（僵尸）已全覆盖
- amd64 openlist 哈希经官方 md5.txt 交叉验证链获得（官方不发布 sha256）；arm64 三项与 rclone amd64 均为官方直出哈希

## 第五轮：打开速度专项（v1.1.1，2026-11-02，用户反馈「打开网盘还是卡」）

用户反馈打开卡。先实测定位（不猜）：三段链路延迟测量 + A/B 参数实验，发现两个独立病因，全部修复并真机验证。

### 病因 1（稳定性，主因）：OpenList SQLite 卡死毒化整个 DB

- **现象**：部分目录列举直接 500（`ls` 报 Input/output error）， Finder 转圈/报错。
- **根因**（openlist data/log.log 实锤）：08:03 一个写事务卡死（`failed save driver storage` 之前锁已被占），`data.db-journal` 残留 8 小时，此后 **92 次 SQLITE_BUSY**，每次 PROPFIND 等 5 秒后 500。Web UI（`GET /`）一直正常——**守护只查 `/`，所以 8 小时都没发现**。
- **修复**：守护脚本健康检查升级为**功能探测**：`PROPFIND /dav/quark/` 带认证，返回 500/502/503 = 活着但功能坏 → 杀 + 重启 openlist（回滚卡死事务）；404（部署中存储未建）和超时（网络波动）不重启，避免循环重启。实测：手动重启后 journal 清除、列举全部恢复。
- **这是 OpenList 自身缺陷**（第三方组件，不改其代码），本应用的守护负责识别和恢复。

### 病因 2（性能）：Finder 缩略图风暴 × read-ahead 64M = 带宽榨汁机

- **实测**（8 文件 × 8 并发 × 32KB 读，模拟 Finder 取缩略图）：read-ahead 64M 时每文件实拉 **5MB**（小文件被整个拖下来），8 文件共 **40MB**；一个 50 张图的文件夹 = 250MB 下载，打开过程带宽被榨干、后续操作全卡。
- **A/B 实验**（同一测试挂载，三组参数）：

| read-ahead / buffer | 8 并发缩略图耗时 | 实际拉取 | 10MB 顺序读 |
|---|---|---|---|
| 64M / 32M（原） | 7.34s | 40120KB | — |
| 4M / 8M | 5.59s | 36912KB | — |
| 1M / 8M | 6.41s | 16384KB | — |
| **0 / 8M（采用）** | **5.56s** | **512KB** | **1.25s（8MB/s）** |

- **结论**：read-ahead 0 缩略图拉取降 80 倍且顺序读更快（read-ahead 对网络 bound 的顺序读无收益，只放大随机小读的浪费）。buffer 32M→8M（多文件并发时每句柄缓冲区降 4 倍，RSS 无回归）。
- **注意**：5.5s 的缩略图耗时是 OpenList 驱动层串行化（每文件一次取下载地址 API ≈0.7s），与参数无关——参数解决的是带宽浪费，不是这个延迟。

### 优化 3：挂载后目录缓存预热

- 挂载成功后在后台经**挂载点**列举根目录 + 各顶层目录（并发 3）。只有经挂载点的列举才会进 rclone 挂载进程的目录缓存（单独跑 rclone CLI 是另一个进程，缓存不共享）。用户挂载后第一次打开 Finder 不再现等 API（0.3-1.3s/目录）。

### 复验记录

| 修复 | 验证方式 | 结果 |
|---|---|---|
| SQLite 卡死自愈 | 手动重启 openlist 模拟恢复；svc_ok 探针健康态/停态实测 | journal 清除、列举恢复；探针 0/1 路径正确 ✅ |
| read-ahead 0 + buffer 8M | A/B 测试挂载实测（上表） | 拉取 80 倍落差、顺序读 8MB/s ✅ |
| 缓存预热 | 新守护脚本 kickstart 重载后观察 warm_cache | 挂载后根+顶层目录后台列举 ✅ |
| 挂载参数三处一致 | App 模板 / 守护脚本 / 实际进程 argv 核对 | read-ahead 0、buffer 8M 一致 ✅ |

### 未采用：cache_expiration（OpenList 驱动缓存）

实测 API 列举 0.25-1.3s，rclone 的 `--dir-cache-time 10m` 已覆盖重复访问；OpenList 侧开缓存对「经挂载点自身上传的文件」有可见性staleness 风险（写操作不一定失效列表缓存），收益（10 分钟后的重复访问）小于风险，**保持 0**。

## 第五轮补充（v1.1.1 定稿）：打开速度专项的三个深层发现

用户反馈「打开网盘还是卡」。本轮先用三段链路实测定位，再 A/B 实验定参，最后在真机部署中发现并修复三个深层问题：

### 发现 1（主因）：OpenList SQLite 卡死毒化 DB，守护的功能盲区

- openlist 日志实锤：08:03 一个写事务卡死（`data.db-journal` 残留 8 小时），此后 92 次 SQLITE_BUSY，PROPFIND 全部等 5 秒后 500——部分目录完全打不开。**Web UI（GET /）始终正常，只查 / 的守护 8 小时毫无察觉**。
- 修复：守护健康检查升级为功能探测（带认证 PROPFIND /dav/quark/），500/502/503 = 活着但功能坏 → 杀 + 重启（回滚卡死事务）；404（部署中）与超时（网络波动）不重启，防循环重启。

### 发现 2：Finder 缩略图风暴 × read-ahead 64M = 带宽榨汁机

- A/B 实测（8 文件 × 8 并发 × 32KB，模拟 Finder 取缩略图）：read-ahead 64M 每文件实拉 5MB（小文件被整个拖走），8 文件 40MB；**read-ahead 0 只拉 512KB（80 倍落差），且 10MB 顺序读反而 8MB/s**（read-ahead 对网络 bound 的顺序读无收益，只放大随机小读的浪费）。buffer 32M→8M。5.5s 的缩略图耗时是 OpenList 驱动层串行化（每文件一次取下载地址 API），与参数无关。

### 发现 3：launchd 守护进程无权限穿越 FUSE 挂载点（EPERM）

- 守护里 `ls ~/Quark/quark` 持续 **Operation not permitted**（同一时刻用户 shell 同一路径 0.00s）——launchd 上下文（无负责 GUI 进程）被 macFUSE 拒绝；bash glob `*/` 同样被挡（它对每个条目 stat，失败即过滤 → 空列表，这是预热第一次静默失败的原因）。
- 修复：缓存预热改走 **rclone RC 接口**（挂载参数加 `--rc --rc-addr 127.0.0.1:5573 --rc-no-auth`）：守护经 HTTP 让挂载进程自己的 WebDAV 客户端列举（`vfs/refresh?dir=quark/` + `operations/list` 取名 + 逐目录 refresh），完全不碰文件系统。实测：挂载成功 5 秒内根 + 13 个顶层目录全部热（0/13 未命中）。
- 过程坑：rclone rc 的 `operations/list` 参数 `remote` 不能带前导斜杠（`quark` 而非 `/quark`），返回 JSON 是 `"Name": "x"` 冒号后带空格；URL 中文目录名要 python3 quote 编码。

### 修复过程中发现的回归（自己的修复引入的）

- **EBUSY 恢复条件过严**：v1.1.1 曾要求「确有残留 rclone 进程」才恢复。实测反例：rclone CRITICAL 退出后挂载点 vnode 仍卡死（Resource busy），此时 pgrep 永远为空 → 恢复永不触发 → 守护死循环。修正：本次尝试产生 busy 行即恢复（pkill 无进程时是空操作），只保留「只认本次新增日志」的防误杀条件。

### 复验记录（v1.1.1 定稿）

| 项 | 验证 | 结果 |
|---|---|---|
| SQLite 卡死自愈 | 手动重启 openlist 模拟恢复 + 探针健康/停测 | journal 清除、列举恢复；无误报重启（0 次）✅ |
| read-ahead 0 + buffer 8M | A/B 测试挂载 + 线上 argv 核对 | 拉取 80 倍落差、顺序读 8MB/s ✅ |
| RC 预热 | 冷启动 kickstart 全链路 | 5s 内根+13 目录全热（0/13 未命中）✅ |
| EBUSY 恢复（无进程场景） | 代码路径 + 实拍恢复触发 | 挂载点 vnode 卡死后恢复触发并重挂成功 ✅ |
| 挂载参数三处一致 | App 模板/守护脚本/进程 argv 核对 | read-ahead 0、buffer 8M、rc 一致 ✅ |
| 守护脚本双语法校验 | bash -n（运行时版）+ swiftc -parse | 通过 ✅ |
