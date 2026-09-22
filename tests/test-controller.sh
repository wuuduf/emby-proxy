#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
PID=""
cleanup() {
  if [[ -n "$PID" ]]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# 受限开发沙箱可能禁止回环监听；在 CI/VPS 上仍执行完整真实 HTTP 回环测试。
if python3 - <<'PY'
import socket, sys
s = socket.socket()
try:
    s.bind(('127.0.0.1', 0))
except PermissionError:
    sys.exit(77)
finally:
    s.close()
PY
then
  :
else
  status=$?
  [[ "$status" == 77 ]] || exit "$status"
  printf 'SKIP: 当前沙箱禁止回环监听，跳过真实控制器 HTTP 测试\n'
  exit 0
fi

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
# 直接持有 Python 服务 PID，避免 kill 外层 shell 后遗留监听进程。
# 端口 0 由操作系统分配；等 /status 就绪，不能用固定 sleep 假定服务已启动。
python3 - "$ROOT_DIR/emby-proxy" "$STATE" "$TMP_DIR/port" <<'PY' >"$TMP_DIR/serve.log" 2>&1 &
from pathlib import Path
import sys
from types import SimpleNamespace
source = Path(sys.argv[1]).read_text().split("controller_cli() {", 1)[1]
source = source.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
ns = {"__name__": "controller_under_test"}
exec(compile(source, "emby-proxy:controller", "exec"), ns)
class ReadyServer(ns['Server']):
    def __init__(self, address, controller):
        super().__init__(address, controller)
        Path(sys.argv[3]).write_text(str(self.server_address[1]))
ns['Server'] = ReadyServer
ns['serve'](SimpleNamespace(state=sys.argv[2], listen='127.0.0.1:0', reconcile_interval=1))
PY
PID=$!
ready=0
for _ in $(seq 1 100); do
  kill -0 "$PID" 2>/dev/null || { cat "$TMP_DIR/serve.log" >&2; fail "主控服务未启动"; }
  if [[ -s "$TMP_DIR/port" ]]; then
    PORT="$(cat "$TMP_DIR/port")"
    if curl --noproxy '*' -fsS --max-time 1 "http://127.0.0.1:$PORT/status" >"$TMP_DIR/status.json"; then
      ready=1; break
    fi
  fi
  sleep 0.05
done
[[ "$ready" == 1 ]] || fail "等待主控就绪超时"
grep -F 'domain-test.example.com' "$TMP_DIR/status.json" >/dev/null || fail "主控状态错误"
for i in $(seq 1 8); do
  output="$(run_cli issue \
    --state "$STATE" --controller-url "http://127.0.0.1:$PORT" \
    --node-id "edge-$i" --name "edge-$i" --priority "$i" \
    --quota-bytes 0 --public-ip "192.0.2.$i")"
  if [[ "$i" == 1 ]]; then
    grep -F 'command -v ep' <<<"$output" >/dev/null || fail "生成命令没有包含全新边缘机自引导安装"
  fi
done
python3 - "$STATE" <<'PY' || exit 1
import json, sys, time
# 等待发码后的下一轮 reconcile，证明服务确实持续写状态，而非只启动成功。
last = json.load(open(sys.argv[1])).get('last_reconcile', 0)
for _ in range(50):
    d = json.load(open(sys.argv[1]))
    if d.get('last_reconcile', 0) > last:
        break
    time.sleep(0.1)
else:
    raise AssertionError('controller did not reconcile after issuing tokens')
tokens = d.get('enroll_tokens', {})
assert len(tokens) == 8, f'expected 8 enrollment tokens, got {len(tokens)}'
assert set(tokens) == {f'edge-{i}' for i in range(1, 9)}, tokens
PY

# CLI 也允许省略 --node-id，按公网 IPv4 生成可读且唯一的节点 ID。
AUTO_STATE="$TMP_DIR/auto-issue.json"
run_cli init --state "$AUTO_STATE" --domain auto.example.com --source https://origin.example.com --engine caddy >/dev/null
auto_output="$(run_cli issue --state "$AUTO_STATE" --controller-url http://127.0.0.1:19090 --name auto --priority 1 --quota-bytes 0 --public-ip 192.0.2.99)"
grep -F -- '--node-id edge-192-0-2-99' <<<"$auto_output" >/dev/null || fail "CLI 省略 node-id 时未自动生成"

kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
PID=""
printf 'PASS: controller state locking preserves concurrent enrollment tokens\n'
