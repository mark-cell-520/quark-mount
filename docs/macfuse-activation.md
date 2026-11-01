# macFUSE 开通指南（必读）

> **一句话**：macFUSE 装好后，还必须到「系统设置 → 隐私与安全性」点一次「允许」，内核驱动才会真正工作。这一步 Apple 强制要求人工确认，任何软件都无法代劳。

---

## 1. 为什么需要 macFUSE

macOS 默认只支持苹果自己的文件系统。要让「网盘」像本地磁盘一样挂载，必须有一个第三方文件系统驱动。macFUSE 就是干这个的——它以**内核扩展（kext）**形式运行在系统最底层。

正因为它运行在内核态，Apple 的安全策略要求：**任何第三方内核扩展，必须由用户本人在系统设置里明确批准后才会加载**。没批准 = 驱动没运行 = 挂载必然失败（报错类似 `Resource busy` 或 `mount stopped before calling Init`）。

## 2. 开通步骤（macOS 13 / 14 / 15 / 26 / 27 通用）

### 第一步：安装

App 部署到这一步时会自动下载并安装 macFUSE，弹出密码框属正常（安装系统级组件需要管理员权限）。

### 第二步：批准（关键的一步）

1. 安装完成后，打开 **系统设置 → 隐私与安全性**
2. 在页面中下部找到 **「安全性」** 区域
3. 会看到类似提示：

   > **来自开发者「Benjamin Fleischer」的系统软件已被阻止加载。**
   > 【允许】

4. 点 **【允许】**，输入密码确认
5. 无需重启，驱动随即加载

> ⚠️ **这个「允许」按钮只存在 30 分钟**。它是被安装动作触发的，过期后按钮会消失。如果错过了，见下文「按钮没出现」。

### 第三步：验证（可选）

打开「终端」运行：

```bash
kextstat | grep -i fuse
```

看到类似输出即成功：

```
   255    0 0  0x17a0  0x17a0  io.macfuse.filesystems.macfuse.25 (5.5.0) ...
```

App 也会自动检测，通过后直接继续下一步。

## 3. 不同 macOS 版本的界面差异

| macOS 版本 | 「允许」按钮位置 | 备注 |
|---|---|---|
| macOS 13 / 14 | 系统设置 → 隐私与安全性 → 安全性 | 按钮在页面下方，需稍等几秒出现 |
| macOS 15 (Sequoia) | 系统设置 → 隐私与安全性 → 安全性 | 同上；如安装后立即打开可能还在刷新，等 10 秒 |
| macOS 26 / 27 | 系统设置 → 隐私与安全性 → 安全性 | 若整个「安全性」区域没出现，见下方排查 |

**Apple Silicon（M1/M2/M3/M4...）与 Intel 无差别**，都是同一流程。macFUSE 已获 Apple 认可签名，不需要进 Recovery 模式、不需要关闭 SIP。

## 4. 按钮没出现 / 已过期怎么办

「允许」按钮由 macFUSE 安装器触发，只在安装后 30 分钟内有效。过期后重新触发即可：

```bash
/Library/Filesystems/macfuse.fs/Contents/Resources/load_macfuse
```

这条命令会重新激活加载请求，按钮立刻回到「隐私与安全性」里，再去点【允许】。

或者最省事的办法：**重启 Mac**。重启后系统会重新挂起待批准请求，登录后再去看「隐私与安全性」。

## 5. 常见问题

### Q1：点了「允许」但还是挂载失败？

等 10 秒再试（驱动加载需要一两秒）。App 的部署流程会自动重试检测。也可在终端验证：

```bash
kextstat | grep -i fuse        # 有输出 = 已加载
```

### Q2：提示「macFUSE 已安装」但驱动没加载？

安装和加载是两回事。运行：

```bash
/Library/Filesystems/macfuse.fs/Contents/Resources/load_macfuse
kextstat | grep -i fuse
```

### Q3：公司电脑 / MDC 管理的 Mac 按钮点不了？

企业管控的 Mac 可能禁止加载第三方内核扩展，需要联系 IT 管理员在 MDM 里放行 macFUSE（团队 ID `3T5GSNBU6W`）。这种情况下本工具无法使用，建议改用夸克官方客户端。

### Q4：之前装过旧版 macFUSE (4.x)？

直接装新版即可，安装器会自动处理升级，批准流程照旧。

### Q5：卸载 macFUSE？

App 的「卸载」不会动 macFUSE 本身（其他软件可能也在用）。如确需卸载：`/Library/Filesystems/macfuse.fs/Contents/Resources/uninstall_macfuse.app`。

## 6. 给开发者：无头触发加载

在脚本/CI 里可以用 setuid 助手触发加载（不需要 sudo，助手自身是 root）：

```bash
/Library/Filesystems/macfuse.fs/Contents/Resources/load_macfuse
```

它会把 kext 加载请求重新挂起，用户端「允许」按钮随之出现。检测是否就绪：

```bash
kextstat 2>/dev/null | grep -q macfuse && echo READY || echo NOT_READY
```

## 7. 官方资源

- macFUSE 官网：https://macfuse.github.io/
- 本项目的自动化实现见 `app/Installer.swift` 的 `ensureMacFUSE()`
