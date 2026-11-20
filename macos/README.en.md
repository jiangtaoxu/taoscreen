# TaoScreen for macOS

English · [简体中文](README.md) · [Project README](../README.en.md) · [User Guide](../docs/user-guide.en.md) · [Server](../server/README.en.md)

The native client targets macOS 14 or later using Swift 5 language mode, WebRTC 154.0.0, and Sparkle 2.10.0. The app bundles the dependency licenses.

## Build and test

Install Xcode and XcodeGen (`brew install xcodegen`). Run from `macos/`:

```sh
swift test
./scripts/build-app.sh
open dist/TaoScreen.app
```

The script generates the Xcode project, embeds the frameworks, and signs an app for local testing. It defaults to Debug and accepts `Release`. For permission testing, launch the packaged app rather than `swift run`. Build identity matters for app settings, Keychain data, and macOS privacy approvals. The development bundle ID is `org.taoscreen.development`; customize it with `TAOSCREEN_BUNDLE_ID`.

| Option | Use |
| --- | --- |
| `TAOSCREEN_DEFAULT_SERVER_URL` | Preconfigure an HTTPS account server |
| `TAOSCREEN_OAUTH_CALLBACK_SCHEME` | Match the server's `DESKTOP_OAUTH_CALLBACK_SCHEME`. Both default to `taoscreen`. |
| `TAOSCREEN_SIGN_IDENTITY` | Use a signing certificate instead of an ad-hoc signature |

Local server development can use `http://127.0.0.1:28080`. Remote server addresses use HTTPS.

## Languages

TaoScreen supports English and Simplified Chinese. By default it uses the first supported language in macOS preferences, or English when neither is listed. Choose a language using the globe at the top of the main window. Confirm a restart to apply it. This closes active sessions.

Chinese text is maintained with the Swift source. English translations are bundled in [English.json](Sources/TaoScreen/Resources/English.json). Keep numbered placeholders in the catalog intact when changing an interpolated string.

## Client features

- **Direct Connect.** Connect over a LAN or Tailscale with a temporary password. Use a fixed password or trusted devices for unattended access within Tailscale. TCP listeners are `45871`, `45873`, and `45872` respectively.
- **Account Connect.** The official package defaults to the official server. The gear menu lets signed-out users select a custom server. The login screen shows the Google and GitHub providers enabled by the current instance. Account linking is available from the account menu.
- **Permissions and capture.** The host uses Screen & System Audio Recording, plus Accessibility when control is authorized. Physical and virtual extended displays are available. Virtual display choices include 1080p, 1440p, and HiDPI 4K.
- **Remote input and security.** Choose where shortcuts and input methods run. The local Keychain can hold authorized remote login passwords, with Touch ID when available. The host can lock its screen after a session ends if this option was authorized.
- **Port forwarding.** Independent account sessions carry bidirectional TCP or UDP traffic. Rules default to loopback listening. Each peer must authorize this service separately.
- **Sharing and transfer.** Where permitted, share the clipboard, send files, or use drag and drop. Files are normally received in `~/Downloads/TaoScreen`. Active direct unattended sessions limit file and clipboard features.

See the [User Guide](../docs/user-guide.en.md) for operating instructions.

## Updates

Sparkle uses an HTTPS appcast and an Ed25519 public key. Updates are disabled in the default source build. Configure `TAOSCREEN_UPDATE_FEED_URL` and `TAOSCREEN_UPDATE_PUBLIC_KEY` to provide your own update feed. Installing an update restarts the app and ends active connections.

| Command | Output |
| --- | --- |
| `./scripts/build-release.sh` | Tests, signed and notarized release files in `dist/releases` when credentials are configured |
| `./scripts/build-release.sh X.Y.Z --universal` | One universal DMG, a signed Sparkle ZIP, and universal appcast and release manifest |
| `./scripts/publish-production.sh` | Build, upload, and verify a configured release |
| `./scripts/upload-release.sh` | Upload previously built release artifacts |

Configure Developer ID, team, and notarization credentials securely with `TAOSCREEN_SIGN_IDENTITY`, `TAOSCREEN_TEAM_ID`, and `TAOSCREEN_NOTARY_PROFILE`. `TAOSCREEN_RELEASE_ORIGIN` sets the HTTPS distribution origin. The bundled update public key can also be read from `TAOSCREEN_UPDATE_PUBLIC_KEY_FILE`. Keep the Sparkle private key in the publisher's Keychain. To create it, run `swift package resolve` and `python3 scripts/package-release.py --init-update-key`.

The [GitHub Actions release workflow](../.github/workflows/macos-release.yml) can build, notarize, and publish a universal DMG for a version tag. Set `MACOS_TEAM_ID` and the signing and notary values in the release environment. Release secrets include `MACOS_SIGNING_P12`, `MACOS_SIGNING_P12_PASSWORD`, `MACOS_NOTARY_APPLE_ID`, and `MACOS_NOTARY_PASSWORD`. See the [release manifest guide](../server/docs/desktop-updates.en.md) for upload order and validation.
