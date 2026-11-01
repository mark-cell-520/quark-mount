# 架构说明

## 组件职责

| 组件 | 职责 | 来源 |
|---|---|---|
| **夸克网盘.app** | 编排一切：检测环境、下载组件、配置服务、扫码登录、挂载、自启 | 本仓库 Swift 源码 |
| **macFUSE** | macOS 内核扩展，提供 FUSE 文件系统能力 | 官方 Release 下载 |
| **OpenList** | WebDAV 网关，把夸克 API 翻译成标准 WebDAV | 官方 Release 下载 |
| **rclone** | FUSE 挂载器 + VFS 缓存层 | 官方 Release 下载 |
| **LaunchAgent** | 登录时自启 + 挂载掉线自动重挂 | App 生成 `com.quark.mount.plist` |

## 为什么是这套栈

- 夸克没有公开 API 也没有 macOS 客户端，唯一稳定的接口是网页版内部 API
- rclone 没有夸克后端（官方 PR 仍是草稿），所以中间需要一层「网盘 API → 标准协议」的翻译器
- OpenList（AList 的社区继任者）有成熟的夸克驱动，对外暴露 WebDAV，rclone 的 webdav 后端久经考验
- 整条链路上每个组件都可以单独替换，App 不修改任何第三方代码

## 目录布局

安装后所有数据在 `~/Library/Application Support/QuarkMount/`：

```
QuarkMount/
├── bin/
│   ├── openlist            # WebDAV 网关（仅监听 127.0.0.1:5244）
│   └── rclone              # 挂载器
├── data/                   # OpenList 数据（SQLite + 日志）
├── .admin-pass             # OpenList 管理员密码（600 权限，App 自管）
├── .quark-cookie           # 夸克登录 cookie（600 权限）
├── rclone.conf             # rclone 配置（600 权限）
├── start-all.sh            # LaunchAgent 入口：kext → 服务 → 挂载守护
├── openlist.log / mount.log / launchd.log
```

挂载点：`~/Quark`（Finder 中卷名 Quark）。

## 关键流程

### 部署（App 首次运行）

```
检测 macFUSE → 未装则下载 dmg + installer（管理员密码）→ 等用户点「允许」
    → 下载 OpenList / rclone（多镜像：gh-proxy → ghfast → 直连）
    → 写 OpenList 配置（仅 127.0.0.1 + 绝对路径 SQLite）
    → 以 OPENLIST_ADMIN_PASSWORD 环境变量启动（OpenList v4 不再自动建号）
    → 修补 admin 权限位（见下）
    → 扫码登录拿 cookie 并验证（drive.quark.cn 列目录）
    → 添加 Quark 存储
    → rclone mount --daemon（webdav remote → ~/Quark）
    → 安装 LaunchAgent + kickstart
```

### OpenList v4 的两个坑（代码里有对应修复）

1. **v4 不再自动创建 admin**：只有 dev 模式或设置了 `OPENLIST_ADMIN_PASSWORD` 才建号，否则等 Web 向导。App 用环境变量方式无头创建。
2. **环境变量建的 admin 权限是 `0x71FF`**：含 WebDAV 读（bit 8）但缺 WebDAV 写（bit 9），导致 PUT/MKCOL/DELETE 全部 403。App 启动后通过 API 补上 `| 0x200`。

### 扫码登录（`QuarkAuth.swift`）

复刻开源社区验证过的夸克 CAS 流程：

1. `GET uop.quark.cn/cas/ajax/getTokenForQrcodeLogin` → token
2. 二维码内容为 `su.quark.cn/4_eMHBJ?token=...`（CoreImage 本地生成，零依赖）
3. 轮询 `getServiceTicketByQrcodeToken`：`2000000` 成功 / `50004001` 等待 / `50004002` 过期
4. `pan.quark.cn/account/info?st=<ticket>&lw=scan` 落 cookie
5. `drive-pc.quark.cn/1/clouddrive/config` 补 `__puus`
6. `drive.quark.cn/1/clouddrive/file/sort` 验证 cookie 有效（`code == 0`）

### 自愈（`start-all.sh`）

LaunchAgent 每 30 秒检查挂载是否存在，掉了就重挂；OpenList 不在就重启。kext 未加载则先 `load_macfuse`。

## 挂载参数

```
--vfs-cache-mode writes      # 写入先缓存，异步上传（关闭即返回）
--vfs-cache-max-size 10G     # 缓存上限
--vfs-write-back 30s         # 关闭文件 30 秒后回传
--dir-cache-time 10m         # 目录列表缓存
--noapplexattr               # 丢弃 com.apple.* 扩展属性（避免 Finder 复制 EPERM）
--volname Quark              # Finder 卷名
```

## 安全边界

- OpenList 仅绑定 `127.0.0.1`（安装时改写默认的 `0.0.0.0`）
- 三个敏感文件（密码、cookie、rclone 配置）均为 `600`
- 无网络外传：cookie 只在本机使用，二维码由 CoreImage 本地生成
- App 自身无沙盒（需要操作 LaunchAgents / 安装 pkg / 起子进程），ad-hoc 签名

## 多架构支持

App 通过 `uname -m` 选择下载 `darwin-arm64` 或 `darwin-amd64` 的组件；macFUSE dmg 为通用包。
