#!/usr/bin/env python3
"""Offline regressions for polling Bot identity, live authorization and cursors."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "emby-proxy").read_text()
source = source.split("controller_cli() {", 1)[1].split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
ns = {"__name__": "telegram_poll_under_test"}
exec(compile(source, "emby-proxy:telegram-poll", "exec"), ns)


class StopPolling(BaseException):
    pass


class TelegramPollTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "controller.json"
        self.args = type("Args", (), {"state": str(self.path)})()
        self.state = {"telegram": {"enabled": True, "chat_ids": ["111"], "fixture_token": "old-bot"},
                      "entry_id": "domain-test.example.com", "nodes": {}}
        self.save()
        self.sent = []
        self.calls = []
        self.polls = 0

    def save(self):
        self.path.write_text(json.dumps(self.state))

    def update(self, ident=1, text="/status", chat="111"):
        return {"update_id": ident, "message": {"chat": {"id": chat}, "text": text}}

    def run_poll(self, poll, render=None, webhook=None):
        def api(token, method, payload, timeout=0):
            self.calls.append((token, method, payload))
            if method == "getMe":
                return {"username": "OldBot" if token == "old-bot" else "NewBot"}
            if method == "getWebhookInfo":
                return {"url": webhook(token) if webhook else ""}
            if method == "getUpdates":
                self.polls += 1
                if self.polls > 4:
                    raise StopPolling()
                return poll(token, self.polls)
            raise AssertionError(method)
        class Controller:
            def __init__(self, path): pass
            def private_status(inner): return self.state.copy()
        with patch.dict(ns, {"telegram_api": api,
                             "telegram_token": lambda config: config["fixture_token"],
                             "telegram_send": lambda token, chat, text, **kwargs: self.sent.append((token, chat, text))
                             if not kwargs.get("authorize") or kwargs["authorize"](token, chat) else False,
                             "telegram_render": render or (lambda *args: "private state"),
                             "Controller": Controller,
                             "telegram_alerts": lambda *args: [],
                             "telegram_deliver_alerts": lambda *args: None}):
            try:
                ns["telegram_serve"](self.args)
            except StopPolling:
                pass

    def test_rotation_during_poll_discards_old_batch_and_cursor(self):
        def poll(token, count):
            if count == 1:
                self.state["telegram"]["fixture_token"] = "new-bot"
                self.save()
                return [self.update(900)]
            raise StopPolling()
        self.run_poll(poll)
        self.assertEqual(self.sent, [])
        self.assertEqual(ns["telegram_read_offset"](self.path.with_name("telegram.offset"), "new-bot"), 0)
        new_poll = next(payload for token, method, payload in self.calls if token == "new-bot" and method == "getUpdates")
        self.assertEqual(new_poll["offset"], 0)

    def test_rotation_reloads_bot_identity_and_accepts_new_bot_mention(self):
        def poll(token, count):
            if count == 1:
                self.state["telegram"]["fixture_token"] = "new-bot"
                self.save()
                return []
            if count == 2:
                return [self.update(3, "/status@NewBot")]
            raise StopPolling()
        self.run_poll(poll)
        self.assertEqual(self.sent, [("new-bot", "111", "private state")])
        self.assertIn(("new-bot", "getMe", {}), self.calls)
        self.assertIn(("new-bot", "getWebhookInfo", {}), self.calls)

    def test_rotation_checks_webhook_before_polling_new_bot(self):
        def poll(token, count):
            if count == 1:
                self.state["telegram"]["fixture_token"] = "new-bot"
                self.save()
                return []
            raise StopPolling()
        with self.assertRaisesRegex(RuntimeError, "webhook"):
            self.run_poll(poll, webhook=lambda token: "https://bot.example.com/hook" if token == "new-bot" else "")
        self.assertFalse(any(token == "new-bot" and method == "getUpdates" for token, method, _ in self.calls))

    def test_acl_revoked_while_rendering_does_not_send(self):
        def poll(token, count):
            if count == 1: return [self.update()]
            raise StopPolling()
        def render(*args):
            self.state["telegram"]["chat_ids"] = ["222"]
            self.save()
            return "sensitive state"
        self.run_poll(poll, render=render)
        self.assertEqual(self.sent, [])

    def test_token_rotated_while_rendering_does_not_send_or_ack_new_bot(self):
        def poll(token, count):
            if count == 1: return [self.update(700)]
            raise StopPolling()
        def render(*args):
            self.state["telegram"]["fixture_token"] = "new-bot"
            self.save()
            return "sensitive state"
        self.run_poll(poll, render=render)
        self.assertEqual(self.sent, [])
        self.assertEqual(ns["telegram_read_offset"](self.path.with_name("telegram.offset"), "new-bot"), 0)

    def test_disable_while_rendering_does_not_send_error_reply(self):
        def poll(token, count):
            if count == 1: return [self.update()]
            raise StopPolling()
        def render(*args):
            self.state["telegram"]["enabled"] = False
            self.save()
            raise RuntimeError("fixture failure")
        self.run_poll(poll, render=render)
        self.assertEqual(self.sent, [])

    def test_non_list_update_result_is_ignored(self):
        def poll(token, count):
            if count == 1: return 42
            raise StopPolling()
        self.run_poll(poll)
        self.assertEqual(self.sent, [])

    def test_malformed_updates_do_not_send_or_advance_cursor(self):
        def poll(token, count):
            if count == 1:
                return [None, [], "message", 12, self.update(True), self.update(-4),
                        self.update(1.9), self.update("88"), self.update(2**100)]
            raise StopPolling()
        self.run_poll(poll)
        self.assertEqual(self.sent, [])
        self.assertEqual(ns["telegram_read_offset"](self.path.with_name("telegram.offset"), "old-bot"), 0)

    def test_unauthorized_valid_update_is_acknowledged(self):
        def poll(token, count):
            if count == 1: return [self.update(4, chat="222"), {"update_id": 5, "message": []}]
            raise StopPolling()
        self.run_poll(poll)
        self.assertEqual(self.sent, [])
        self.assertEqual(ns["telegram_read_offset"](self.path.with_name("telegram.offset"), "old-bot"), 6)

    def test_offset_requires_bounded_integer(self):
        path = self.path.with_name("telegram.offset")
        for offset in (True, -1, 1.9, "12", 2**100):
            with self.subTest(offset=offset):
                path.write_text(json.dumps({"token_fingerprint": ns["telegram_token_fingerprint"]("old-bot"), "offset": offset}))
                self.assertEqual(ns["telegram_read_offset"](path, "old-bot"), 0)


if __name__ == "__main__":
    unittest.main()
