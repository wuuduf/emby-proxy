#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

bash -n "$ROOT_DIR/setup-emby-proxy.sh" || fail "安装后端语法检查失败"
bash -n "$ROOT_DIR/emby-proxy" || fail "管理器语法检查失败"
"$ROOT_DIR/setup-emby-proxy.sh" --help >"$TMP_DIR/setup-help"
"$ROOT_DIR/emby-proxy" --help >"$TMP_DIR/manager-help"
grep -F -- '--ip-version VERSION' "$TMP_DIR/setup-help" >/dev/null || fail "帮助缺少 --ip-version"
"$ROOT_DIR/emby-proxy" version | grep -F '2.3.0-ipv6' >/dev/null || fail "版本输出错误"

# 非 root 且没有任何 --route 时，sudo 重执行参数不能因空数组 + nounset 崩溃。
mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/sudo" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$SUDO_ARGS_OUT"
EOF
chmod +x "$TMP_DIR/bin/sudo"
SUDO_ARGS_OUT="$TMP_DIR/sudo.args" PATH="$TMP_DIR/bin:$PATH" \
  "$ROOT_DIR/setup-emby-proxy.sh" --engine caddy --domain example.com --upstream https://origin.example.com \
  >"$TMP_DIR/sudo.out" 2>&1 || fail "非 root 参数重执行失败"
grep -Fx -- '--engine' "$TMP_DIR/sudo.args" >/dev/null || fail "sudo 参数缺少 --engine"
grep -Fx -- 'caddy' "$TMP_DIR/sudo.args" >/dev/null || fail "sudo 参数缺少 caddy"

# 首次无参数运行只进入管理菜单，不应调用配置向导或安装 Web 服务。
cat >"$TMP_DIR/fake-manager" <<'EOF'
#!/bin/sh
printf 'menu\n' >"$BOOTSTRAP_TRACE"
EOF
chmod +x "$TMP_DIR/fake-manager"
BOOTSTRAP_TRACE="$TMP_DIR/bootstrap.trace" \
EMBY_PROXY_MANAGER_BIN="$TMP_DIR/fake-manager" \
SCRIPT_UNDER_TEST="$ROOT_DIR/setup-emby-proxy.sh" EMBY_PROXY_LIB_ONLY=1 bash -c '
  set --
  source "$SCRIPT_UNDER_TEST"
  require_root() { :; }
  acquire_operation_lock() { :; }
  release_operation_lock() { :; }
  check_platform() { :; }
  detect_existing_services() { :; }
  apt_install_prerequisites() { :; }
  install_manager_command() { :; }
  main
' || fail "首次运行管理菜单初始化失败"
grep -Fx 'menu' "$TMP_DIR/bootstrap.trace" >/dev/null || fail "首次运行没有打开管理菜单"

# 不安全 IP 模式没有显式解锁时必须在配置前拒绝。
if SCRIPT_UNDER_TEST="$ROOT_DIR/setup-emby-proxy.sh" EMBY_PROXY_LIB_ONLY=1 bash -c '
  set -- --engine caddy --mode ip --ip-address 203.0.113.10 --listen-port 18080 --upstream http://127.0.0.1:8096
  source "$SCRIPT_UNDER_TEST"
  normalize_unsafe_ip_visibility
  normalize_access_mode
  require_unsafe_ip_opt_in
' >"$TMP_DIR/ip.out" 2>&1; then
  fail "未解锁 IP 模式却返回成功"
fi
grep -F 'IP 模式是明文 HTTP，默认已禁用' "$TMP_DIR/ip.out" >/dev/null || fail "IP 模式拒绝原因不明确"

printf 'PASS: CLI help/version, sudo re-exec with empty arrays, unsafe IP guard\n'
