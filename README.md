# quark-mount

**把夸克网盘变成你的 Mac 本地磁盘 —— 一键部署，扫码即用。**

一个原生 macOS App：双击安装、打开、用夸克 APP 扫个码，你的夸克网盘就挂在 `~/Quark` 下了。Finder 直接浏览、复制、拖拽上传，开机自动挂载，掉线自动恢复。

[English](#english) · [macFUSE 开通指南](docs/macfuse-activation.md) · [架构说明](docs/architecture.md) · [故障排查](docs/troubleshooting.md)

---

## 它解决什么问题

夸克网盘没有官方 macOS 客户端，网页端下载大文件慢、不能当磁盘用。本项目用一套开源栈把它完整地接到 Mac 上：

```
┌─────────────┐     ┌──────────────┐     ┌────────────┐     ┌──────────┐
│  Finder /   │     │   rclone     │     │  OpenList  │     │  夸克    │
│  任意 App   │ ◄── │  (FUSE 挂载)  │ ◄── │  (WebDAV   │ ◄── │  网盘    │
│  ~/Quark    │     │  + VFS 缓存   │     │   网关)    │     │   API    │
└─────────────┘     └──────────────┘     └────────────┘     └──────────┘
                          │                     │
                     macFUSE kext          仅监听 127.0.0.1
```

- **读**：直接双击播放网盘里的视频、用 QuickLook 预览
- **写**：拖文件进去，30 秒后自动上传（可当备份盘用）
- **删**：和本地文件一样操作
- **长久**：开机自启 + 掉线自动重挂；登录状态过期了再扫一次码（30 秒）

## 下载安装

从 [Releases](../../releases) 下载 `QuarkMount-1.1.0.dmg`（或 `.zip`）：

1. 双击 dmg，把「夸克网盘」拖进「应用程序」
2. **首次打开：右键 App 图标 →「打开」→ 再点「打开」**（未购买 Apple 开发者签名，Gatekeeper 首次会拦，之后不再询问）
3. 打开 App，剩下全自动：

| 步骤 | 会发生什么 | 需要你做什么 |
|---|---|---|
| ① 检测 macFUSE | 没装则自动下载安装（约 22MB） | **输入一次开机密码** |
| ② 开通驱动 | 安装后系统需要你批准内核扩展 | **系统设置 → 隐私与安全性 → 点「允许」**（[详细图文指南](docs/macfuse-activation.md)） |
| ③ 下载组件 | OpenList + rclone（约 90MB，视网速 1-3 分钟） | 等待（有进度条） |
| ④ 扫码登录 | App 内显示二维码 | **手机夸克 APP 扫一扫 → 确认** |
| ⑤ 挂载 | 挂载到 `~/Quark`，设置开机自启 | 无 |

完成后 Finder 左侧出现「Quark」卷，打开即用。

> **macFUSE 是关键前提**：它是一个 macOS 内核扩展（kext），让第三方文件系统成为可能。Apple 要求这类驱动必须由用户本人在系统设置里手动批准——任何工具都无法代劳。整个流程 90% 的情况下就是「点一下允许」，详见 [macFUSE 开通指南](docs/macfuse-activation.md)。

## 系统要求

- macOS 13 (Ventura) 及以上
- Apple Silicon (M 系列) 或 Intel 均可
- 约 300MB 可用磁盘（组件 + VFS 写缓存）
- 夸克网盘账号一个

## 日常使用

```bash
open ~/Quark              # 打开网盘
ls ~/Quark/quark/         # 命令行浏览也一样
cp ~/Quark/quark/某电影.mp4 ~/Desktop/    # 下载到本地
```

App 界面里还可以：**重新扫码**（登录过期时）、**卸载**（停止服务并清理数据）。

## 已知行为（重要）

- **同名文件重传会生成副本**（`file (1).ext`），不会覆盖——这是夸克 Web 接口的限制。改重要文件前建议先备份原文件
- **写入后约 30 秒才真正传到网盘**（本地缓存机制，这期间删文件会取消上传）
- **登录状态 1~3 个月有效**，过期后 App 里点「重新扫码」再扫一次即可
- 网盘内文件很多时，首次打开文件夹会慢几秒（正常，之后有缓存）

## 从源码构建

```bash
git clone https://github.com/<you>/quark-mount.git
cd quark-mount
bash scripts/build.sh          # 编译 + 打包 .app + dmg + zip
```

产物在 `dist/`。开发细节见 [docs/architecture.md](docs/architecture.md)。

## 故障排查

见 [docs/troubleshooting.md](docs/troubleshooting.md)——覆盖：macFUSE 按钮不出现、上传 403、扫码没反应、挂载后打不开、重启后不自动挂载等。

## 安全与隐私

- 所有数据只在本机：OpenList 只监听 `127.0.0.1`，密码/cookie 均为 `600` 权限文件
- 登录 cookie 等同于账号凭证，只保存在你自己的 Mac 上，不经过任何第三方服务器
- App 在安装时从**官方 GitHub Releases** 下载 OpenList / rclone / macFUSE，不带任何镜像篡改

## 许可证

本项目代码 [MIT](LICENSE)。运行时下载的第三方组件版权归各自作者：OpenList (AGPL-3.0)、rclone (MIT)、macFUSE (BSD)——详见 [NOTICE.md](NOTICE.md)。

---

<a id="english"></a>

## English

**QuarkMount** turns your Quark Pan (夸克网盘) into a local folder on macOS. One-click installer app: scan a QR code with the Quark app, and your cloud drive appears at `~/Quark` — browsable in Finder, auto-mounts on login, auto-recovers from drops.

Built on rclone + OpenList (WebDAV gateway) + macFUSE. Native SwiftUI app, no Xcode project required. See [docs/macfuse-activation.md](docs/macfuse-activation.md) for the one manual step Apple requires (approving the kernel extension). MIT licensed.
