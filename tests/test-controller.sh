#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
PORT=$((19090 + (RANDOM % 500)))
PID=""
trap '[[ -z "$PID" ]] || kill "$PID" 2>/dev/null || true; rm -rf "$TMP_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

run_cli() {
  EMBY_PROXY_MANAGER_LIB_ONLY=1 SCRIPT_UNDER_TEST="$ROOT_DIR/emby-proxy" \
    bash -c 'source "$SCRIPT_UNDER_TEST"; controller_cli "$@"' bash "$@"
}

STATE="$TMP_DIR/controller.json"
run_cli init \
  --state "$STATE" \
  --entry-id domain-test.example.com \
  --domain test.example.com \
  --source https://origin.example.com \
  --engine caddy >/dev/null

# 主控服务会周期性写回状态；issue 必须和它共享文件锁，否则新注册码会被旧内存状态覆盖。
run_cli serve --state "$STATE" --listen "127.0.0.1:$PORT" --reconcile-interval 1 \
  >"$TMP_DIR/serve.log" 2>&1 &
PID=$!
sleep 0.2
for i in $(seq 1 8); do
  run_cli issue \
    --state "$STATE" --controller-url "http://127.0.0.1:$PORT" \
    --node-id "edge-$i" --name "edge-$i" --priority "$i" \
    --quota-bytes 0 --public-ip "192.0.2.$i" >/dev/null
done
python3 - "$STATE" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
tokens = d.get('enroll_tokens', {})
assert len(tokens) == 8, f'expected 8 enrollment tokens, got {len(tokens)}'
assert set(tokens) == {f'edge-{i}' for i in range(1, 9)}, tokens
PY

kill "$PID" 2>/dev/null || true
PID=""
printf 'PASS: controller state locking preserves concurrent enrollment tokens\n'
