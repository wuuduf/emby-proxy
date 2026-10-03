#!/usr/bin/env python3
"""Deterministic regressions for Telegram runtime authorization and outbox."""
import json
from pathlib import Path
import tempfile
import unittest
import urllib.error
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "emby-proxy").read_text()
source = source.split("controller_cli() {", 1)[1].split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
ns = {"__name__": "telegram_runtime_under_test"}
exec(compile(source, "emby-proxy:telegram-runtime", "exec"), ns)


class TelegramRuntimeTests(unittest.TestCase):
    def state(self, root, **telegram):
        state = {
            "schema_version": 1, "entry_id": "domain-test.example.com",
            "domain": "test.example.com", "source": "https://origin.example.com",
            "nodes": {}, "active_node": None,
            "telegram": {"enabled": True, "chat_ids": ["111", "222"], **telegram},
        }
        path = root / "controller.json"
        path.write_text(json.dumps(state))
        return path

    def test_expired_heartbeat_is_an_alertable_failure(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            path = self.state(root, alert_state={"nodes": {"edge-a": {"healthy": True, "quota": False}}})
            state = json.loads(path.read_text())
            state["nodes"] = {"edge-a": {"healthy": True, "status": "正常", "last_seen": 100,
                                          "quota_bytes": 0, "used_bytes": 0}}
            path.write_text(json.dumps(state))
            with patch.dict(ns, {"now": lambda: 1000, "HEARTBEAT_TTL": 90}):
                alerts = ns["telegram_alerts"](path)
            self.assertTrue(any("节点异常" in item for item in alerts))

    def test_outbox_ack_is_per_chat_and_concurrent_append_survives(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            path = self.state(root, pending_alerts=[{"id": "event-1", "message": "故障", "created_at": 1}])
            sent = []
            def send(token, chat_id, text):
                sent.append(chat_id)
                if chat_id == "222":
                    raise RuntimeError("temporary")
                state = json.loads(path.read_text())
                state["telegram"].setdefault("pending_alerts", []).append(
                    {"id": "event-2", "message": "并发事件", "created_at": 2})
                path.write_text(json.dumps(state))
            with patch.dict(ns, {"telegram_token": lambda config: "fixture-token",
                                 "telegram_send": send, "now": lambda: 100}):
                ns["telegram_deliver_alerts"](path, "stale-token", {"111", "222"})
            pending = json.loads(path.read_text())["telegram"]["pending_alerts"]
            first = next(item for item in pending if item.get("id") == "event-1")
            self.assertEqual(first.get("delivered_chat_ids"), ["111"])
            self.assertTrue(any(item.get("id") == "event-2" for item in pending))
            self.assertEqual(sent, ["111", "222"])

    def test_disabled_during_delivery_does_not_send_to_revoked_chat(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            path = self.state(root, pending_alerts=[{"id": "event-1", "message": "告警", "created_at": 1}])
            sent = []
            def send(token, chat_id, text):
                sent.append(chat_id)
                state = json.loads(path.read_text())
                state["telegram"]["enabled"] = False
                state["telegram"]["chat_ids"] = []
                path.write_text(json.dumps(state))
            with patch.dict(ns, {"telegram_token": lambda config: "fixture-token", "telegram_send": send, "now": lambda: 100}):
                ns["telegram_deliver_alerts"](path, "stale-token", {"111", "222"})
            self.assertEqual(sent, ["111"])

    def test_offset_is_bound_to_bot_identity(self):
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "telegram.offset"
            write = ns["telegram_write_offset"]
            read = ns["telegram_read_offset"]
            write(path, "111111:fixture-token", 42)
            self.assertEqual(read(path, "111111:fixture-token"), 42)
            self.assertEqual(read(path, "222222:other-token"), 0)

    def test_http_429_exposes_only_bounded_retry_hint(self):
        class Opener:
            def open(self, request, timeout=0):
                raise urllib.error.HTTPError(request.full_url, 429, "busy", {},
                                             __import__("io").BytesIO(b'{"ok":false,"error_code":429,"parameters":{"retry_after":7}}'))
        with patch.dict(ns, {"urllib": ns["urllib"]}):
            with patch.object(ns["urllib"].request, "build_opener", return_value=Opener()):
                with self.assertRaises(ns["TelegramAPIError"]) as context:
                    ns["telegram_api"]("123456:fixture-token", "getMe", {})
        self.assertEqual(context.exception.retry_after, 7)
        self.assertNotIn("fixture-token", str(context.exception))

    def test_poll_lock_is_released_when_startup_fails(self):
        with tempfile.TemporaryDirectory() as raw:
            path = self.state(Path(raw), enabled=False)
            args = type("Args", (), {"state": str(path)})()
            with self.assertRaises(RuntimeError):
                ns["telegram_serve"](args)
            # A second startup reaches the same validation rather than being
            # rejected as a stale duplicate process.
            with self.assertRaisesRegex(RuntimeError, "尚未启用"):
                ns["telegram_serve"](args)

    def test_stale_metrics_are_not_counted_as_recent_traffic(self):
        state = {"nodes": {"edge-a": {"used_bytes": 900,
            "metrics": {"generated_at": 1, "window_seconds": 300, "bytes": 500,
                         "requests": 8, "paths": [{"name": "/old", "bytes": 500, "requests": 8}]}}}}
        with patch.dict(ns, {"now": lambda: 5000}):
            rendered = ns["telegram_render"](state, "/traffic", "/tmp/controller.json")
        self.assertIn("最近 0 B", rendered)
        self.assertNotIn("/old", rendered)

    def test_stale_client_and_device_snapshots_are_not_presented_as_recent(self):
        state = {"nodes": {"edge-a": {"name": "A",
            "metrics": {"generated_at": 1, "window_seconds": 300,
                         "clients": [{"name": "192.0.2.9", "requests": 2}],
                         "devices": [{"name": "Android", "requests": 3}]}}}}
        with patch.dict(ns, {"now": lambda: 5000}):
            for command in ("/access", "/devices"):
                rendered = ns["telegram_render"](state, command, "/tmp/controller.json")
                self.assertIn("暂无访问摘要", rendered)
                self.assertNotIn("192.0.2.9", rendered)
                self.assertNotIn("Android", rendered)

    def test_malformed_node_counters_do_not_crash_query(self):
        state = {"nodes": {"edge-a": {"name": "A", "priority": "bad",
            "quota_bytes": "bad", "used_bytes": "bad", "last_seen": "bad",
            "healthy": True}}}
        rendered = ns["telegram_render"](state, "/nodes", "/tmp/controller.json")
        self.assertIn("A [edge-a]", rendered)
        self.assertIn("不限额", rendered)

    def test_failed_test_message_does_not_publish_new_bot(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            old_token = root / "old.token"
            old_token.write_text("111111:old-token-value-abcdefghijklmnopqrstuvwxyz")
            old_token.chmod(0o600)
            incoming = root / "incoming.token"
            incoming.write_text("222222:ABCDEFGHIJKLMNOPQRSTUVWXYZ_123456")
            state_path = root / "controller.json"
            state_path.write_text(json.dumps({"telegram": {"enabled": True, "token_file": str(old_token),
                "chat_ids": ["111"], "alert_state": {"old": True}}, "nodes": {}}))
            args = type("Args", (), {"state": str(state_path), "token_file": str(incoming),
                                      "chat_ids": "222", "persist_token": "", "test": True})()
            with patch.dict(ns, {"telegram_api": lambda *a, **k: {"id": 1},
                                 "telegram_send": lambda *a, **k: (_ for _ in ()).throw(RuntimeError("offline"))}):
                with self.assertRaisesRegex(RuntimeError, "offline"):
                    ns["telegram_configure"](args)
            saved = json.loads(state_path.read_text())
            self.assertEqual(saved["telegram"]["chat_ids"], ["111"])
            self.assertEqual(old_token.read_text(), "111111:old-token-value-abcdefghijklmnopqrstuvwxyz")


if __name__ == "__main__":
    unittest.main()
