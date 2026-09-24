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
grep -F -- '--domain DOMAIN' "$TMP_DIR/setup-help" >/dev/null || fail "帮助缺少域名参数"
grep -F -- 'uninstall [--yes]' "$TMP_DIR/manager-help" >/dev/null || fail "帮助缺少安全卸载命令"
"$ROOT_DIR/emby-proxy" version | grep -F '3.3.0-menu' >/dev/null || fail "版本输出错误"

# 非 root 且没有任何 --route 时，sudo 重执行参数不能因空数组 + nounset 崩溃。
mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/sudo" <<'SUDO'
#!/bin/sh
printf '%s\n' "$@" >"$SUDO_ARGS_OUT"
SUDO
chmod +x "$TMP_DIR/bin/sudo"
SUDO_ARGS_OUT="$TMP_DIR/sudo.args" PATH="$TMP_DIR/bin:$PATH" \
  "$ROOT_DIR/setup-emby-proxy.sh" --engine caddy --domain example.com --upstream https://origin.example.com \
  >"$TMP_DIR/sudo.out" 2>&1 || fail "非 root 参数重执行失败"
grep -Fx -- '--engine' "$TMP_DIR/sudo.args" >/dev/null || fail "sudo 参数缺少 --engine"
grep -Fx -- 'caddy' "$TMP_DIR/sudo.args" >/dev/null || fail "sudo 参数缺少 caddy"

# 进程替换入口（bash <(curl ... )）在 sudo 重执行时必须落到稳定临时文件，
# 不能把已经读过的 /dev/fd/* 传给 sudo。
cp "$ROOT_DIR/setup-emby-proxy.sh" "$TMP_DIR/process-source.sh"
SUDO_ARGS_OUT="$TMP_DIR/process-sudo.args" \
EMBY_PROXY_SCRIPT_URL="file://$TMP_DIR/process-source.sh" \
PATH="$TMP_DIR/bin:$PATH" \
  bash <(cat "$TMP_DIR/process-source.sh") --engine caddy --domain example.com --upstream https://origin.example.com \
  >"$TMP_DIR/process.out" 2>&1 || fail "进程替换入口启动失败"
grep -F '/dev/fd/' "$TMP_DIR/process-sudo.args" >/dev/null && fail "进程替换入口仍把 /dev/fd 传给 sudo"
grep -F -- '--engine' "$TMP_DIR/process-sudo.args" >/dev/null || fail "进程替换入口 sudo 参数缺少 --engine"

# 首次无参数运行只进入管理菜单，不应调用配置向导或安装 Web 服务。
cat >"$TMP_DIR/fake-manager" <<'MANAGER'
#!/bin/sh
printf 'menu\n' >"$BOOTSTRAP_TRACE"
MANAGER
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

printf 'PASS: CLI help/version, sudo re-exec with empty arrays, menu bootstrap\n'
