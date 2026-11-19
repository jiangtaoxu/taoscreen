"""独立随机账户验证桌面信令；运行于本地真实 API/PostgreSQL/Redis。"""
import json
import time
import unittest
from support import EventSocket, request, uid, PASSWORD


class DesktopTests(unittest.TestCase):
    def setUp(self):
        self.sockets = []
        self.email = f"desktop-{uid()}@example.test"
        self.assertEqual(request("POST", "/v1/auth/register", {"email": self.email, "password": PASSWORD})[0], 201)
        self.a = self.login(self.email)
        self.b = self.login(self.email)
        self.c = self.login(self.email)

    def tearDown(self):
        for sock in self.sockets:
            sock.close()

    def login(self, email):
        device = uid()
        status, data, _ = request("POST", "/v1/auth/login", {"email": email, "password": PASSWORD, "device_id": device, "device_name": "桌面集成测试"})
        self.assertEqual(status, 200)
        data["device"] = device
        return data

    def connect(self, account):
        sock = EventSocket(account["access_token"], "/v1/desktop/signal")
        self.sockets.append(sock)
        self.assertEqual(sock.status, 101)
        self.assertEqual(sock.wait("hello")["from"], account["device"])
        return sock

    def send(self, sock, kind, session, target, **payload):
        # Swift UUID encoding uses uppercase; deliberately exercise canonicalization.
        message = {"type": kind, "id": session.upper(), "to": target["device"].upper(), "from": uid(), "payload": payload}
        sock._send(1, json.dumps(message).encode())

    def test_consent_identity_and_pair_isolation(self):
        a, b, c = self.connect(self.a), self.connect(self.b), self.connect(self.c)
        code, body, _ = request("GET", "/v1/desktop/peers", token=self.a["access_token"])
        self.assertEqual(code, 200)
        self.assertEqual({p["id"] for p in body["peers"]}, {self.b["device"], self.c["device"]})
        session = uid()
        self.send(a, "invite", session, self.b)
        invite = b.wait("invite")
        self.assertEqual(invite["from"], self.a["device"])
        self.assertEqual(invite["id"], session)
        self.send(a, "offer", session, self.b, sdp="before consent")
        self.assertEqual(a.wait("error")["id"].lower(), session)
        self.send(c, "accept", session, self.a)
        self.assertEqual(c.wait("error")["id"].lower(), session)
        self.send(b, "accept", session, self.a, control=False, audio=False)
        self.assertFalse(a.wait("accept")["payload"]["control"])
        self.send(a, "offer", session, self.b, sdp="v=0\r\n")
        self.assertEqual(b.wait("offer")["payload"]["sdp"], "v=0\r\n")
        self.send(b, "answer", session, self.a, sdp="answer")
        self.assertEqual(a.wait("answer")["from"], self.b["device"])
        self.send(a, "candidate", session, self.b, candidate="candidate", line=0)
        self.assertEqual(b.wait("candidate")["payload"]["line"], 0)
        self.send(a, "candidate", session, self.c, candidate="cannot redirect")
        self.assertEqual(a.wait("error")["id"].lower(), session)
        self.send(a, "end", session, self.b)
        self.assertEqual(b.wait("end")["id"], session)
        self.send(b, "candidate", session, self.a, candidate="late")
        self.assertEqual(b.wait("error")["id"].lower(), session)

    def test_account_isolation_reject_and_offline(self):
        a, b = self.connect(self.a), self.connect(self.b)
        email = f"other-desktop-{uid()}@example.test"
        self.assertEqual(request("POST", "/v1/auth/register", {"email": email, "password": PASSWORD})[0], 201)
        other = self.login(email)
        self.connect(other)
        body = request("GET", "/v1/desktop/peers", token=other["access_token"])[1]
        self.assertEqual(body["peers"], [])
        self.send(a, "invite", uid(), other)
        self.assertEqual(a.wait("error")["type"], "error")
        session = uid()
        self.send(a, "invite", session, self.b); b.wait("invite")
        self.send(b, "reject", session, self.a); a.wait("reject")
        self.send(a, "offer", session, self.b, sdp="late"); a.wait("error")
        b.close()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            peers = request("GET", "/v1/desktop/peers", token=self.a["access_token"])[1]["peers"]
            if not peers:
                break
            time.sleep(0.05)
        self.assertEqual(peers, [])
        self.send(a, "invite", uid(), self.b); a.wait("error")

    def test_auth_and_configuration(self):
        self.assertEqual(request("GET", "/v1/desktop/config")[0], 401)
        self.assertEqual(request("GET", "/v1/desktop/peers")[0], 401)
        unauth = EventSocket(path="/v1/desktop/signal")
        self.sockets.append(unauth)
        self.assertEqual(unauth.status, 401)
        status, config, _ = request("GET", "/v1/desktop/config", token=self.a["access_token"])
        self.assertEqual(status, 200)
        self.assertIsInstance(config["ice_servers"], list)
        for server in config["ice_servers"]:
            if server["urls"][0].startswith(("turn:", "turns:")):
                expiry, device = server["username"].split(":", 1)
                self.assertEqual(device, self.a["device"])
                self.assertTrue(7100 < int(expiry) - time.time() <= 7200)
                self.assertTrue(server["credential"])
        a = self.connect(self.a)
        duplicate = EventSocket(self.a["access_token"], "/v1/desktop/signal")
        self.sockets.append(duplicate)
        self.assertEqual(duplicate.status, 409)
        # Revoked sessions can no longer signal, even over an already open socket.
        self.assertEqual(request("POST", "/v1/auth/logout", {"refresh_token": self.a["refresh_token"]}, self.a["access_token"])[0], 204)
        self.send(a, "invite", uid(), self.b)
        try:
            self.assertEqual(a.recv()["type"], "session_revoked")
            self.assertIsNone(a.recv())
            self.assertEqual(a.close_code, 4001)
        except ConnectionError:
            pass

    def reconnect(self, account):
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline:
            sock = EventSocket(account["access_token"], "/v1/desktop/signal")
            self.sockets.append(sock)
            if sock.status == 101:
                hello = sock.wait("hello")
                self.assertTrue(hello["payload"]["resume"])
                return sock
            self.assertEqual(sock.status, 409)
            sock.sock.close()
            time.sleep(0.1)
        self.fail("closed signaling connection did not release its lease")

    def test_resume_original_session_without_new_invitation(self):
        a, b = self.connect(self.a), self.connect(self.b)
        session = uid()
        self.send(a, "invite", session, self.b); b.wait("invite")
        self.send(b, "accept", session, self.a, control=True); a.wait("accept")
        a.close()
        a = self.reconnect(self.a)
        nonce = uid()
        self.send(a, "resume", session, self.b, resume_token=nonce.upper())
        resumed = a.wait("resumed")
        self.assertEqual(resumed["id"], session)
        self.assertEqual(resumed["from"], self.b["device"])
        self.assertEqual(resumed["payload"]["resume_token"], nonce)
        self.send(a, "candidate", session, self.b, candidate="after resume", line=0)
        self.assertEqual(b.wait("candidate")["payload"]["candidate"], "after resume")
        self.send(a, "end", session, self.b); b.wait("end")
        self.send(a, "resume", session, self.b, resume_token=uid())
        self.assertEqual(a.wait("error")["payload"]["code"], "expired")

    def test_resume_rechecks_consent_participant_and_both_logins(self):
        a, b, c = self.connect(self.a), self.connect(self.b), self.connect(self.c)
        session = uid()
        self.send(a, "invite", session, self.b); b.wait("invite")
        self.send(a, "resume", session, self.b, resume_token=uid())
        self.assertEqual(a.wait("error")["payload"]["code"], "invalid_request")
        self.send(b, "accept", session, self.a); a.wait("accept")
        self.send(c, "resume", session, self.b, resume_token=uid())
        self.assertEqual(c.wait("error")["payload"]["code"], "forbidden")
        status, replacement, _ = request("POST", "/v1/auth/login", {
            "email": self.email, "password": PASSWORD, "device_id": self.a["device"], "device_name": "same device new login"})
        self.assertEqual(status, 200)
        replacement["device"] = self.a["device"]
        a.close()
        changed = self.reconnect(replacement)
        self.send(changed, "resume", session, self.b, resume_token=uid())
        self.assertEqual(changed.wait("error")["payload"]["code"], "session_changed")
        self.send(changed, "keepalive", session, self.b)
        self.assertEqual(changed.wait("error")["payload"]["code"], "session_changed")
        changed.close()
        a = self.reconnect(self.a)
        self.assertEqual(request("POST", "/v1/auth/logout", {"refresh_token": self.b["refresh_token"]}, self.b["access_token"])[0], 204)
        self.send(a, "resume", session, self.b, resume_token=uid())
        self.assertEqual(a.wait("error")["payload"]["code"], "session_revoked")

    def test_keepalive_rechecks_consent_identity_and_does_not_revive_ended_session(self):
        a, b, c = self.connect(self.a), self.connect(self.b), self.connect(self.c)
        session = uid()
        self.send(a, "invite", session, self.b); b.wait("invite")
        self.send(a, "keepalive", session, self.b)
        self.assertEqual(a.wait("error")["payload"]["code"], "invalid_request")
        self.send(b, "accept", session, self.a); a.wait("accept")
        self.send(c, "keepalive", session, self.b)
        self.assertEqual(c.wait("error")["payload"]["code"], "forbidden")
        self.send(a, "keepalive", session, self.c)
        self.assertEqual(a.wait("error")["payload"]["code"], "forbidden")
        self.send(a, "keepalive", session, self.b)
        # 同一连接按序处理；resume 成功意味着前一条续期已完成。
        self.send(a, "resume", session, self.b, resume_token=uid())
        reply = a.recv()
        while reply and reply["type"] == "heartbeat":
            reply = a.recv()
        self.assertIsNotNone(reply)
        self.assertEqual(reply["type"], "resumed")
        self.send(a, "end", session, self.b); b.wait("end")
        self.send(a, "keepalive", session, self.b)
        self.assertEqual(a.wait("error")["payload"]["code"], "expired")

        session = uid()
        self.send(a, "invite", session, self.b); b.wait("invite")
        self.send(b, "accept", session, self.a); a.wait("accept")
        self.assertEqual(request("POST", "/v1/auth/logout", {"refresh_token": self.b["refresh_token"]}, self.b["access_token"])[0], 204)
        self.send(a, "keepalive", session, self.b)
        self.assertEqual(a.wait("error")["payload"]["code"], "session_revoked")

    def test_heartbeat_reclaims_half_open_connection_and_keeps_responsive_peer(self):
        # Read hello, then deliberately stop reading: no automatic Pong responses.
        stale = self.connect(self.a)
        deadline = time.monotonic() + 45
        recovered = None
        conflicts = 0
        while time.monotonic() < deadline:
            probe = EventSocket(self.a["access_token"], "/v1/desktop/signal")
            self.sockets.append(probe)
            if probe.status == 101:
                recovered = probe
                self.assertEqual(probe.wait("hello")["type"], "hello")
                break
            self.assertEqual(probe.status, 409)
            conflicts += 1
            probe.sock.close()
            time.sleep(2)
        self.assertGreater(conflicts, 0)
        self.assertIsNotNone(recovered, "missing Pong must release the lease, not renew it forever")
        # recv responds to Ping: a healthy connection survives multiple heartbeat cycles.
        self.assertEqual(recovered.wait("heartbeat", timeout=40)["type"], "heartbeat")
        self.assertEqual(recovered.wait("heartbeat", timeout=40)["type"], "heartbeat")
        duplicate = EventSocket(self.a["access_token"], "/v1/desktop/signal")
        self.sockets.append(duplicate)
        self.assertEqual(duplicate.status, 409)
        duplicate.sock.close()
