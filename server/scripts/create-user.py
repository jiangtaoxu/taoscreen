#!/usr/bin/env python3
"""交互式创建本项目账号，密码不进入参数或日志。"""
import getpass
from pathlib import Path
import subprocess
import sys

if len(sys.argv) != 2:
    raise SystemExit("用法：python3 scripts/create-user.py <邮箱>")
password = getpass.getpass("新账号密码（至少 12 个字符）：")
if password != getpass.getpass("再次输入密码："):
    raise SystemExit("两次密码不一致。")
result = subprocess.run(
    ["docker", "compose", "exec", "-T", "api", "/server", "create-user", sys.argv[1]],
    input=(password + "\n").encode(), cwd=Path(__file__).resolve().parents[1],
)
raise SystemExit(result.returncode)
