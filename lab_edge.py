#!/usr/bin/env python3
"""Prototype one-click edge enrollment and heartbeat agent."""
from __future__ import annotations

import argparse
import json
import time
import urllib.request
from pathlib import Path


def request(url: str, payload: dict, token: str = "") -> dict:
    data = json.dumps(payload).encode()
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=5) as response:
        return json.loads(response.read())


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--controller", required=True)
    p.add_argument("--entry-id", required=True)
    p.add_argument("--node-id", required=True)
    p.add_argument("--name", required=True)
    p.add_argument("--priority", type=int, required=True)
    p.add_argument("--quota-bytes", type=int, default=0)
    p.add_argument("--enroll-token", required=True)
    p.add_argument("--used-bytes", type=int, default=0)
    p.add_argument("--healthy", action="store_true")
    p.add_argument("--once", action="store_true")
    p.add_argument("--token-file", type=Path, default=Path("edge-token"))
    args = p.parse_args()
    base = args.controller.rstrip("/")
    if args.token_file.exists():
        node_token = args.token_file.read_text().strip()
    else:
        result = request(base + "/enroll", {
            "entry_id": args.entry_id, "node_id": args.node_id, "name": args.name,
            "priority": args.priority, "quota_bytes": args.quota_bytes,
            "version": "lab-edge-0.1", "enroll_token": args.enroll_token,
        })
        node_token = result["node_token"]
        args.token_file.write_text(node_token)
        args.token_file.chmod(0o600)
        print(f"enrolled node={args.node_id}")
    result = request(base + "/heartbeat", {
        "entry_id": args.entry_id, "node_id": args.node_id,
        "used_bytes": args.used_bytes, "healthy": args.healthy,
        "version": "lab-edge-0.1", "event": "edge_started",
    }, node_token)
    print(json.dumps({"node": args.node_id, **result}, sort_keys=True))
    if args.once:
        return
    while True:
        time.sleep(30)
        result = request(base + "/heartbeat", {
            "entry_id": args.entry_id, "node_id": args.node_id,
            "used_bytes": args.used_bytes, "healthy": args.healthy,
            "version": "lab-edge-0.1", "event": "heartbeat",
        }, node_token)
        print(json.dumps(result, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
