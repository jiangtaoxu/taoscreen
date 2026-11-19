"""独立端口信令与桌面用途隔离，使用隔离测试账号。"""
import json
import time
import unittest
from support import EventSocket, request, uid, PASSWORD


class IndependentPortsTests(unittest.TestCase):
    def setUp(self):
        self.sockets = []
        self.email = f"ports-{uid()}@example.test"
        self.assertEqual(self.auth_request("/v1/auth/register", {"email": self.email, "password": PASSWORD})[0], 201)
        self.a, self.b, self.c = [self.login(self.email) for _ in range(3)]

    def tearDown(self):
        for sock in self.sockets:
            sock.close()

    def auth_request(self, path, data):
        result = request("POST", path, data)
        # 新增用例会触及每 IP 每分钟 30 次认证限制；遵守服务器明确的 Retry-After。
        if result[0] == 429 and result[1].get("error", {}).get("code") == "rate_limited":
            time.sleep(int(result[2]["Retry-After"]))
            result = request("POST", path, data)
        return result

    def login(self, email):
        device = uid()
        code, body, _ = self.auth_request("/v1/auth/login", {"email": email, "password": PASSWORD,
            "device_id": device, "device_name": "独立端口集成测试"})
        self.assertEqual(code, 200)
        body["device"] = device
        return body

    def connect(self, account, purpose="ports"):
        sock = EventSocket(account["access_token"], f"/v1/{purpose}/signal")
        self.sockets.append(sock)
        self.assertEqual(sock.status, 101)
        hello = sock.wait("hello")
        self.assertEqual(hello["from"], account["device"])
        if purpose == "ports":
            self.assertEqual(hello["payload"], {"independent": True, "resume": True, "keepalive": True})
        return sock

    def send(self, sock, kind, session, target, **payload):
        sock._send(1, json.dumps({"type": kind, "id": session.upper(), "to": target["device"].upper(),
            "from": uid(), "payload": payload}).encode())

    def peers(self, account, purpose):
        code, body, _ = request("GET", f"/v1/{purpose}/peers", token=account["access_token"])
        self.assertEqual(code, 200)
        return {p["id"] for p in body["peers"]}

    def invite(self, a, b, session):
        self.send(a, "invite", session, self.b)
        self.assertEqual(b.wait("invite")["from"], self.a["device"])
        self.send(b, "accept", session, self.a)
        self.assertEqual(a.wait("accept")["from"], self.b["device"])

    def assert_resume(self, sock, session, target):
        nonce = uid()
        self.send(sock, "resume", session, target, resume_token=nonce.upper())
        reply = sock.wait("resumed")
        self.assertEqual(reply["id"], session)
        self.assertEqual(reply["from"], target["device"])
        self.assertEqual(reply["payload"]["resume_token"], nonce)

    def test_independent_presence_and_disconnect_desktop_keeps_ports(self):
        a, b = self.connect(self.a), self.connect(self.b)
        self.assertEqual(self.peers(self.a, "ports"), {self.b["device"]})
        self.assertEqual(self.peers(self.a, "desktop"), set())
        session = uid()
        self.invite(a, b, session)
        da, db = self.connect(self.a, "desktop"), self.connect(self.b, "desktop")
        # 故意使用完全相同的 UUID，证明授权记录按用途隔离。
        self.invite(da, db, session)
        self.send(da, "end", session, self.b); db.wait("end")
        da.close(); db.close()
        self.send(a, "keepalive", session, self.b)
        self.assert_resume(a, session, self.b)
        self.send(a, "offer", session, self.b, sdp="independent data-only offer")
        self.assertEqual(b.wait("offer")["payload"]["sdp"], "independent data-only offer")
        self.send(b, "candidate", session, self.a, candidate="ports after desktop shutdown", line=0)
        self.assertEqual(a.wait("candidate")["payload"]["candidate"], "ports after desktop shutdown")
        self.assertEqual(self.peers(self.a, "ports"), {self.b["device"]})

    def test_ending_ports_keeps_desktop_and_consent_cannot_cross_purposes(self):
        a, b = self.connect(self.a), self.connect(self.b)
        da, db = self.connect(self.a, "desktop"), self.connect(self.b, "desktop")
        session = uid(); self.invite(da, db, session)
        self.send(a, "offer", session, self.b, sdp="cannot use desktop consent")
        self.assertEqual(a.wait("error")["payload"]["code"], "expired")
        self.send(a, "invite", session, self.b); b.wait("invite")
        self.send(a, "offer", session, self.b, sdp="before independent consent")
        self.assertEqual(a.wait("error")["payload"]["code"], "invalid_request")
        self.send(b, "accept", session, self.a); a.wait("accept")
        self.send(a, "end", session, self.b); b.wait("end")
        self.send(a, "keepalive", session, self.b)
        self.assertEqual(a.wait("error")["payload"]["code"], "expired")
        a.close(); b.close()
        self.assert_resume(da, session, self.b)
        self.send(da, "offer", session, self.b, sdp="desktop still authorized")
        self.assertEqual(db.wait("offer")["payload"]["sdp"], "desktop still authorized")

    def test_authorization_identity_reject_and_offline_purpose(self):
        a, b, c = self.connect(self.a), self.connect(self.b), self.connect(self.c, "desktop")
        self.send(a, "invite", uid(), self.c)
        self.assertEqual(a.wait("error")["payload"]["code"], "offline")
        session = uid()
        self.send(a, "invite", session, self.b); b.wait("invite")
        cp = self.connect(self.c)
        self.send(cp, "accept", session, self.a)
        self.assertEqual(cp.wait("error")["payload"]["code"], "forbidden")
        self.send(b, "reject", session, self.a); a.wait("reject")
        self.send(a, "resume", session, self.b, resume_token=uid())
        self.assertEqual(a.wait("error")["payload"]["code"], "expired")
        email = f"ports-other-{uid()}@example.test"
        self.assertEqual(self.auth_request("/v1/auth/register", {"email": email, "password": PASSWORD})[0], 201)
        other = self.login(email); self.connect(other)
        self.assertEqual(self.peers(other, "ports"), set())
        self.send(a, "invite", uid(), other)
        self.assertEqual(a.wait("error")["payload"]["code"], "offline")

    def test_auth_config_and_resuming_only_original_login(self):
        for path in ["config", "peers"]:
            self.assertEqual(request("GET", f"/v1/ports/{path}")[0], 401)
        unauth = EventSocket(path="/v1/ports/signal"); self.sockets.append(unauth)
        self.assertEqual(unauth.status, 401)
        code, config, _ = request("GET", "/v1/ports/config", token=self.a["access_token"])
        self.assertEqual(code, 200); self.assertIsInstance(config["ice_servers"], list)
        a, b = self.connect(self.a), self.connect(self.b)
        session = uid(); self.invite(a, b, session)
        duplicate = EventSocket(self.a["access_token"], "/v1/ports/signal"); self.sockets.append(duplicate)
        self.assertEqual(duplicate.status, 409)
        a.close()
        deadline = time.monotonic() + 5
        while True:
            reconnect = EventSocket(self.a["access_token"], "/v1/ports/signal"); self.sockets.append(reconnect)
            if reconnect.status == 101:
                reconnect.wait("hello"); break
            self.assertEqual(reconnect.status, 409)
            if time.monotonic() > deadline: self.fail("独立连接租约未释放")
            time.sleep(0.05)
        self.assert_resume(reconnect, session, self.b)
        self.assertEqual(request("POST", "/v1/auth/logout", {"refresh_token": self.b["refresh_token"]}, self.b["access_token"])[0], 204)
        self.send(reconnect, "keepalive", session, self.b)
        self.assertEqual(reconnect.wait("error")["payload"]["code"], "session_revoked")
