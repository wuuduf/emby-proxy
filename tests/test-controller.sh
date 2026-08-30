#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ROOT_DIR="$ROOT_DIR" TMP_DIR="$TMP_DIR" python3 - <<'PY'
import importlib.util
import json
import os
import subprocess
from pathlib import Path

root = Path(os.environ["ROOT_DIR"])
tmp = Path(os.environ["TMP_DIR"])
spec = importlib.util.spec_from_file_location("controller", root / "emby-proxy-controller.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

state_path = tmp / "controller.json"
state_path.write_text(json.dumps({
    "schema_version": 1,
    "entry_id": "domain-test.example.com",
    "domain": "test.example.com",
    "source": "https://origin.example.com",
    "engine": "caddy",
    "active_node": None,
    "enroll_tokens": {"fast": "one-time"},
    "nodes": {},
}))
controller = module.Controller(state_path)
code, enrolled = controller.enroll({
    "entry_id": "domain-test.example.com", "node_id": "fast", "name": "fast",
    "priority": 100, "quota_bytes": 1000, "public_ip": "192.0.2.10",
    "enroll_token": "one-time",
})
assert code == 200
assert controller.enroll({"entry_id": "domain-test.example.com", "node_id": "fast", "enroll_token": "one-time"})[0] == 403
code, heartbeat = controller.heartbeat({
    "node_id": "fast", "healthy": True, "used_bytes": 0,
    "public_ip": "192.0.2.10",
}, enrolled["node_token"])
assert code == 200 and heartbeat["selected_node"] == "fast"
assert controller.status()["nodes"]["fast"]["public_ip"] == "192.0.2.10"

issue = subprocess.check_output([
    "python3", str(root / "emby-proxy-controller.py"), "issue",
    "--state", str(state_path), "--controller-url", "https://control.example.com:19090",
    "--node-id", "backup", "--name", "backup", "--priority", "10",
    "--quota-bytes", "0", "--public-ip", "192.0.2.11",
], text=True)
assert "--public-ip 192.0.2.11" in issue
assert "/edge-bootstrap.sh" in issue
print("PASS: controller enrollment, single-use token, public IP and issue command")
PY
