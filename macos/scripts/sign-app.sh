#!/bin/bash
set -euo pipefail
APP=${1:?请指定要签名的 App}
APP_ENTITLEMENTS=${TAOSCREEN_APP_ENTITLEMENTS:-}
PROVISIONING_PROFILE=${TAOSCREEN_PROVISIONING_PROFILE:-}
if [ -n "${TAOSCREEN_SIGN_IDENTITY:-}" ]; then
    SIGN_ARGS=(--force --sign "$TAOSCREEN_SIGN_IDENTITY" --options runtime --timestamp)
else
    SIGN_ARGS=(--force --sign - --timestamp=none)
fi
codesign "${SIGN_ARGS[@]}" "$APP/Contents/Frameworks/WebRTC.framework"
# Sparkle 的独立安装器和 XPC 服务先签名，最后签框架及主应用。
SPARKLE_RUNTIME="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
for component in XPCServices/Downloader.xpc XPCServices/Installer.xpc Autoupdate Updater.app; do
    codesign "${SIGN_ARGS[@]}" "$SPARKLE_RUNTIME/$component"
done
codesign "${SIGN_ARGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
if [ -n "$PROVISIONING_PROFILE" ]; then
    cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
    codesign "${SIGN_ARGS[@]}" --entitlements "$APP_ENTITLEMENTS" "$APP"
else
    codesign "${SIGN_ARGS[@]}" "$APP"
fi
codesign --verify --deep --strict "$APP"
