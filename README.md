# TaoScreen 涛子远程桌面

<img src="macos/Resources/Brand/TaoScreen-logo.png" alt="TaoScreen 应用图标" width="128">

TaoScreen 是面向 macOS 14 及以上版本的 Mac 到 Mac 远程桌面项目。支持远程屏幕和键鼠、系统声音、文件传输，也可以通过局域网或 Tailscale 免账号直连。

| 目录 | 内容 |
| --- | --- |
| [macos](macos/README.md) | SwiftUI 客户端、原生 WebRTC 与 macOS 构建说明 |
| [server](server/README.md) | Go 账号与信令服务、自托管管理后台和 Docker Compose |

## 本地构建

服务端需要 Docker Compose 和 Python 3。在仓库根目录执行：

```sh
cd server
python3 scripts/setup-local.py
docker compose up -d --build --wait
docker compose exec api /server create-user user@example.com
```

在另一终端从仓库根目录打开 macOS 客户端。构建需要 Xcode、Swift 6 工具链和 XcodeGen。

```sh
cd macos
scripts/build-app.sh
open dist/TaoScreen.app
```

在客户端选择「账号连接」，填写 `http://127.0.0.1:28080` 后可用刚创建的账号测试登录。部署供多台 Mac 使用时，请配置 HTTPS。也可以在两台 Mac 上选择「免登录直连」，按界面提示操作。

## 自托管

通用 Compose 管理 API、PostgreSQL、Redis 和数据库迁移。生产实例可以使用本地账号和管理员动态码，可选接入 Google、GitHub 和 Cloudflare Access。配置生产 HTTPS、管理后台和首次绑定的步骤见 [自托管登录](server/docs/authentication.md#自托管登录)。

## 许可证

TaoScreen 源码采用 [Apache-2.0](LICENSE)。外部依赖及其许可见 [第三方声明](THIRD_PARTY_NOTICES.md)。
