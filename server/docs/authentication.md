# TaoScreen 登录与管理员后台

普通用户可以使用邮箱密码、Google 或 GitHub。管理员使用本地密码加动态码或独立的 Cloudflare Access 应用。管理员身份与桌面用户账号及远程权限隔离。

## 自托管登录

1. 将 `.env.production.example` 复制为仅部署者可读的 `.env.selfhost`。设置 `POSTGRES_PASSWORD` 和实例的 HTTPS 根地址 `AUTH_PUBLIC_URL`，用 `openssl rand -base64 32` 生成 `ADMIN_TOTP_KEY`。妥善保存此密钥与数据库备份，恢复实例时两者需要配套。
2. 使用 HTTPS 反向代理转发到 Compose 在 `127.0.0.1:28080` 发布的端口。代理保留原始 `Host`、转发 WebSocket，并覆盖客户端传入的 `X-Forwarded-Proto` 为代理实际接收的协议。将服务容器看到的直接代理地址按 `/32` 或 `/128` 写入 `TRUSTED_PROXY_CIDRS`。宿主机代理经 Docker 转发时，服务容器看到的可能是 Docker 网关。浏览器和桌面客户端均使用对外的 HTTPS 地址。
3. 运行以下命令。第一个命令启动 PostgreSQL、Redis 和应用，并执行迁移。第二个命令要求交互终端，输入密码、在验证器扫码并输入六位动态码。请离线保存输出的一次性恢复码。首次网页登录使用下一组动态码。

   ```sh
   docker compose --env-file .env.selfhost up -d --build --wait
   docker compose --env-file .env.selfhost exec api /server create-admin admin@example.com
   ```

4. 浏览器打开实例的 `/admin`，登录后选择「创建本地账号」。在 macOS 的「账号连接」中填写实例地址，使用该邮箱和密码登录。还可以在托管机上运行 `docker compose --env-file .env.selfhost exec api /server create-user user@example.com` 创建普通账号。

后台登录可使用密码加一条恢复码。需要重新绑定验证器或重置管理员密码时，在托管机上运行 `docker compose --env-file .env.selfhost exec api /server reset-admin admin@example.com`。重置会撤销该管理员的现有会话并替换恢复码。后台会话有效期为 8 小时，可以主动退出。无需配置邮件或短信。

`ADMIN_AUTH_MODE=disabled` 可关闭后台。若改用 `cloudflare_access`，填写 Access 应用配置。Google/GitHub 各自的 Client ID 和 Secret 可按需配置。本地账号模式默认关闭公开注册和 OAuth 首次注册。


## Cloudflare Access（可选）

要使用 Access 管理后台，设置 `ADMIN_AUTH_MODE=cloudflare_access`，并填写本实例的 `ADMIN_ACCESS_TEAM_DOMAIN`、`ADMIN_ACCESS_AUD` 和 `ADMIN_ALLOWED_EMAILS`。让后台域名及其 `/v1/admin/*` 路径通过管理员专用的 Access 应用。普通桌面 API 可使用单独的域名。

后端逐个请求验证 `Cf-Access-Jwt-Assertion` 的签名、issuer、应用 AUD、有效期和管理员邮箱。Access 管理身份可查看账号资料，与桌面账号会话隔离。

## Google 配置

1. 在 Google Cloud 为 TaoScreen 建立独立 OAuth 应用，配置品牌与所需的测试/发布受众。
2. 创建 **Web application** 类型客户端，因为第三方回调由 Go 服务端处理。
3. 登记精确的 Authorized redirect URI：`https://desktop.example.com/v1/auth/oauth/google/callback`。
4. 将新应用的 `GOOGLE_CLIENT_ID`、`GOOGLE_CLIENT_SECRET` 写入服务端受保护配置；不得放进 macOS 包或文档。

服务端申请 `openid email profile`，使用授权码与 S256 PKCE。检查 Google ID Token 签名、issuer、client audience、有效期和本次 nonce，要求已验证邮箱。稳定身份为 Google `sub`，不用 Gmail 地址推断身份。

## GitHub 配置

1. 为 TaoScreen 建立独立 GitHub OAuth App。
2. Homepage URL 使用 `https://desktop.example.com`；Authorization callback URL 使用 `https://desktop.example.com/v1/auth/oauth/github/callback`。
3. 将 `GITHUB_CLIENT_ID`、`GITHUB_CLIENT_SECRET` 写入服务端受保护配置。

申请 `read:user user:email`，不申请代码仓库权限。授权码交换使用 S256 PKCE。通过 GitHub API 取得稳定数字用户 ID 和已验证主邮箱；资料页隐藏邮箱不影响 `/user/emails` 的授权读取。没有已验证主邮箱时明确拒绝，不猜测邮箱。

## 原生客户端授权流程

1. 客户端生成随机 state、verifier 和 S256 challenge，并带稳定设备 ID 发起 `POST /v1/auth/oauth/{provider}/start`。
2. 服务端返回同源的浏览器授权 URL。浏览器进入 `/authorize` 后，用 HttpOnly/SameSite Cookie 绑定本次浏览器；再跳转指定提供方。
3. 提供方回调服务端。服务端校验 state、浏览器 Cookie、上游 PKCE 和身份，保存短期验证结果。
4. 浏览器仅跳回 `taoscreen://auth/callback?state=...&code=...`。macOS 使用 `ASWebAuthenticationSession` 直接接收本次认证会话的回调，不依赖 LaunchServices 在已安装版、开发目录版等多个副本之间选择应用；系统会话结束时立即校验 state、回调路径和一次性授权码，失败则结束等待并显示错误。不在 URL 中携带 TaoScreen 访问令牌、刷新令牌或提供方令牌。
5. 客户端核对来源、state 和唯一参数，用自己的 verifier POST 兑换。服务端在事务中消费一次性兑换码、确定账号归属并签发原有 TaoScreen 会话。登录事务五分钟有效。

登录后的刷新、退出、设备隔离及桌面信令继续使用现有不透明随机令牌，第三方令牌不作为远程桌面凭据。取消、超时、错误回调不会被当作登录成功。

## 注册与主动绑定

新增迁移 `002_social_auth.sql`，不改写已执行的初始迁移。`users` 新增注册来源、昵称、邮箱验证状态和最近登录时间；第三方账号允许没有本地密码。`auth_identities` 通过 `(provider, subject)` 唯一确定用户，每个用户同一提供方最多绑定一个身份。

独立使用 Google 和 GitHub 登录不会仅凭相同邮箱自动合并账号。若邮箱已存在而该身份尚未绑定，返回 `identity_conflict`，提示先登录原账号再主动绑定。macOS 账号菜单提供“绑定 Google/GitHub”。发起及完成绑定均校验同一用户、设备和原会话；原会话失效后拒绝绑定。绑定完成后两种方式使用同一个 TaoScreen 用户 UUID，设备及桌面授权归属保持一致。

## 管理员页面与接口

- `/`、`/admin`：后台用户列表，支持搜索、分页和详情。
- `GET /admin/login`、`POST /admin/login`、`POST /admin/logout` 用于本地后台登录及退出。
- `GET /v1/admin/me` 返回当前管理员身份和后台模式。
- `GET /v1/admin/users?q=&limit=50&offset=0`：用户注册信息、最近登录、设备及有效会话数量。
- `GET /v1/admin/users/{id}`：用户资料及第三方绑定详情。

本地后台同时启用普通用户密码登录时，`POST /v1/admin/users` 可创建普通账号。Access 后台提供账号资料查询。管理会话与桌面会话分别签发。迁移 `003_local_admin.sql` 新增管理员、恢复码和会话表。动态码种子加密保存，恢复码和会话令牌仅保存摘要。

## 验证

```sh
go test ./...
go vet ./...
docker compose up -d --build --wait
make auth-test
make integration
```

`make auth-test` 在真实独立 PostgreSQL/Redis 上运行本地 RSA 签名的模拟 Google/GitHub 和 Access 公钥服务，覆盖完整浏览器/PKCE/一次性兑换链路、重复兑换、无 Cookie 回调、nonce、已验证邮箱、跨账号同邮箱拒绝、主动绑定、原会话撤销、过期，以及管理员 issuer/AUD/邮箱/签名隔离。本地管理员集成测试覆盖 HTTPS Cookie、跨站请求拦截、动态码与恢复码防重用、账号创建、身份隔离和会话撤销。这些协议测试不能替代真实 Google/GitHub 应用配置后的账号联调。
