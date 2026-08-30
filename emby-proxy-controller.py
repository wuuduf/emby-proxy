#!/usr/bin/env python3
"""emby-proxy 多线路控制器（实验版）。

控制器只处理注册、心跳、优先级/配额选择和 Cloudflare DNS；不转发视频流量。
生产部署应把它放在 HTTPS 或 WireGuard 后面。本文件不依赖第三方 Python 包。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import secrets
import shlex
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


def now() -> int:
    return int(time.time())


def sha256(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


class Controller:
    def __init__(self, state_path: Path):
        self.state_path = state_path
        self.lock = threading.RLock()
        self.state = self._load()

    def _load(self) -> dict:
        data = json.loads(self.state_path.read_text())
        data.setdefault("schema_version", 1)
        data.setdefault("enroll_tokens", {})
        data.setdefault("nodes", {})
        data.setdefault("active_node", None)
        return data

    def save(self) -> None:
        tmp = self.state_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.state, indent=2, sort_keys=True))
        tmp.replace(self.state_path)

    def enroll(self, body: dict) -> tuple[int, dict]:
        with self.lock:
            if body.get("entry_id") != self.state["entry_id"]:
                return 404, {"error": "unknown_entry"}
            node_id = str(body.get("node_id", ""))
            token = str(body.get("enroll_token", ""))
            if not node_id or self.state["enroll_tokens"].get(node_id) != token:
                return 403, {"error": "invalid_or_expired_enroll_token"}
            node_token = secrets.token_urlsafe(32)
            self.state["enroll_tokens"].pop(node_id, None)
            self.state["nodes"][node_id] = {
                "name": body.get("name", node_id),
                "priority": int(body.get("priority", 0)),
                "quota_bytes": int(body.get("quota_bytes", 0)),
                "used_bytes": 0,
                "healthy": False,
                "status": "enrolled",
                "last_seen": now(),
                "version": body.get("version", "unknown"),
                "token_hash": sha256(node_token),
            }
            if body.get("public_ip"):
                self.state["nodes"][node_id]["public_ip"] = str(body["public_ip"])
            self.save()
            return 200, {
                "node_token": node_token,
                "entry_id": self.state["entry_id"],
                "domain": self.state["domain"],
                "source": self.state["source"],
                "engine": self.state.get("engine", "caddy"),
            }

    def heartbeat(self, body: dict, token: str) -> tuple[int, dict]:
        with self.lock:
            node_id = str(body.get("node_id", ""))
            node = self.state["nodes"].get(node_id)
            if not node or node.get("token_hash") != sha256(token):
                return 403, {"error": "invalid_node_token"}
            used = max(int(node.get("used_bytes", 0)), int(body.get("used_bytes", 0)))
            node.update(
                healthy=bool(body.get("healthy", False)),
                used_bytes=used,
                status="healthy" if body.get("healthy") else "unhealthy",
                last_seen=now(),
                version=body.get("version", node.get("version", "unknown")),
                last_event=body.get("event", "heartbeat"),
                public_ip=body.get("public_ip", node.get("public_ip")),
            )
            selected = self.select_node()
            self.save()
            return 200, {"selected_node": selected, "accepted_used_bytes": used}

    def select_node(self) -> str | None:
        candidates = []
        for node_id, node in self.state["nodes"].items():
            quota = int(node.get("quota_bytes", 0))
            within_quota = quota <= 0 or int(node.get("used_bytes", 0)) < quota
            online = now() - int(node.get("last_seen", 0)) <= 90
            if node.get("healthy") and within_quota and online:
                candidates.append((int(node.get("priority", 0)), node_id))
        return max(candidates, default=(0, None))[1]

    def reconcile(self) -> dict:
        with self.lock:
            selected = self.select_node()
            previous = self.state.get("active_node")
            changed = selected != previous
            dns_result = None
            if selected and changed:
                dns_result = self._update_dns(selected)
            # Cloudflare 更新失败时不要确认切换，否则下一轮会认为已经完成，
            # 从而永远不再重试；成功或未配置 DNS 才提交 active_node。
            if not (isinstance(dns_result, dict) and dns_result.get("ok") is False):
                self.state["active_node"] = selected
            self.state["last_reconcile"] = now()
            self.state["last_dns_result"] = dns_result
            self.save()
            return {"selected_node": selected, "active_node": self.state.get("active_node"),
                    "previous_node": previous, "changed": changed, "dns": dns_result}

    def _update_dns(self, node_id: str) -> dict:
        dns = self.state.get("dns") or {}
        if dns.get("provider") != "cloudflare":
            return {"skipped": "dns provider not configured"}
        node = self.state["nodes"][node_id]
        if not node.get("public_ip"):
            return {"ok": False, "error": "selected node has no public_ip"}
        token_file = Path(dns["token_file"])
        token = token_file.read_text().strip()
        payload = {
            "type": "A", "name": self.state["domain"],
            "content": node["public_ip"], "ttl": int(dns.get("ttl", 60)),
            "proxied": False,
        }
        request = urllib.request.Request(
            f"https://api.cloudflare.com/client/v4/zones/{dns['zone_id']}/dns_records/{dns['record_id']}",
            data=json.dumps(payload).encode(),
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
            method="PUT",
        )
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                result = json.loads(response.read())
            if not result.get("success"):
                return {"ok": False, "errors": result.get("errors", [])}
            return {"ok": True, "content": node["public_ip"]}
        except (OSError, urllib.error.URLError) as exc:
            return {"ok": False, "error": str(exc)}

    def status(self) -> dict:
        with self.lock:
            result = dict(self.state)
            result.pop("enroll_tokens", None)
            for node in result.get("nodes", {}).values():
                node.pop("token_hash", None)
            result["selected_node"] = self.select_node()
            return result


class Handler(BaseHTTPRequestHandler):
    server: "ControllerServer"

    def log_message(self, fmt: str, *args) -> None:
        print("[controller] " + (fmt % args), flush=True)

    def json_response(self, status: int, body: dict) -> None:
        raw = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def body(self) -> dict:
        size = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(size) or b"{}")

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/status":
            self.json_response(200, self.server.controller.status())
        elif path in ("/edge-bootstrap.sh", "/edge-agent.sh"):
            source = self.server.edge_bootstrap if path.endswith("bootstrap.sh") else self.server.edge_agent
            try:
                raw = Path(source).read_bytes()
            except OSError as exc:
                self.json_response(503, {"error": str(exc)})
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers(); self.wfile.write(raw)
        else:
            self.json_response(404, {"error": "not_found"})

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        try:
            body = self.body()
            if path == "/enroll":
                status, result = self.server.controller.enroll(body)
            elif path == "/heartbeat":
                auth = self.headers.get("Authorization", "")
                status, result = self.server.controller.heartbeat(body, auth.removeprefix("Bearer ").strip())
            elif path == "/reconcile":
                status, result = 200, self.server.controller.reconcile()
            else:
                status, result = 404, {"error": "not_found"}
        except (ValueError, json.JSONDecodeError, KeyError) as exc:
            status, result = 400, {"error": f"bad_request:{exc}"}
        self.json_response(status, result)


class ControllerServer(ThreadingHTTPServer):
    def __init__(self, address, controller: Controller, edge_bootstrap: str, edge_agent: str):
        super().__init__(address, Handler)
        self.controller = controller
        self.edge_bootstrap = edge_bootstrap
        self.edge_agent = edge_agent


def write_state(args: argparse.Namespace) -> None:
    state = {
        "schema_version": 1, "entry_id": args.entry_id, "domain": args.domain,
        "source": args.source, "engine": args.engine, "active_node": None,
        "enroll_tokens": {}, "nodes": {},
    }
    if args.zone_id and args.record_id and args.token_file:
        state["dns"] = {"provider": "cloudflare", "zone_id": args.zone_id, "record_id": args.record_id, "token_file": args.token_file, "ttl": 60}
    path = Path(args.state); path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp"); tmp.write_text(json.dumps(state, indent=2)); tmp.replace(path)
    print(f"已创建控制器入口：{path}")


def issue_token(args: argparse.Namespace) -> None:
    path = Path(args.state); data = json.loads(path.read_text())
    token = secrets.token_urlsafe(24)
    data.setdefault("enroll_tokens", {})[args.node_id] = token
    tmp = path.with_suffix(".tmp"); tmp.write_text(json.dumps(data, indent=2)); tmp.replace(path)
    public_ip_arg = f" --public-ip {shlex.quote(args.public_ip)}" if args.public_ip else ""
    command = (f"curl -fsSL {args.controller_url.rstrip('/')}/edge-bootstrap.sh | sudo bash -s -- "
               f"--controller {args.controller_url.rstrip('/')} --entry-id {data['entry_id']} "
               f"--node-id {args.node_id} --name {args.name} --priority {args.priority} "
               f"--quota-bytes {args.quota_bytes}{public_ip_arg} --enroll-token '{token}'")
    print(command)


def serve(args: argparse.Namespace) -> None:
    host, port = args.listen.rsplit(":", 1)
    controller = Controller(Path(args.state))
    server = ControllerServer((host, int(port)), controller, args.edge_bootstrap, args.edge_agent)
    print(f"controller listening on {args.listen}; entry={controller.state['entry_id']}", flush=True)
    stop = threading.Event()
    def loop() -> None:
        while not stop.wait(args.reconcile_interval):
            try:
                print(json.dumps(controller.reconcile(), ensure_ascii=False), flush=True)
            except Exception as exc:
                print(f"[controller] reconcile failed: {exc}", flush=True)
    thread = threading.Thread(target=loop, daemon=True); thread.start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        stop.set()


def main() -> None:
    parser = argparse.ArgumentParser(prog="emby-proxy-controller")
    sub = parser.add_subparsers(dest="command", required=True)
    init = sub.add_parser("init"); init.add_argument("--state", required=True); init.add_argument("--entry-id", required=True); init.add_argument("--domain", required=True); init.add_argument("--source", required=True); init.add_argument("--engine", default="caddy"); init.add_argument("--zone-id"); init.add_argument("--record-id"); init.add_argument("--token-file")
    issue = sub.add_parser("issue"); issue.add_argument("--state", required=True); issue.add_argument("--controller-url", required=True); issue.add_argument("--node-id", required=True); issue.add_argument("--name", required=True); issue.add_argument("--priority", type=int, required=True); issue.add_argument("--quota-bytes", type=int, default=0); issue.add_argument("--public-ip")
    run = sub.add_parser("serve"); run.add_argument("--state", required=True); run.add_argument("--listen", default="0.0.0.0:19090"); run.add_argument("--reconcile-interval", type=int, default=30); run.add_argument("--edge-bootstrap", required=True); run.add_argument("--edge-agent", required=True)
    args = parser.parse_args()
    {"init": write_state, "issue": issue_token, "serve": serve}[args.command](args)


if __name__ == "__main__":
    main()
