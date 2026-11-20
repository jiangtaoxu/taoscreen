# Desktop Downloads and Updates

English · [简体中文](desktop-updates.md) · [Server README](../README.en.md)

Set `DESKTOP_RELEASE_ORIGIN` to an HTTPS file origin, for example `https://downloads.example.com`. This can be object storage or a static file service. If the setting is empty, `/download` shows that packages are unavailable.

Host `taoscreen-macos-arm64.json` and `taoscreen-macos-x86_64.json` for the architectures you publish. The package URL uses `/macos/<version>/TaoScreen-<version>-<architecture>.dmg`. The [macOS release scripts](../../macos/README.en.md#updates) generate installers, manifests, and Sparkle appcasts.

Use `GET /v1/desktop/updates/latest?platform=macos&arch=arm64&current=1.0.0` to query the latest version. The server validates the origin, package path, architecture, version, file size, and SHA-256 checksum.

Sparkle uses a build-time HTTPS appcast and Ed25519 public key. Upload and verify the signed, notarized ZIP and DMG before publishing the manifest and appcast. Configure signing and notarization in the publisher's local environment or CI.
