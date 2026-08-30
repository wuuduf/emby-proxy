#!/usr/bin/env python3
"""Local-only prototype of the multi-line controller.

This file intentionally has no Caddy/Nginx/DNS side effects.  It validates the
control-plane protocol before it is integrated into ep.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


def now() -> int:
    return int(time.time())


class Controller:
    def __init__(self, entry_id: str, source: str, tokens: dict[str, str], state_path: Path | None):
        self.entry_id = entry_id
        self.source = source
        self.tokens = tokens
        self.state_path = state_path
        self.lock = threading.Lock()
        self.nodes: dict[str, dict] = {}
        self._load()

    def _load(self) -> None:
        if not self.state_path or not self.state_path.exists():
            return
        data = json.loads(self.state_path.read_text())
        self.nodes = data.get("nodes", {})

    def _save(self) -> None:
        if not self.state_path:
            return
        payload = {"entry_id": self.entry_id, "source": self.source, "nodes": self.nodes}
        tmp = self.state_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, indent=2, sort_keys=True))
        tmp.replace(self.state_path)

    @staticmethod
    def _hash(token: str) -> str:
        return hashlib.sha256(token.encode()).hexdigest()

    def enroll(self, body: dict) -> tuple[int, dict]:
        if body.get("entry_id") != self.entry_id:
            return 404, {"error": "unknown_entry"}
        node_id = str(body.get("node_id", ""))
        enroll_token = str(body.get("enroll_token", ""))
        if not node_id or self.tokens.get(node_id) != enroll_token:
            return 403, {"error": "invalid_or_expired_enroll_token"}
        node_token = secrets.token_urlsafe(32)
        with self.lock:
            self.nodes[node_id] = {
                "name": body.get("name", node_id),
                "priority": int(body.get("priority", 0)),
                "quota_bytes": int(body.get("quota_bytes", 0)),
                "used_bytes": 0,
                "healthy": False,
                "status": "enrolled",
                "last_seen": now(),
                "version": body.get("version", "unknown"),
                "token_hash": self._hash(node_token),
            }
            # One-time enrollment token: a second registration attempt fails.
            self.tokens.pop(node_id, None)
            self._save()
        return 200, {"node_token": node_token, "entry_id": self.entry_id}

    def heartbeat(self, body: dict, token: str) -> tuple[int, dict]:
        node_id = str(body.get("node_id", ""))
        with self.lock:
            node = self.nodes.get(node_id)
            if not node or node.get("token_hash") != self._hash(token):
                return 403, {"error": "invalid_node_token"}
            used = max(int(node.get("used_bytes", 0)), int(body.get("used_bytes", 0)))
            node.update(
                healthy=bool(body.get("healthy", False)),
                used_bytes=used,
                status="healthy" if body.get("healthy") else "unhealthy",
                last_seen=now(),
                version=body.get("version", node.get("version", "unknown")),
                last_event=body.get("event", "heartbeat"),
            )
            self._save()
            return 200, {"selected_node": self.selected_node(), "accepted_used_bytes": used}

    def selected_node(self) -> str | None:
        candidates = []
        for node_id, node in self.nodes.items():
            quota = int(node.get("quota_bytes", 0))
            quota_ok = quota <= 0 or int(node.get("used_bytes", 0)) < quota
            online = now() - int(node.get("last_seen", 0)) <= 90
            if node.get("healthy") and quota_ok and online:
                candidates.append((int(node.get("priority", 0)), node_id))
        return max(candidates, default=(0, None))[1]

    def status(self) -> dict:
        with self.lock:
            return {"entry_id": self.entry_id, "source": self.source, "selected_node": self.selected_node(), "nodes": self.nodes}


class Handler(BaseHTTPRequestHandler):
    server: "Server"

    def log_message(self, fmt: str, *args) -> None:
        print("[controller] " + (fmt % args), flush=True)

    def _json(self, status: int, body: dict) -> None:
        raw = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(length) or b"{}")

    def do_GET(self) -> None:
        if urlparse(self.path).path == "/status":
            self._json(200, self.server.controller.status())
        else:
            self._json(404, {"error": "not_found"})

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        try:
            body = self._body()
            if path == "/enroll":
                status, result = self.server.controller.enroll(body)
            elif path == "/heartbeat":
                auth = self.headers.get("Authorization", "")
                token = auth.removeprefix("Bearer ").strip()
                status, result = self.server.controller.heartbeat(body, token)
            else:
                status, result = 404, {"error": "not_found"}
        except (ValueError, json.JSONDecodeError) as exc:
            status, result = 400, {"error": f"bad_request:{exc}"}
        self._json(status, result)


class Server(ThreadingHTTPServer):
    def __init__(self, address, controller: Controller):
        super().__init__(address, Handler)
        self.controller = controller


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default="127.0.0.1:19090")
    parser.add_argument("--entry-id", default="lab-entry")
    parser.add_argument("--source", default="https://origin.invalid")
    parser.add_argument("--token", action="append", default=[], metavar="NODE=TOKEN")
    parser.add_argument("--state", type=Path)
    args = parser.parse_args()
    host, port = args.listen.rsplit(":", 1)
    tokens = dict(item.split("=", 1) for item in args.token)
    server = Server((host, int(port)), Controller(args.entry_id, args.source, tokens, args.state))
    print(f"controller listening on {args.listen}; entry={args.entry_id}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
