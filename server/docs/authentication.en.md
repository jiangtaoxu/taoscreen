# TaoScreen Authentication and Admin Console

English · [简体中文](authentication.md) · [Server README](../README.en.md) · [Deployment Guide](../../docs/deployment.en.md)

TaoScreen supports email/password, Google, and GitHub sign-in for ordinary accounts. Admin authentication is separate from desktop access. A local admin uses a password and a time-based one-time code by default. Cloudflare Access is an alternative for the admin console.

## Self-hosted sign-in

1. Copy `.env.production.example` to a private `.env.selfhost`. Set a database password and the instance's public HTTPS root URL in `AUTH_PUBLIC_URL`. With TOTP enabled, generate an `ADMIN_TOTP_KEY` using `openssl rand -base64 32`. Store this key alongside the database backup.
2. Configure a reverse proxy for `127.0.0.1:28080` that preserves `Host`, forwards WebSockets, and overwrites `X-Forwarded-Proto`. Set `TRUSTED_PROXY_CIDRS` to the actual direct proxy address as seen from the API container.
3. Start the stack and create an admin:

   ```sh
   docker compose --env-file .env.selfhost up -d --build --wait
   docker compose --env-file .env.selfhost exec api /server create-admin admin@example.com
   ```

4. Complete TOTP enrollment when prompted, save the recovery codes securely, and sign in at `/admin` with a fresh code. Create a regular user there, or run the following command:

   ```sh
   docker compose --env-file .env.selfhost exec api /server create-user user@example.com
   ```

5. In TaoScreen on macOS, choose **Account Connect → Custom Server**, save the instance URL, then use **Sign in with Email and Password** in the settings gear.

Use `reset-admin` to reset the local admin password, revoke admin sessions, and re-enroll the authenticator where required. A local admin session lasts eight hours. If you turn TOTP off, protect any existing enrollment and retain its key for re-enabling it later. Set `ADMIN_AUTH_MODE=disabled` to turn off the console.

## Cloudflare Access

Use a dedicated admin Access application for the admin host and the `/v1/admin/*` routes. Set `ADMIN_AUTH_MODE=cloudflare_access`, `ADMIN_ACCESS_TEAM_DOMAIN`, `ADMIN_ACCESS_AUD`, and `ADMIN_ALLOWED_EMAILS`. The server verifies the Access JWT signature, issuer, application audience, and expiry, and checks the administrator allowlist.

## Google setup

1. Create an OAuth client of type **Web application** in Google Cloud, and configure the app brand and intended audience.
2. Register the exact redirect URI `https://desktop.example.com/v1/auth/oauth/google/callback`.
3. Set `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` on the server.

The server requests `openid email profile`. It validates the ID token signature, issuer, audience, expiry, nonce, and verified email. The account identity is the Google `sub` claim.

## GitHub setup

1. Create a GitHub OAuth App with the instance HTTPS address as its homepage.
2. Register `https://desktop.example.com/v1/auth/oauth/github/callback` as the authorization callback URL.
3. Set `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET` on the server.

The server requests `read:user user:email` and uses the stable numeric GitHub user ID and the verified primary email. Repository permissions are unnecessary. An account without a verified primary email cannot complete sign-in.

## Registration and linking

The production template disables public registration and first-time third-party sign-up by default.

- When `ALLOW_SOCIAL_SIGNUP=false`, an unlinked Google or GitHub identity receives `social_signup_disabled`. An existing user can sign in through their original method and link the new provider from the account menu.
- When `ALLOW_SOCIAL_SIGNUP=true`, a new verified email can create an account. If the email already belongs to a TaoScreen account, the server returns `email_already_registered`, including for accounts that have never signed in. Sign in using the existing method and then link the provider. A matching email alone does not merge accounts.
- A provider identity already linked to another user, or a second identity from the same provider on one account, yields `identity_conflict`. An expired session cannot authorize a link.

Once linked, both methods use the same TaoScreen user ID and keep the account's devices and permissions.

## Desktop authorization and verification

The desktop client uses an authorization code, state, and S256 PKCE. The provider redirects to the server, which validates the browser session and identity before returning a short-lived code to `taoscreen://auth/callback`. The client exchanges it for TaoScreen tokens. No vendor or TaoScreen token is placed in the callback URL. A custom desktop callback scheme must match on both sides.

Discover configured methods at `GET /v1/auth/providers`. Always check the instance's readiness and test sign-in and linking with a new device before inviting users.
