# 故障排查

按症状查。每条都附了可复现的检查命令。

## 挂载相关

### 挂载后 `~/Quark` 打不开 / 一直转圈

**原因**：首次列目录要走完整链路（rclone → OpenList → 夸克 API），大网盘要几秒到几十秒。
**处理**：等 30 秒。还不行就看重试日志：

```bash
tail -20 ~/Library/Application\ Support/QuarkMount/mount.log
```

出现 `context deadline exceeded` 是夸克 API 慢，会自动重试，属正常。

### `~/Quark` 报「Device not configured」/ 文件夹图标在但打不开

**原因**：rclone 进程被强杀或崩溃后，macFUSE 挂载条目残留成「僵尸」——文件夹还在，文件系统已死，任何操作都报错。
**处理**：v1.1.0 起守护进程会自动识别（挂载条目 + rclone 进程双条件健康检查）并恢复，通常 10 秒内自愈。想手动处理：

```bash
diskutil unmount force ~/Quark     # 清掉残留条目，守护进程随后自动重挂
```

### 报错 `Resource busy` / `mount stopped before calling Init`

**原因 A（最常见）**：有残留的 rclone 守护进程占着挂载目录。检查（**精确匹配本应用的配置**——`pkill -x rclone` 会连用户自己的 rclone 挂载一起杀，别用）：

```bash
pgrep -fl 'Application Support/QuarkMount/rclone.conf'        # 有输出即有残留
pkill -f 'Application Support/QuarkMount/rclone.conf'        # 清理后重试
```

**原因 B**：挂载点目录被卡死的进程持有（异常强卸载导致）。处理：

```bash
rmdir ~/Quark && mkdir ~/Quark     # 换一个新目录节点
```

**原因 C**：macFUSE 驱动没加载。见下面「macFUSE」节。

### 重启后不自动挂载

检查 LaunchAgent：

```bash
launchctl list | grep com.quark.mount        # 应有一条记录
tail ~/Library/Application\ Support/QuarkMount/start-all.log
```

没有记录则重新在 App 里走一遍部署（会自动重装 LaunchAgent）。

## macFUSE 相关

### 部署卡在「检测 macFUSE」步骤

99% 是驱动没批准。打开 **系统设置 → 隐私与安全性**，点 macFUSE 旁的【允许】。
完整指南（含按钮过期处理）：[macfuse-activation.md](macfuse-activation.md)。

### `kextstat | grep fuse` 没输出

驱动没加载。手动触发：

```bash
/Library/Filesystems/macfuse.fs/Contents/Resources/load_macfuse
```

然后去系统设置点【允许】。

## 上传 / 删除相关

### 上传失败，日志里 403

旧版部署残留导致的服务端限频，或权限位缺失。处理：App 里「卸载」后重新部署一次；或检查：

```bash
curl -s -X POST http://127.0.0.1:5244/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"'$(cat ~/Library/Application\ Support/QuarkMount/.admin-pass)'"}'
```

返回 429（限频）就等几分钟再试。

### 改了一个文件，网盘里出现了两个

预期行为：夸克 Web 接口不支持覆盖上传，重传同名文件会生成 `file (1).ext`。重要文件先备份再改。

### 写完立刻删了，网盘里却没有

预期行为：写入有 30 秒回传延迟，这期间删除会取消上传。

## 登录相关

### 扫码没反应 / 二维码不动

二维码 3 分钟有效，过期后点 App 里的「重新扫码」。手机确认后如果还没反应，检查网络能否访问夸克：

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://pan.quark.cn/
```

应返回 200。

### 过一段时间文件列表突然为空 / 报未登录

cookie 过期了（1~3 个月）。App 里点「重新扫码」，30 秒解决。

## 下载 / 组件相关

### 部署卡在下载步骤

组件从 GitHub 官方 Release 下载，国内网络经镜像（gh-proxy → ghfast → 直连）自动切换。卡住可以：等 2 分钟（镜像切换），或切换网络后重试。

### 端口 5244 被别的程序占了

App 会检测并提示。查看占用者：

```bash
lsof -iTCP:5244 -sTCP:LISTEN      # 注意：本工具链不依赖 lsof，仅排查用
```

## 收集诊断信息

提交 issue 时附上：

```bash
ls ~/Library/Application\ Support/QuarkMount/        # 部署文件
tail -30 ~/Library/Application\ Support/QuarkMount/openlist.log
tail -30 ~/Library/Application\ Support/QuarkMount/mount.log
tail -30 ~/Library/Application\ Support/QuarkMount/start-all.log
kextstat | grep -i fuse
sw_vers
```

（日志里不含密码和 cookie，可以放心分享。）
