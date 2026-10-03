#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
MANAGER="$ROOT_DIR/emby-proxy"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# The menu installer must restart an already running bot and must preserve a
# non-managed same-name unit. Use a fake systemctl and a temp unit path so
# this remains offline and never touches the host service manager.
STATE_DIR="$TMP_DIR/state dir"
UNIT="$TMP_DIR/system dir/emby-proxy-telegram.service"
mkdir -p "$STATE_DIR" "$(dirname "$UNIT")"
STATE="$STATE_DIR/controller.json"
cat >"$STATE" <<'JSON'
{"schema_version":1,"entry_id":"domain-test.example.com","telegram":{"enabled":true,"token_file":"/tmp/token","chat_ids":["123456789"]}}
JSON
TRACE="$TMP_DIR/systemctl.trace"
EMBY_PROXY_TELEGRAM_UNIT="$UNIT" EMBY_PROXY_STATE_HOME="$STATE_DIR" \
EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" STATE="$STATE" TRACE="$TRACE" \
bash -c '
  set --; source "$MANAGER_UNDER_TEST"
  controller_require_state() { printf "%s" "$STATE"; }
  systemctl() {
    printf "%s\n" "$*" >>"$TRACE"
    if [[ "$1" == is-active ]]; then
      grep -Fx "restart" "$TRACE" >/dev/null 2>&1
    else
      return 0
    fi
  }
  controller_telegram_install
' >/dev/null 2>"$TMP_DIR/install.err" || fail "Telegram 托管 unit 安装失败"

grep -Fx 'restart' "$TRACE" >/dev/null || fail "运行中的 Telegram 服务没有 restart"
grep -F 'daemon-reload' "$TRACE" >/dev/null || fail "Telegram unit 更新没有 daemon-reload"
grep -Fx 'enable' "$TRACE" >/dev/null || fail "Telegram unit 没有 enable"
grep -F -- '--state="' "$UNIT" >/dev/null || fail "Telegram ExecStart 没有引用状态路径"
grep -F 'ReadWritePaths="' "$UNIT" >/dev/null || fail "Telegram ReadWritePaths 没有引用带空格的目录"
grep -Fx '# MANAGED EMBY TELEGRAM BOT' "$UNIT" >/dev/null || fail "Telegram unit 缺少托管标记"

# A pre-existing non-managed unit is never overwritten.
printf '%s\n' '# THIRD PARTY UNIT' >"$UNIT"
if EMBY_PROXY_TELEGRAM_UNIT="$UNIT" EMBY_PROXY_STATE_HOME="$STATE_DIR" \
   EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" STATE="$STATE" \
   bash -c 'set --; source "$MANAGER_UNDER_TEST"; controller_require_state() { printf "%s" "$STATE"; }; controller_telegram_install' \
   >/dev/null 2>"$TMP_DIR/conflict.err"; then
  fail "非托管 Telegram unit 被允许覆盖"
fi
grep -F '不是 emby-proxy 托管文件' "$TMP_DIR/conflict.err" >/dev/null || fail "非托管 unit 冲突没有给出修复提示"
grep -Fx '# THIRD PARTY UNIT' "$UNIT" >/dev/null || fail "非托管 Telegram unit 内容被修改"

printf 'PASS: Telegram menu restart, path quoting and managed-unit guard\n'
