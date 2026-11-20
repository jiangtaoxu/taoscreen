# 独立桌面协议

简体中文 · [English](remote-desktop.en.md)

本服务使用自己的 PostgreSQL 账号、设备会话、第三方身份与短期登录事务表，以及独立 Redis。

普通用户通过邮箱密码（生产开启 `ALLOW_PASSWORD_LOGIN=true` 时）或 Google / GitHub 授权，取得的均为 TaoScreen 自己的不透明会话令牌。HTTP 自助注册仅在显式开启的非生产环境保留。完整接入说明见 [登录与管理员后台](authentication.md)。

## 认证

注册请求为 `email`、`password`；登录另带小写 UUID `device_id` 和非空 `device_name`。密码至少 12 个字符，最长 256 字节。生产关闭 HTTP 自助注册，通过标准输入的 `create-user` 命令创建账号。

登录返回 `user_id`、`device_id`、`session_id`、`access_token`、`refresh_token`、`token_type=Bearer`、`access_expires_at` 和 `refresh_expires_at`。访问令牌有效期最长 15 分钟，会话最长 30 天；刷新请求仅带 `refresh_token` 并轮换两个令牌。重放旧刷新令牌撤销整条登录。令牌只以摘要存储。

鉴权 API 使用 `Authorization: Bearer <access_token>`，HTTP 重定向不用于登录；独立客户端在发送凭据前检查 `/health/ready` 的 `service=taoscreen`。`GET /v1/me` 返回账号 `id`、`email`、`service`、`protocol_version`。

## 桌面 API

- `GET /v1/desktop/config`：`ice_servers`、`relay_available`、`expires_at`。每项为 `urls`，TURN 另有短期 `username`/`credential`。共享密钥只在服务端与 coturn 保存。
- `GET /v1/desktop/peers`：`{"peers":[{"id":"设备 UUID","name":"设备名称"}]}`，只返回同账号、已登录且桌面信令在线的其他设备。
- `GET /v1/desktop/signal`：WebSocket，同一账号设备同时一条，重复连接 HTTP 409。每 25 秒心跳，在线租约 70 秒；收到 Pong 才延长租约。

消息格式为 `{"type":"invite","id":"会话 UUID","to":"设备 UUID","payload":{}}`。服务端覆盖 `from` 为鉴权设备，并规范化 UUID。不得以客户端自报身份替代账号/会话归属。

依次为 `invite` → `accept/reject` → `offer` → `answer` → `candidate` → `end`。接受前不得交换 SDP/ICE；会话只能发往记录中的双方，不能中途改投第三台设备。`accept.payload` 可带 `control`、`audio`、`files`，授权最终由被控端决定。

`hello.payload` 声明 `resume=true` 与 `keepalive=true`。断线后通过 `resume` 验证原会话双方登录与同一参与者；不能将新登录身份替换到旧授权。已连通的会话随心跳发送 `keepalive`，服务端重新校验双方登录后将记录续期到 120 秒，不转发给对端。邀请 60 秒有效，接受后的初始记录为两小时，活跃会话可不断续期，没有总连接时长上限。

每帧 64 KiB、payload 60 KiB；每台设备每分钟最多 600 条业务信令。业务错误发 `error`，含原 `id` 和 `payload.code/message`。撤销登录时发送 `session_revoked` 并以 4001 关闭；每条消息、转发和 25 秒心跳均复查登录。API/数据库/Redis 失效时不继续确认新授权。

信令经 Redis Pub/Sub 跨实例中转，不保存 SDP/ICE/画面/输入。媒体、文件和输入经 WebRTC 加密通道，TURN 仅转发密文。不能将本机候选能够连通等同于已验证跨 NAT 或 TURN。

## 独立端口转发 API

- `GET /v1/ports/config`：与桌面相同的短期 ICE/TURN 配置，凭据仍绑定当前设备。沿用已有 TURN 配置，无需新增公网监听端口。
- `GET /v1/ports/peers`：仅返回同账号、已登录且**端口信令**在线的其他设备；不以桌面在线替代端口在线。
- `GET /v1/ports/signal`：独立 WebSocket。`hello.payload` 为 `{"resume":true,"keepalive":true,"independent":true}`。每台设备每种用途限一条信令；可同时保持桌面与端口 WebSocket。

端口信令遵循同一消息格式及 `invite` → `accept/reject` → `offer` → `answer` → `candidate` → `end` 授权流程。端口授权必须独立取得，不接受桌面控制或无人值守授权替代。接受前不允许交换 SDP/ICE；服务端覆盖发送者身份，限制同账号在线设备，并检查会话参与者、原登录身份及双端登录有效性。恢复、续期、邀请有效期、心跳与消息限额遵循上述规则，各用途分别计数。

Redis 按 `desktop` / `ports` 分离在线租约、Pub/Sub 频道、会话记录与限流键；即使双方设备、账号和会话 UUID 完全相同，结束一类会话也不影响另一类。断开桌面信令或桌面 RTC 不结束端口会话；断开端口会话不结束桌面。关闭端口服务或注销时客户端停止端口监听及数据通道。短暂信令中断仅保留已有端口加密通道最多 60 秒，恢复需验证原会话及随机码，不重新授予权限。

客户端在专用 WebRTC 连接上只协商 `m=application`，通过可靠有序的 `desktop-ports.v1` 数据通道转发双向 TCP 字节流和 UDP 数据报，不建立屏幕、音频、键鼠或文件通道。UDP 保留数据报边界（0–65507 字节），经可靠通道传输，其丢包和时序表现不同于原生 UDP。转发载荷不经过 HTTP 信令；直连不可达时使用已有 TURN 中继密文。两端客户端与服务端均需升级，不回落至桌面会话或旧接口。
