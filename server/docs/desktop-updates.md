# 桌面下载与更新

简体中文 · [English](desktop-updates.en.md)

`DESKTOP_RELEASE_ORIGIN` 用于配置应用安装包的 HTTPS 发布源，例如 `https://downloads.example.com`。可以用对象存储或静态文件服务托管。变量留空时，下载页显示尚未提供安装包。

发布源根目录按架构提供 `taoscreen-macos-arm64.json` 或 `taoscreen-macos-x86_64.json`。安装包路径为 `/macos/<版本>/TaoScreen-<版本>-<架构>.dmg`。可以使用桌面端的 `scripts/build-release.sh` 生成安装包、安装包清单和 Sparkle appcast。

`/download` 显示安装包。需要查询时，使用 `GET /v1/desktop/updates/latest?platform=macos&arch=arm64&current=1.0.0`。服务端验证 HTTPS 来源、文件路径、架构、版本、大小和 SHA-256，并按需返回更新。

macOS 的自动更新由 Sparkle 提供。客户端在构建时配置对应架构的 HTTPS appcast 和 Ed25519 公钥。发布前先上传带签名且已公证的 ZIP 和 DMG，核对下载内容，再发布清单和 appcast。签名、公证和更新密钥均由发布者在本机或 CI 中配置。
