#!/usr/bin/env python3
"""只初始化本项目的新配置；不读取或覆盖其他服务配置。"""
import os
from pathlib import Path
import secrets

root = Path(__file__).resolve().parents[1]
target = root / ".env"
contents = (root / ".env.example").read_text().replace(
    "REPLACE_WITH_A_NEW_RANDOM_PASSWORD", secrets.token_hex(32)
)
try:
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
except FileExistsError:
    raise SystemExit("本项目 .env 已存在，未覆盖。")
with os.fdopen(fd, "w") as output:
    output.write(contents)
print("已生成独立本地配置；密钥未输出。")
