#!/bin/bash
# 发布 TaoScreen 新版本：自动递增版本、测试、签名公证、上传 TaoScreen R2 并验证公开下载，最后更新客户端可发现的清单。
set -euo pipefail
TAOSCREEN_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$TAOSCREEN_ROOT"
exec python3 scripts/package-release.py --notes-file RELEASE_NOTES.md --upload "$@"
