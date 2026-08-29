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
grep -F -- '仅支持 domain（域名 HTTPS）' "$TMP_DIR/setup-help" >/dev/null || fail "帮助未声明仅支持域名 HTTPS"
if grep -Eq -- '--ip-version|--ip-address|--listen-port|--show-unsafe-ip-mode' "$TMP_DIR/setup-help"; then
  fail "帮助仍暴露已移除的 IP 参数"
fi
"$ROOT_DIR/emby-proxy" version | grep -F '3.1.0-menu' >/dev/null || fail "版本输出错误"

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

# IP 旧入口及相关参数必须明确拒绝，不得进入配置阶段。
for arg in --show-unsafe-ip-mode --allow-insecure-ip --ip-address --ip-version --listen-port; do
  if "$ROOT_DIR/setup-emby-proxy.sh" "$arg" value >/dev/null 2>"$TMP_DIR/reject.out"; then
    fail "已移除参数仍返回成功：$arg"
  fi
  grep -F 'IP 明文 HTTP 模式已移除' "$TMP_DIR/reject.out" >/dev/null || fail "拒绝原因不明确：$arg"
done
if SCRIPT_UNDER_TEST="$ROOT_DIR/setup-emby-proxy.sh" EMBY_PROXY_LIB_ONLY=1 bash -c '
  set --
  source "$SCRIPT_UNDER_TEST"
  ACCESS_MODE=ip
  normalize_access_mode
' >"$TMP_DIR/mode.out" 2>&1; then
  fail "--mode ip 仍能通过模式校验"
fi
grep -F 'IP 明文 HTTP 模式已移除' "$TMP_DIR/mode.out" >/dev/null || fail "--mode ip 拒绝原因不明确"

printf 'PASS: CLI help/version, sudo re-exec with empty arrays, menu bootstrap, IP mode removal\n'
