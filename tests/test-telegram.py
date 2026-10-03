#!/usr/bin/env python3
"""Offline tests for Telegram metrics, access summaries and command rendering."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "emby-proxy").read_text()
source = source.split("controller_cli() {", 1)[1].split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
ns = {"__name__": "telegram_under_test"}
exec(compile(source, "emby-proxy:telegram", "exec"), ns)


class TelegramTests(unittest.TestCase):
    def test_metrics_collect_clients_devices_and_paths(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            log = root / "access.log"
            log.write_text("\n".join([
                json.dumps({"time": "2030-01-01T00:00:00+00:00", "request": {"remote_ip": "192.0.2.10", "uri": "/Videos/1", "headers": {"User-Agent": ["Emby Android"]}}, "status": 200, "bytes_sent": 1024}),
                json.dumps({"time": "2030-01-01T00:00:01+00:00", "request": {"remote_ip": "192.0.2.11", "uri": "/web/index.html", "headers": {"User-Agent": ["Mozilla/5.0 (Windows NT 10.0)"]}}, "status": 503, "bytes_sent": 512}),
            ]) + "\n")
            with patch.dict(ns, {"time": type("Clock", (), {"time": staticmethod(lambda: 1893456002)})()}):
                metrics = ns["collect_access_metrics"]({"access_log": str(log)}, window=300)
            self.assertEqual(metrics["requests"], 2)
            self.assertEqual(metrics["bytes"], 1536)
            self.assertEqual(metrics["errors"], 1)
            self.assertEqual(metrics["clients"][0]["name"], "192.0.2.10")
            self.assertEqual(metrics["devices"][0]["name"], "Android")

    def test_heartbeat_sanitizes_metrics(self):
        path = Path(tempfile.mkdtemp()) / "state.json"
        state = {"schema_version": 1, "entry_id": "domain-test.example.com", "domain": "test.example.com",
                 "source": "https://origin.example.com", "engine": "caddy", "nodes": {
                     "edge-a": {"token_hash": ns["digest"]("token"), "healthy": True, "last_seen": 1000,
                                 "priority": 100, "quota_bytes": 0, "used_bytes": 0}
                 }, "enroll_tokens": {}, "active_node": None,
                 "telegram": {"enabled": True, "chat_ids": []}}
        path.write_text(json.dumps(state))
        controller = ns["Controller"](path)
        code, _ = controller.heartbeat({"node_id": "edge-a", "healthy": True, "used_bytes": 1,
            "metrics": {"generated_at": 1000, "window_seconds": 300, "requests": 2, "bytes": 3, "errors": 0,
                         "clients": [{"name": "192.0.2.10", "requests": 2, "bytes": 3, "extra": "ignored"}]},
            "address_family": "ipv4"}, "token")
        self.assertEqual(code, 200)
        saved = json.loads(path.read_text())["nodes"]["edge-a"]["metrics"]
        self.assertEqual(saved["clients"][0]["name"], "192.0.2.10")
        self.assertNotIn("extra", saved["clients"][0])
        self.assertEqual(saved["devices"], [])

    def test_heartbeat_metrics_are_opt_in_and_controller_tells_edge(self):
        path = Path(tempfile.mkdtemp()) / "state.json"
        state = {"schema_version": 1, "entry_id": "domain-test.example.com", "domain": "test.example.com",
                 "source": "https://origin.example.com", "engine": "caddy", "nodes": {
                     "edge-a": {"token_hash": ns["digest"]("token"), "healthy": True, "last_seen": ns["now"](),
                                 "priority": 100, "quota_bytes": 0, "used_bytes": 0}
                 }, "enroll_tokens": {}, "active_node": None, "telegram": {"enabled": False}}
        path.write_text(json.dumps(state))
        controller = ns["Controller"](path)
        code, result = controller.heartbeat({"node_id": "edge-a", "healthy": True, "used_bytes": 1,
            "metrics": {"requests": 99, "bytes": 100}, "address_family": "ipv4"}, "token")
        self.assertEqual(code, 200); self.assertFalse(result["telemetry_enabled"])
        self.assertNotIn("metrics", json.loads(path.read_text())["nodes"]["edge-a"])
        state = json.loads(path.read_text()); state["telegram"] = {"enabled": True}; path.write_text(json.dumps(state))
        code, result = controller.heartbeat({"node_id": "edge-a", "healthy": True, "used_bytes": 2,
            "metrics": {"requests": 3, "bytes": 4}, "address_family": "ipv4"}, "token")
        self.assertEqual(code, 200); self.assertTrue(result["telemetry_enabled"])
        self.assertEqual(json.loads(path.read_text())["nodes"]["edge-a"]["metrics"]["bytes"], 4)

    def test_metrics_tail_is_bounded_and_marks_sampling(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root); log = root / "access.log"
            rows = [json.dumps({"ts": 1893456000 + i, "request": {"remote_ip": "192.0.2.10", "uri": "/x"},
                                "status": 200, "bytes_sent": 1}) for i in range(1200)]
            log.write_text("\n".join(rows) + "\n")
            with patch.dict(ns, {"time": type("Clock", (), {"time": staticmethod(lambda: 1893456200)})()}):
                metrics = ns["collect_access_metrics"]({"access_log": str(log), "access_log_max_bytes": 65536}, window=300, limit=5000)
            self.assertTrue(metrics["truncated"])
            self.assertLessEqual(metrics["sampled_rows"], 1200)

    def test_render_commands_and_config_validation(self):
        state = {"entry_id": "domain-test.example.com", "domain": "test.example.com",
                 "source": "https://origin.example.com", "address_family": "ipv4", "active_node": "edge-a",
                 "nodes": {"edge-a": {"name": "线路 A", "healthy": True, "last_seen": 1893456000,
                         "public_ip": "192.0.2.10", "used_bytes": 2048, "quota_bytes": 0,
                         "metrics": {"generated_at": 1893456000, "window_seconds": 300, "bytes": 1024, "requests": 2, "clients": [{"name": "192.0.2.9", "requests": 2, "bytes": 1024}],
                                     "devices": [{"name": "Android", "requests": 2, "bytes": 1024}], "paths": []}}}}
        self.assertIn("/nodes", ns["telegram_render"](state, "/help", "/tmp/state.json"))
        with patch.dict(ns, {"now": lambda: 1893456002}):
            self.assertIn("192.0.2.9", ns["telegram_render"](state, "/access", "/tmp/state.json"))
            self.assertIn("Android", ns["telegram_render"](state, "/devices", "/tmp/state.json"))
        self.assertIn("origin.example.com", ns["telegram_render"](state, "/origins", "/tmp/state.json"))

    def test_configure_writes_private_token_and_chat_allowlist(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root); state_path = root / "controller.json"; incoming = root / "incoming.token"
            state_path.write_text(json.dumps({"entry_id": "domain-test.example.com", "nodes": {}}))
            incoming.write_text("123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZ_123456")
            with patch.dict(ns, {"telegram_api": lambda *args, **kwargs: {"id": 1}}):
                args = type("Args", (), {"state": str(state_path), "token_file": str(incoming), "chat_ids": "123456789,-1001234567890",
                                          "persist_token": "", "test": False})()
                ns["telegram_configure"](args)
            saved = json.loads(state_path.read_text())
            token_path = Path(saved["telegram"]["token_file"])
            self.assertEqual(saved["telegram"]["chat_ids"], ["123456789", "-1001234567890"])
            self.assertEqual(token_path.read_text(), incoming.read_text())
            self.assertEqual(token_path.stat().st_mode & 0o777, 0o600)

    def test_reconfigure_drops_old_chat_alerts_and_starts_new_generation(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root); state_path = root / "controller.json"; incoming = root / "incoming.token"
            old = root / "old.token"; old.write_text("111111:OLDTOKENABCDEFGHIJKLMNOPQRSTUVWXYZ")
            old.chmod(0o600); incoming.write_text("123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZ_123456")
            state_path.write_text(json.dumps({"entry_id": "domain-test.example.com", "nodes": {},
                "telegram": {"enabled": True, "token_file": str(old), "chat_ids": ["111"],
                              "configuration_id": "old-generation", "alert_state": {"old": True},
                              "pending_alerts": [{"id": "old-event", "message": "old chat"}]}}))
            with patch.dict(ns, {"telegram_api": lambda *args, **kwargs: {"id": 1}}):
                args = type("Args", (), {"state": str(state_path), "token_file": str(incoming),
                                          "chat_ids": "222", "persist_token": "", "test": False})()
                ns["telegram_configure"](args)
            config = json.loads(state_path.read_text())["telegram"]
            self.assertEqual(config["chat_ids"], ["222"])
            self.assertNotEqual(config.get("configuration_id"), "old-generation")
            self.assertEqual(config.get("alert_state"), {})
            self.assertEqual(config.get("pending_alerts"), [])

    def test_telegram_send_splits_utf16_limited_messages(self):
        sent = []
        with patch.dict(ns, {"telegram_api": lambda token, method, payload, timeout=0: sent.append(payload["text"]) or {}}):
            ns["telegram_send"]("fixture-token", "123456", "😀" * 3000)
        self.assertGreater(len(sent), 1)
        self.assertTrue(all(len(text.encode("utf-16-le")) // 2 <= ns["TELEGRAM_MESSAGE_LIMIT"] for text in sent))


if __name__ == "__main__":
    unittest.main()
