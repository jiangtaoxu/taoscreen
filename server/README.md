# TaoScreen 服务端

简体中文 · [English](README.en.md)

[返回项目首页](../README.md) · [自托管部署指南](../docs/deployment.md) · [macOS 客户端说明](../macos/README.md)

TaoScreen（涛子远程桌面）的账号、设备会话和信令服务。

独立 Go 模块 `taoscreen.local/server`，Go 1.26.11。媒体与文件通过 WebRTC 传输。

## 本地运行

```sh
python3 scripts/setup-local.py
docker compose up -d --build --wait
curl http://127.0.0.1:28080/health/ready
make test
make check
make integration
```

Compose 项目名固定为 `taoscreen-local`，使用独立 PostgreSQL 数据库与持久化卷。API 仅绑定宿主机回环 `127.0.0.1:28080` 端口。停止用 `docker compose down`，保留数据库卷。请勿误执行 `down -v` 清空数据库。

测试使用独立随机账号。`make integration` 使用 Python 标准库和真实 WebSocket，含约 85 秒的失联回收检查；只能指向此本地开发实例。默认地址为 `http://127.0.0.1:28080`，可通过 `TAOSCREEN_TEST_URL` 显式指定本地测试服务。

## 自托管生产部署

使用 `.env.production.example` 和通用的 `compose.yaml` 部署。默认示例启用普通用户邮箱密码和管理员密码加动态码，关闭公开注册。管理员在 `/admin` 创建普通用户。macOS 客户端切到「账号直连」，在右上角齿轮的「自定义服务器」中填写实例 HTTPS 地址。配置步骤和首次绑定命令见 [自托管登录](docs/authentication.md#自托管登录)。

## 配置

- `DATABASE_URL`：独立 PostgreSQL；`REDIS_URL`：独立 Redis。Go 直接启动时必须显式配置。
- `APP_ENV`：development/test/production；`ALLOW_REGISTRATION` 必须显式设置。
- `AUTH_PUBLIC_URL` 为实例 HTTPS 根地址。启用本地账号的生产实例和启用 Google/GitHub 的实例需要设置。OAuth 回调路径及客户端凭据见 [登录接入说明](docs/authentication.md)。
- `DESKTOP_OAUTH_CALLBACK_SCHEME` 控制浏览器跳回桌面应用的 URL scheme，默认 `taoscreen`。自定义客户端构建时，将 `TAOSCREEN_OAUTH_CALLBACK_SCHEME` 设为同一个值。
- `DESKTOP_RELEASE_ORIGIN` 为可选的 HTTPS 发布根地址。配置后，下载页读取该地址的 `taoscreen-macos-<架构>.json`，其中安装包路径须为 `/macos/<版本>/TaoScreen-<版本>-<架构>.dmg`。留空时，下载页显示尚未提供安装包。
- `DESKTOP_STUN_URLS`、`DESKTOP_TURN_URLS`：逗号分隔 ICE 地址；未配置时只能使用可达的内网/Tailscale/直连候选。
- `DESKTOP_TURN_SECRET`：与 coturn 共享的至少 32 字节新密钥，必须与 TURN URLs 同时配置，不放入客户端。
- `TRUSTED_PROXY_CIDRS`、`CLOUDFLARE_PROXY_CIDRS`：仅填写已确定的代理网段，不接受全网信任。

- `ALLOW_PASSWORD_LOGIN` 控制普通用户邮箱密码登录。生产环境关闭 `ALLOW_REGISTRATION`。独立的 `ALLOW_SOCIAL_SIGNUP` 控制首次 OAuth 登录是否自动创建账号。
- `ADMIN_AUTH_MODE` 可选 `local`、`cloudflare_access` 或 `disabled`。本地模式通过 `ADMIN_TOTP_ENABLED` 配置动态验证码，默认 `true`，开启时需要 `ADMIN_TOTP_KEY`。Access 模式需要独立团队域名、应用 AUD 和管理员邮箱白名单。

数据库迁移显式运行 `server migrate`，使用 `MIGRATION_DATABASE_URL`；Compose 已串联迁移和就绪检查。启动时会校验内置迁移记录，若误连不兼容的既有数据库会主动拒绝启动以防数据损坏。

## API

认证使用 `Authorization: Bearer <access_token>`，不接受查询参数令牌。

| 接口 | 用途 |
| --- | --- |
| `/`、`/admin`、`/admin/login` | 自托管管理员控制台与本地管理员登录页 |
| `GET /download` | 公开下载页，展示两种 Mac 芯片的最新发布版本、下载按钮及更新说明 |
| `GET /health/live`、`GET /health/ready` | 存活与数据库/Redis/迁移就绪；ready 返回 `service=taoscreen` |
| `GET /v1/auth/providers` | 登录方式的启用状态 |
| `POST /v1/auth/register`、`/login` | 开发注册、启用后的邮箱密码登录 |
| `POST /v1/admin/users` | 本地管理员创建普通账号 |
| `POST /v1/auth/refresh`、`/logout` | 刷新轮换、退出并撤销当前登录 |
| `GET /v1/me`、`GET /v1/sessions`、`DELETE /v1/sessions/{id}` | 账号信息、设备会话与撤销 |
| `GET /v1/desktop/updates/latest` | 无需登录，按平台、架构和当前版本获取最新发布信息 |
| `GET /v1/desktop/config` | STUN/TURN 配置，TURN 凭据两小时有效 |
| `GET /v1/desktop/peers` | 同账号在线桌面设备 |
| `GET /v1/desktop/signal` | 唯一桌面设备信令 WebSocket，邀请/授权/SDP/ICE/恢复/续期 |
| `GET /v1/ports/config` | 独立端口映射的 STUN/TURN 配置 |
| `GET /v1/ports/peers` | 同账号且独立端口服务在线的设备 |
| `GET /v1/ports/signal` | 独立端口转发信令 WebSocket |

协议详情见 `docs/remote-desktop.md`，OpenAPI 契约见 `api/openapi.json`。

## 目录

`cmd/server` 为入口与迁移/账号命令；`internal/config` 为最小配置；`internal/database` 为独立迁移与校验；`internal/httpapi` 为鉴权、桌面信令及代理地址校验；`tests/integration` 为真实依赖集成测试；`scripts` 为本地初始化和账号管理；`docs`、`api` 为接口说明。

TURN 示例在 `turnserver.conf.example`；需要独立可用的公网地址、TLS 证书及 3478 UDP/TCP、5349 TLS 和 49160–49260 UDP 中继端口。不能通过普通 HTTP 反向代理转发 TURN，不能沿用原服务密钥。

## Google、GitHub 和管理员 Access

第三方登录和后台 Access 均按实例配置启用。Google/GitHub 通过 PKCE 授权并支持主动绑定，Access 模式提供只读后台。生产和本地开发可共用 Compose 文件，并为各实例设置独立环境变量。`make auth-test` 使用模拟第三方身份提供方和真实的测试数据库验证登录协议。

## 桌面更新分发

下载页位于 `/download`，可直接访问。启用发布源后，页面按 `arm64`、`x86_64` 查询最新版本及对应清单，展示版本、大小、安装包地址和更新说明。发布清单更新后，刷新页面即可展示新版本。未发布的架构显示“尚未发布”。网站根路径与 `/admin` 使用管理员鉴权。

源站配置、版本清单与卷部署说明分别见 [桌面更新发布](docs/desktop-updates.md) 和 [自托管登录](docs/authentication.md#自托管登录)。
