# TaoScreen Self-hosting Guide

English · [简体中文](deployment.md) · [Project README](../README.en.md) · [User Guide](user-guide.en.md)

A self-hosted TaoScreen instance provides account, device, signaling, and optional relay configuration. Direct Connect over a LAN or Tailscale runs without a TaoScreen server.

## Requirements

- Docker Engine and Docker Compose v2 on the host
- Python 3 for the local setup script
- An HTTPS domain and a reverse proxy for production
- PostgreSQL, Redis, and the TaoScreen API are included in the Compose stack

| Port | Use |
| --- | --- |
| `443/TCP` | Public HTTPS, including desktop and port signaling WebSockets |
| `28080/TCP` | TaoScreen API on the host loopback interface |
| `5432/TCP`, `6379/TCP` | Internal PostgreSQL and Redis |
| `3478`, `5349`, and your TURN relay range | Optional coturn listeners and relay ports |

## Try the server locally

```sh
cd server
python3 scripts/setup-local.py
docker compose up -d --build --wait
curl http://127.0.0.1:28080/health/ready
docker compose exec api /server create-user user@example.com
```

A ready server returns `{"service":"taoscreen","status":"ready"}`. In TaoScreen on the same Mac, open **Account Connect**, then choose **Custom Server** in the gear menu. Save `http://127.0.0.1:28080`, wait for discovery to complete, then pick **Sign in with Email and Password**.

Run `make test` for Go tests, `make check` for `go vet`, or `make auth-test` for the OAuth and admin integration suite with PostgreSQL and Redis. `make integration` runs the end-to-end tests against the local API. Stop the stack with `docker compose down` to retain the database volume.

## Production environment

From the repository root:

```sh
cd server
cp .env.production.example .env.selfhost
chmod 600 .env.selfhost
```

Set a strong random `POSTGRES_PASSWORD`. Set `AUTH_PUBLIC_URL` to the public HTTPS root URL, for example `https://desktop.example.com`. Use a URL without a path or trailing slash. Keep this configuration and its secrets on the host.

| Variable | Meaning |
| --- | --- |
| `APP_ENV` | Use `production` on an internet-facing instance |
| `ALLOW_REGISTRATION` | Keep `false` in production |
| `ALLOW_PASSWORD_LOGIN` | Enables normal email and password sign-in |
| `ALLOW_SOCIAL_SIGNUP` | Controls first-time automatic account creation via Google or GitHub. The example defaults to `false`. |
| `DESKTOP_OAUTH_CALLBACK_SCHEME` | Desktop callback scheme, default `taoscreen`. It must match the client if customized. |
| `ADMIN_AUTH_MODE` | `local`, `cloudflare_access`, or `disabled` |
| `ADMIN_TOTP_ENABLED` | Requires a TOTP code for local admins by default |
| `ADMIN_TOTP_KEY` | Generate with `openssl rand -base64 32` when admin TOTP is enabled. Back it up with the database. |
| `TRUSTED_PROXY_CIDRS` | Direct proxy IPs, as seen from the API container, as CIDRs. Use the actual narrow networks, such as a single IPv4 `/32` or IPv6 `/128`. |
| `CLOUDFLARE_PROXY_CIDRS` | Cloudflare origin ranges when using its proxy |
| `DESKTOP_STUN_URLS` | Optional comma-separated STUN URLs |
| `DESKTOP_TURN_URLS` | Optional comma-separated TURN URLs. Requires `DESKTOP_TURN_SECRET`. |
| `DESKTOP_RELEASE_ORIGIN` | Optional HTTPS file origin for the self-hosted download page |

### HTTPS reverse proxy

Keep the API on `127.0.0.1:28080`. Preserve the original `Host`, replace incoming `X-Forwarded-Proto` with the protocol observed by the proxy, and forward WebSocket upgrades on `/v1/desktop/signal` and `/v1/ports/signal`. Set idle timeouts long enough for persistent connections. TaoScreen sends a heartbeat every 25 seconds.

Caddy example:

```caddyfile
desktop.example.com {
    reverse_proxy 127.0.0.1:28080
}
```

Nginx example:

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 443 ssl;
    server_name desktop.example.com;
    ssl_certificate /etc/ssl/certs/desktop.example.com.pem;
    ssl_certificate_key /etc/ssl/private/desktop.example.com.key;

    location / {
        proxy_pass http://127.0.0.1:28080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

### Start the stack and create accounts

Run the following from `server/`. Compose starts PostgreSQL and Redis, applies migrations, and waits for the API health check.

```sh
docker compose --env-file .env.selfhost up -d --build --wait
docker compose --env-file .env.selfhost exec api /server create-admin admin@example.com
```

If TOTP is enabled, enroll an authenticator, enter its current code, and keep the one-time recovery codes offline. Sign in at `/admin` and choose **Create Local Account**, or create a normal account on the host:

```sh
docker compose --env-file .env.selfhost exec api /server create-user user@example.com
```

On each Mac, open **Account Connect**, set the instance's HTTPS URL under **Custom Server**, and sign in to the same account. Turn on **Enable Remote Desktop** on both Macs.

## Optional features

### Google and GitHub sign-in

Enable either provider by configuring its OAuth app and callback URL. Use a different application and credentials for each deployment. Users should sign in with their original method and actively link another provider in the account menu. See the [authentication guide](../server/docs/authentication.en.md).

### TURN relay

Use coturn if restrictive NAT or firewalls prevent direct WebRTC connectivity. Start from [the coturn example](../server/turnserver.conf.example). Open the configured listeners and relay range on the relay host. Provision a valid certificate for TLS, and configure a shared random secret of at least 32 bytes in both coturn and `DESKTOP_TURN_SECRET`. Set `DESKTOP_STUN_URLS` and `DESKTOP_TURN_URLS` as needed. TaoScreen supplies temporary TURN credentials.

### Downloads and updates

Set `DESKTOP_RELEASE_ORIGIN` to enable downloads at `/download`. Host the manifests, DMGs, and optionally the Sparkle appcasts on an HTTPS file origin. The [release format](../server/docs/desktop-updates.en.md) and [build guide](../macos/README.en.md#updates) describe the required files and keys.

## Operations

- Apply updates with `docker compose --env-file .env.selfhost up -d --build --wait`. Use `down` to stop the stack while preserving its volumes. The `down -v` option deletes volumes.
- Back up PostgreSQL with `pg_dump` and keep the matching `ADMIN_TOTP_KEY` securely.
- Use `GET /health/live` for liveness and `GET /health/ready` to check the database, migrations, and Redis.
- See the [desktop protocol](../server/docs/remote-desktop.en.md) and [OpenAPI specification](../server/api/openapi.json) for endpoint contracts.
