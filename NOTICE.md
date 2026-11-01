# 第三方组件声明 (NOTICE)

本 App 自身代码采用 MIT 许可证（见 [LICENSE](LICENSE)）。

App **不在安装包内分发**任何第三方组件，而是在用户本机安装时从各项目的**官方 GitHub Releases** 下载原版二进制文件，不做任何修改。各组件版权归其作者所有：

| 组件 | 用途 | 许可证 | 官方来源 |
|---|---|---|---|
| [OpenList](https://github.com/OpenListTeam/OpenList) | WebDAV 网关（夸克驱动） | AGPL-3.0 | github.com/OpenListTeam/OpenList |
| [rclone](https://github.com/rclone/rclone) | FUSE 挂载 + VFS 缓存 | MIT | github.com/rclone/rclone |
| [macFUSE](https://macfuse.github.io/) | macOS 内核扩展 | BSD-style | github.com/macfuse/macfuse |

## 关于 AGPL-3.0 的 OpenList

OpenList 是 AList 的社区继任项目，继承 AGPL-3.0 许可证。本项目与 OpenList 的关系：

- **不修改、不分发、不链接** OpenList 代码——App 仅在安装时下载官方发布的二进制文件并作为独立进程运行
- 两者通过本机 HTTP (127.0.0.1:5244) 上的标准 WebDAV 协议通信，是互相独立的进程
- 因此本项目的 MIT 许可不受 OpenList 的 AGPL 条款传染

## 关于夸克 (Quark)

本项目通过夸克网盘**网页版接口**访问用户自己的账号数据，不破解、不绕过任何技术措施，与官方客户端使用相同的 HTTPS 端点。用户需自行承担使用第三方工具访问网盘的风险（如账号风控），请遵守夸克用户协议。
