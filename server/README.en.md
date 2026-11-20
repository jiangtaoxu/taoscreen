# TaoScreen Server

English · [简体中文](README.md) · [Project README](../README.en.md) · [Deployment Guide](../docs/deployment.en.md) · [macOS Client](../macos/README.en.md)

The Go server provides accounts, device sessions, and signaling for TaoScreen. The devices exchange media and files through WebRTC. The standalone module is `taoscreen.local/server`.

## Run locally

From `server/`:

```sh
python3 scripts/setup-local.py
docker compose up -d --build --wait
curl http://127.0.0.1:28080/health/ready
make test
make check
make auth-test
make integration
```

Compose binds the API to `127.0.0.1:28080` and uses its own PostgreSQL volume and Redis service. Stop with `docker compose down` to preserve the database. The integration test uses a local development instance and exercises real WebSockets, including lease expiry. Use `TAOSCREEN_TEST_URL` only to select an appropriate local test instance.

## Production

Start with `.env.production.example`. Configure `AUTH_PUBLIC_URL`, PostgreSQL credentials, the administrator options, and your actual trusted reverse proxy. Public registration is disabled in production. Users sign in with email and password or an enabled OAuth provider. See the [self-hosting guide](../docs/deployment.en.md) and [authentication documentation](docs/authentication.en.md).

Run `server migrate` with `MIGRATION_DATABASE_URL` when deploying without Compose. Compose runs migrations before starting the API. Run the server with `DATABASE_URL` and `REDIS_URL`. For WebRTC relays, configure `DESKTOP_STUN_URLS`, `DESKTOP_TURN_URLS`, and the matching `DESKTOP_TURN_SECRET`. See [the coturn example](turnserver.conf.example).

## Endpoints

Use `Authorization: Bearer <access_token>` for authenticated desktop API requests. Tokens in query parameters are unsupported.

| Endpoint | Purpose |
| --- | --- |
| `/`, `/admin`, `/admin/login` | Admin console and local admin sign-in |
| `GET /download` | Public download page for packages configured on the instance |
| `GET /health/live`, `GET /health/ready` | Process and dependency checks |
| `GET /v1/auth/providers` | Enabled sign-in methods |
| `POST /v1/auth/register`, `/login` | Explicitly enabled development registration and password sign-in |
| `POST /v1/auth/refresh`, `/logout` | Rotate tokens or revoke the current session |
| `POST /v1/admin/users` | Local admin account creation |
| `GET /v1/me`, `GET /v1/sessions`, `DELETE /v1/sessions/{id}` | Account data, device sessions, and revocation |
| `GET /v1/desktop/{config,peers,signal}` | ICE configuration, online desktop peers, and WebSocket signaling |
| `GET /v1/ports/{config,peers,signal}` | Independent port forwarding configuration, peers, and WebSocket signaling |
| `GET /v1/desktop/updates/latest` | Latest configured release for a platform and architecture |

[OpenAPI contract](api/openapi.json) · [Desktop protocol](docs/remote-desktop.en.md) · [Downloads and updates](docs/desktop-updates.en.md)

## Source layout

`cmd/server` contains the executable and management commands. `internal/config`, `internal/database`, and `internal/httpapi` contain configuration, migrations, and server behavior. `tests/integration` covers the running API. `scripts` contains local setup and account management helpers.
