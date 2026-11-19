#!/bin/bash
# 构建 TaoScreen 正式安装包：自动递增版本，运行测试，完成 Developer ID 签名与独立公证；不上传。
set -euo pipefail
TAOSCREEN_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$TAOSCREEN_ROOT"
exec python3 scripts/package-release.py --notes-file RELEASE_NOTES.md "$@"
