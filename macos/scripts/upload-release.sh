#!/bin/bash
# 上传已构建的 TaoScreen 正式安装包并更新版本清单，不重新构建；只访问 TaoScreen 独立发布桶。
set -euo pipefail
TAOSCREEN_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$TAOSCREEN_ROOT"
exec python3 scripts/package-release.py --upload-only "$@"
