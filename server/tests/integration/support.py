"""在运行中的本地 Docker API 上测试，使用独立随机账户，不读取客户端数据。"""
import base64
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import unittest
import urllib.error
import urllib.parse
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[2]
BASE = os.environ.get("TAOSCREEN_TEST_URL", "http://127.0.0.1:28080")
PASSWORD = "TaoScreen-local-tests-only-123!"
DATE = "2026-01-01T08:00:00Z"


def uid():
    return str(uuid.uuid4())


def request(method, path, data=None, token=None, headers=None):
    headers = dict(headers or {})
    if data is not None and not isinstance(data, bytes):
        data = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(BASE + path, data=data, method=method, headers=headers)
    try:
        response = urllib.request.urlopen(req, timeout=45)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        raw = response.read()
        body = json.loads(raw) if "application/json" in response.headers.get("Content-Type", "") else raw
        return response.status, body, response.headers


class EventSocket:
    """最小 WebSocket 客户端：只用于读取服务端推送的实时事件。"""

    def __init__(self, token=None, path="/v1/desktop/signal"):
        url = urllib.parse.urlparse(BASE)
        self.sock = socket.create_connection((url.hostname, url.port or 80), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        auth = f"Authorization: Bearer {token}\r\n" if token else ""
        self.sock.sendall((f"GET {path} HTTP/1.1\r\nHost: {url.hostname}:{url.port}\r\nUpgrade: websocket\r\n"
                           f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n{auth}\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(1)
            if not chunk:
                break
            head += chunk
        self.status = int(head.split(b" ", 2)[1])
        self.close_code = None

    def _read(self, n):
        data = b""
        while len(data) < n:
            chunk = self.sock.recv(n - len(data))
            if not chunk:
                raise ConnectionError("连接已关闭")
            data += chunk
        return data

    def _send(self, opcode, payload=b""):
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        length = len(payload)
        header = bytes([0x80 | opcode, 0x80 | length]) if length < 126 else bytes([0x80 | opcode, 0x80 | 126]) + struct.pack("!H", length)
        self.sock.sendall(header + mask + masked)

    def recv(self, timeout=10):
        """返回下一条 JSON 事件；连接关闭时返回 None 并记录关闭码。自动回应 ping。"""
        self.sock.settimeout(timeout)
        while True:
            first, second = self._read(2)
            length = second & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._read(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._read(8))[0]
            payload = self._read(length)
            opcode = first & 0x0F
            if opcode == 0x9:
                self._send(0xA, payload)
            elif opcode == 0x8:
                self.close_code = struct.unpack("!H", payload[:2])[0] if len(payload) >= 2 else None
                return None
            elif opcode == 0x1:
                return json.loads(payload)

    def wait(self, kind, timeout=10):
        """跳过心跳和其他类型，等到指定类型的事件。"""
        while True:
            event = self.recv(timeout)
            if event is None or event["type"] == kind:
                return event

    def close(self):
        try:
            self._send(0x8, struct.pack("!H", 1000))
            self.sock.close()
        except OSError:
            pass
