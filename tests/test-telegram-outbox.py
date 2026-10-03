#!/usr/bin/env python3
"""Offline regressions for the Telegram alert outbox.

These tests intentionally exercise only the durable state merge; no Telegram
network, VPS, DNS provider, or real Bot token is used.
"""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "emby-proxy").read_text()
source = source.split("controller_cli() {", 1)[1].split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
ns = {"__name__": "telegram_outbox_under_test"}
exec(compile(source, "emby-proxy:telegram-outbox", "exec"), ns)


class TelegramOutboxTests(unittest.TestCase):
    def state(self, root, **telegram):
        path = Path(root) / "controller.json"
        value = {"nodes": {}, "active_node": None,
                 "telegram": {"enabled": True, "configuration_id": "generation-a",
                               "chat_ids": ["111", "222"], **telegram}}
        path.write_text(json.dumps(value))
        return path

    def test_old_generation_is_not_delivered_after_reconfigure(self):
        with tempfile.TemporaryDirectory() as raw:
            path = self.state(raw, pending_alerts=[{"id": "old-event-1", "message": "旧配置",
                                                     "created_at": 1, "generation": "generation-old"}])
            sent = []
            with patch.dict(ns, {"telegram_token": lambda config: "111111:fixture-token-value-abcdefghijklmnopqrstuvwxyz",
                                 "telegram_send": lambda *args: sent.append(args[1]), "now": lambda: 100}):
                ns["telegram_deliver_alerts"](path, "ignored", {"111", "222"})
            self.assertEqual(sent, [])
            self.assertEqual(json.loads(path.read_text())["telegram"]["pending_alerts"], [])

    def test_disable_during_send_cannot_resurrect_pending_event(self):
        with tempfile.TemporaryDirectory() as raw:
            path = self.state(raw, pending_alerts=[{"id": "event-0001", "message": "告警",
                                                     "created_at": 1, "generation": "generation-a"}])
            sent = []
            def send(token, chat_id, text):
                sent.append(chat_id)
                value = json.loads(path.read_text())
                value["telegram"]["enabled"] = False
                value["telegram"]["chat_ids"] = []
                value["telegram"]["pending_alerts"] = []
                path.write_text(json.dumps(value))
            with patch.dict(ns, {"telegram_token": lambda config: "111111:fixture-token-value-abcdefghijklmnopqrstuvwxyz",
                                 "telegram_send": send, "now": lambda: 100}):
                ns["telegram_deliver_alerts"](path, "ignored", {"111", "222"})
            value = json.loads(path.read_text())
            self.assertFalse(value["telegram"]["enabled"])
            self.assertEqual(value["telegram"]["pending_alerts"], [])
            self.assertEqual(sent, ["111"])

    def test_malformed_and_expired_rows_are_removed(self):
        with tempfile.TemporaryDirectory() as raw:
            path = self.state(raw, chat_ids=[], pending_alerts=[None, {"message": "", "created_at": 1},
                {"id": "event-0002", "message": "过期", "created_at": 1, "generation": "generation-a"},
                {"id": "event-0003", "message": "保留", "created_at": 95, "generation": "generation-a"}])
            with patch.dict(ns, {"telegram_token": lambda config: "111111:fixture-token-value-abcdefghijklmnopqrstuvwxyz",
                                 "telegram_send": lambda *args: None,
                                 "now": lambda: 100, "TELEGRAM_ALERT_MAX_AGE": 50}):
                ns["telegram_deliver_alerts"](path, "ignored", set())
            rows = json.loads(path.read_text())["telegram"]["pending_alerts"]
            self.assertEqual([row["message"] for row in rows], ["保留"])

    def test_same_text_from_distinct_state_transitions_is_not_deduplicated(self):
        with tempfile.TemporaryDirectory() as raw:
            path = self.state(raw, configuration_id="generation-a",
                              alert_state={"active_node": "edge-a", "active_nodes": [],
                                           "selected_lines": {}, "nodes": {"edge-a": {"healthy": True, "status": "正常", "quota": False}}})
            value = json.loads(path.read_text())
            value["nodes"] = {"edge-a": {"healthy": False, "status": "故障", "last_seen": 100,
                                          "quota_bytes": 0, "used_bytes": 0}}
            path.write_text(json.dumps(value))
            with patch.dict(ns, {"telegram_token": lambda config: "111111:fixture-token-value-abcdefghijklmnopqrstuvwxyz",
                                 "now": lambda: 100}):
                first = ns["telegram_alerts"](path)
                value = json.loads(path.read_text())
                value["nodes"]["edge-a"]["healthy"] = True
                path.write_text(json.dumps(value))
                ns["telegram_alerts"](path)
                value = json.loads(path.read_text())
                value["nodes"]["edge-a"]["healthy"] = False
                path.write_text(json.dumps(value))
                second = ns["telegram_alerts"](path)
            rows = json.loads(path.read_text())["telegram"]["pending_alerts"]
            self.assertTrue(first and second)
            self.assertGreaterEqual(len(rows), 2)
            self.assertEqual(len({row["id"] for row in rows}), len(rows))

    def test_identical_messages_with_distinct_ids_are_both_retained(self):
        with tempfile.TemporaryDirectory() as raw:
            path = self.state(raw, chat_ids=[], pending_alerts=[
                {"id": "event-a", "message": "节点异常：edge-a", "created_at": 95, "generation": "generation-a"},
                {"id": "event-b", "message": "节点异常：edge-a", "created_at": 96, "generation": "generation-a"},
            ])
            with patch.dict(ns, {"telegram_token": lambda config: "111111:fixture-token-value-abcdefghijklmnopqrstuvwxyz",
                                 "now": lambda: 100}):
                ns["telegram_deliver_alerts"](path, "ignored", set())
            rows = json.loads(path.read_text())["telegram"]["pending_alerts"]
            self.assertEqual([row["id"] for row in rows], ["event-a", "event-b"])


if __name__ == "__main__":
    unittest.main()
