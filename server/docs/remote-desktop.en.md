# Desktop and Port Forwarding Protocol

English · [简体中文](remote-desktop.md) · [Server README](../README.en.md) · [OpenAPI](../api/openapi.json)

## Authentication

The server stores accounts, devices, sessions, third-party identities, and short-lived login transactions in PostgreSQL, and shares signaling state through Redis. See [Authentication](authentication.en.md).

Registration uses `email` and `password`. Password sign-in also requires a lowercase UUID `device_id` and a non-empty `device_name`. A password requires at least 12 characters and a maximum of 256 bytes. Production accounts are created by approved OAuth sign-up or administrator command.

Sign-in returns `user_id`, `device_id`, `session_id`, `access_token`, `refresh_token`, `token_type=Bearer`, and both expiration timestamps. Access lasts up to 15 minutes and sessions up to 30 days. Refresh rotates both tokens. Reuse of an old refresh token revokes its session. The server stores token hashes. The client verifies `/health/ready` reports `service=taoscreen` before sending credentials.

## Desktop signaling

- `GET /v1/desktop/config` returns ICE URLs, relay availability, expiry, and temporary TURN credentials where configured.
- `GET /v1/desktop/peers` lists other devices on the same account with active desktop signaling.
- `GET /v1/desktop/signal` is a WebSocket with one active desktop connection per device. A duplicate returns HTTP 409. The heartbeat is 25 seconds. A Pong extends the 70-second online lease.

Business messages include `type`, session UUID `id`, destination device UUID `to`, and optional `payload`. The server sets `from` to the authenticated device. The flow is `invite → accept/reject → offer → answer → candidate → end`. Participants cannot change mid-session. The receiving Mac grants screen, control, audio, and file permissions at acceptance.

The server advertises `resume=true` and `keepalive=true` in `hello.payload`. Resume verifies the existing participants and their original sessions. Active clients send `keepalive` with the heartbeat. The server verifies both logins and extends the session record to 120 seconds without forwarding the message. Invitations expire after 60 seconds, and an accepted session's initial record lasts two hours. Active sessions can renew it.

Frames are limited to 64 KiB, payloads to 60 KiB, and business signals to 600 per device per minute. Errors carry `payload.code` and `payload.message`. Session revocation sends `session_revoked` and closes with code 4001. Authorization is checked for each message, forward, and heartbeat. Signaling uses Redis Pub/Sub. Screen, media, files, and input use encrypted WebRTC data or media channels. TURN only relays encrypted traffic.

## Standalone port forwarding

`GET /v1/ports/config`, `/peers`, and `/signal` provide the independent service. `hello.payload` includes `independent=true`. Peers must have their port signal connected. Port forwarding requires its own approval even if desktop access is already authorized.

Desktop and port forwarding use separate Redis keys, peer leases, sessions, rate limits, and Pub/Sub channels. Both WebSockets may run at once. Closing either RTC session does not end the other. An established encrypted port channel can survive a signaling interruption for up to 60 seconds. Resume verifies the original session and nonce.

The port service negotiates a WebRTC `m=application` connection using the reliable, ordered `desktop-ports.v1` channel. TCP byte streams and UDP datagrams are bidirectional. UDP retains datagram boundaries up to 65,507 bytes over that reliable channel. The desktops and server must all support the independent API.
