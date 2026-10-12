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
    --state "$STATE" --controller-url "https://control.example.com" \
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
auto_output="$(run_cli issue --state "$AUTO_STATE" --controller-url https://control.example.com --name auto --priority 1 --quota-bytes 0 --public-ip 192.0.2.99)"
grep -F -- '--ticket' <<<"$auto_output" >/dev/null || fail "CLI 未生成票据安装命令"
python3 - "$AUTO_STATE" <<'PY'
import json,sys
assert 'edge-192-0-2-99' in json.load(open(sys.argv[1]))['enroll_tokens']
PY

# Exercise the actual CLI parser, not just Python function calls: private list,
# same-command lookup, explicit rotation/revoke and invalid cleanup.
run_cli tickets --state "$AUTO_STATE" >"$TMP_DIR/tickets.json"
run_cli ticket-show --state "$AUTO_STATE" --node-id edge-192-0-2-99 >"$TMP_DIR/show.txt"
python3 - "$AUTO_STATE" "$TMP_DIR/tickets.json" "$TMP_DIR/show.txt" <<'PY'
import json,sys
state=json.load(open(sys.argv[1])); token=state['enroll_tokens']['edge-192-0-2-99']['token']
tasks=json.load(open(sys.argv[2])); assert tasks['edge-192-0-2-99']['status']=='pending'
assert token not in json.dumps(tasks)
assert token in open(sys.argv[3]).read()
PY
cp "$AUTO_STATE" "$TMP_DIR/before-reissue.json"
run_cli ticket-reissue --state "$AUTO_STATE" --node-id edge-192-0-2-99 >"$TMP_DIR/reissue.txt"
python3 - "$AUTO_STATE" "$TMP_DIR/before-reissue.json" <<'PY'
import json,sys
new=json.load(open(sys.argv[1]))['enroll_tokens']['edge-192-0-2-99']
old=json.load(open(sys.argv[2]))['enroll_tokens']['edge-192-0-2-99']
assert new['token']!=old['token'] and new['generation']==2
PY
run_cli ticket-revoke --state "$AUTO_STATE" --node-id edge-192-0-2-99 >/dev/null
if run_cli ticket-show --state "$AUTO_STATE" --node-id edge-192-0-2-99 >"$TMP_DIR/revoked.log" 2>&1; then
  fail "撤销的票据仍可显示"
fi
if run_cli registration-cleanup --state "$AUTO_STATE" --node-id nonexistent >"$TMP_DIR/cleanup.log" 2>&1; then
  fail "允许清理非失败注册"
fi
! grep -F 'Traceback' "$TMP_DIR/cleanup.log" >/dev/null || fail "失败 CLI 泄露 traceback"
for command in node-install node-cleanup tickets ticket-show ticket-revoke ticket-reissue registration-cleanup; do
  run_cli "$command" --help >/dev/null || fail "注册命令帮助不可用：$command"
done

kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
PID=""
printf 'PASS: controller state locking preserves concurrent enrollment tokens\n'
