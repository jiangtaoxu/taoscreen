#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
CONFIGURATION=${1:-Debug}
case "$CONFIGURATION" in Debug|Release) ;; *) echo '用法：scripts/build-app.sh [Debug|Release]' >&2; exit 1 ;; esac
APP_ENTITLEMENTS=${TAOSCREEN_APP_ENTITLEMENTS:-}
PROVISIONING_PROFILE=${TAOSCREEN_PROVISIONING_PROFILE:-}
if [ -n "$APP_ENTITLEMENTS$PROVISIONING_PROFILE" ]; then
    if [ ! -f "$APP_ENTITLEMENTS" ] || [ ! -f "$PROVISIONING_PROFILE" ] || [ -z "${TAOSCREEN_SIGN_IDENTITY:-}" ]; then
        echo '配置钥匙串权限需要签名证书、entitlements 文件和匹配的描述文件。' >&2
        exit 1
    fi
    plutil -lint "$APP_ENTITLEMENTS"
fi
BUILD_ROOT="$ROOT/.build/xcode"
OUTPUT="$ROOT/dist/TaoScreen.app"
ARCHS=$(uname -m)
DESTINATION="platform=macOS,arch=$ARCHS"
ONLY_ACTIVE_ARCH=YES
if [ "${TAOSCREEN_BUILD_UNIVERSAL:-}" = 1 ]; then
    ARCHS="arm64 x86_64"
    DESTINATION="generic/platform=macOS"
    ONLY_ACTIVE_ARCH=NO
fi
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"
xcodebuild -quiet -project "$ROOT/TaoScreen.xcodeproj" -scheme TaoScreen \
    -configuration "$CONFIGURATION" -destination "$DESTINATION" \
    -derivedDataPath "$BUILD_ROOT" -clonedSourcePackagesDirPath "$ROOT/.build/SourcePackages" \
    ARCHS="$ARCHS" ONLY_ACTIVE_ARCH="$ONLY_ACTIVE_ARCH" CODE_SIGNING_ALLOWED=NO \
    INFOPLIST_FILE="${TAOSCREEN_BUILD_INFO_PLIST:-Resources/Info.plist}" \
    PRODUCT_BUNDLE_IDENTIFIER="${TAOSCREEN_BUNDLE_ID:-org.taoscreen.development}" \
    TAOSCREEN_OAUTH_CALLBACK_SCHEME="${TAOSCREEN_OAUTH_CALLBACK_SCHEME:-taoscreen}" \
    TAOSCREEN_DEFAULT_SERVER_URL="${TAOSCREEN_DEFAULT_SERVER_URL:-}" \
    TAOSCREEN_UPDATE_FEED_URL="${TAOSCREEN_UPDATE_FEED_URL:-}" \
    TAOSCREEN_UPDATE_PUBLIC_KEY="${TAOSCREEN_UPDATE_PUBLIC_KEY:-}" build
BUILT_APP="$BUILD_ROOT/Build/Products/$CONFIGURATION/TaoScreen.app"
test -x "$BUILT_APP/Contents/MacOS/TaoScreen"
mkdir -p "$ROOT/dist"
rm -rf "$OUTPUT"
ditto "$BUILT_APP" "$OUTPUT"
if [ -n "${TAOSCREEN_SIGN_IDENTITY:-}" ]; then
    SIGN_ARGS=(--force --sign "$TAOSCREEN_SIGN_IDENTITY" --options runtime --timestamp)
else
    SIGN_ARGS=(--force --sign - --timestamp=none)
fi
codesign "${SIGN_ARGS[@]}" "$OUTPUT/Contents/Frameworks/WebRTC.framework"
# Sparkle 的独立安装器和 XPC 服务先签名，最后签框架及主应用。
SPARKLE_RUNTIME="$OUTPUT/Contents/Frameworks/Sparkle.framework/Versions/Current"
for component in XPCServices/Downloader.xpc XPCServices/Installer.xpc Autoupdate Updater.app; do
    codesign "${SIGN_ARGS[@]}" "$SPARKLE_RUNTIME/$component"
done
codesign "${SIGN_ARGS[@]}" "$OUTPUT/Contents/Frameworks/Sparkle.framework"
cp "$ROOT/.build/SourcePackages/artifacts/sparkle/Sparkle/LICENSE" "$OUTPUT/Contents/Resources/Sparkle-LICENSE.txt"
if [ -n "$PROVISIONING_PROFILE" ]; then
    cp "$PROVISIONING_PROFILE" "$OUTPUT/Contents/embedded.provisionprofile"
    codesign "${SIGN_ARGS[@]}" --entitlements "$APP_ENTITLEMENTS" "$OUTPUT"
else
    codesign "${SIGN_ARGS[@]}" "$OUTPUT"
fi
codesign --verify --deep --strict "$OUTPUT"
echo "已生成：$OUTPUT"
