"""独立项目的服务边界、账号及令牌轮换验证。"""
import unittest
from support import request, uid, PASSWORD


class AccountTests(unittest.TestCase):
    def test_service_identity_and_removed_routes(self):
        status, body, _ = request("GET", "/health/ready")
        self.assertEqual(status, 200)
        self.assertEqual(body["service"], "taoscreen")
        for path in ["/v1/events", "/v1/sync/pull", "/v1/mirror/config", "/v1/remote/config", "/v1/music/config"]:
            self.assertEqual(request("GET", path)[0], 404, path)

    def test_public_download_page(self):
        status, body, headers = request("GET", "/download")
        self.assertEqual(status, 200)
        self.assertIn("text/html", headers["Content-Type"])
        self.assertIn("下载 macOS 客户端", body.decode())
        self.assertNotIn(b"{{nonce}}", body)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])
        self.assertEqual(request("GET", "/download/")[0], 200)
        status, body, _ = request("HEAD", "/download")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"")
        self.assertEqual(request("POST", "/download")[0], 405)

    def test_refresh_rotation_and_replayed_refresh_revokes_session(self):
        email = f"account-{uid()}@example.test"
        self.assertEqual(request("POST", "/v1/auth/register", {"email": email, "password": PASSWORD})[0], 201)
        status, original, _ = request("POST", "/v1/auth/login", {
            "email": email, "password": PASSWORD, "device_id": uid(), "device_name": "独立账号测试",
        })
        self.assertEqual(status, 200)
        self.assertEqual(request("GET", "/v1/me", token=original["access_token"])[1]["service"], "taoscreen")
        status, refreshed, _ = request("POST", "/v1/auth/refresh", {"refresh_token": original["refresh_token"]})
        self.assertEqual(status, 200)
        self.assertNotEqual(refreshed["refresh_token"], original["refresh_token"])
        self.assertEqual(request("GET", "/v1/desktop/peers", token=refreshed["access_token"])[0], 200)
        status, body, _ = request("POST", "/v1/auth/refresh", {"refresh_token": original["refresh_token"]})
        self.assertEqual(status, 401)
        self.assertEqual(body["error"]["code"], "refresh_replayed")
        self.assertEqual(request("GET", "/v1/desktop/peers", token=refreshed["access_token"])[0], 401)
