#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
MANAGER="$ROOT_DIR/emby-proxy"
INSTALLER="$ROOT_DIR/setup-emby-proxy.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$TMP_DIR/state/sites.d" "$TMP_DIR/state/backups" "$TMP_DIR/log" "$TMP_DIR/caddy" "$TMP_DIR/nginx"

NOW="$(date +%s)"
cat >"$TMP_DIR/caddy/Caddyfile" <<'EOF'
http://203.0.113.10:18080 {
    respond "before" 200
}
EOF
cat >"$TMP_DIR/state/sites.d/ip-203.0.113.10-18080.json" <<EOF
{"schema_version":1,"id":"ip-203.0.113.10-18080","engine":"caddy","mode":"ip","domain":"","ip":"203.0.113.10","listen_port":18080,"public_url":"http://203.0.113.10:18080","managed_kind":"standalone","config_file":"$TMP_DIR/caddy/Caddyfile","created_at":"2026-08-17T00:00:00Z","updated_at":"2026-08-17T00:00:00Z","routes":[{"path":"/","upstream":"http://127.0.0.1:8096"}]}
EOF
cat >"$TMP_DIR/os-release" <<'EOF'
PRETTY_NAME="Test Debian"
VERSION="12 (bookworm)"
EOF
cat >"$TMP_DIR/log/emby-proxy-ip-203.0.113.10-18080-access.log" <<EOF
{"ts":$NOW,"request":{"remote_ip":"1.2.3.4","method":"GET","uri":"/Videos/1/stream"},"status":200,"size":1048576,"duration":2.5}
{"ts":$NOW,"request":{"remote_ip":"5.6.7.8","method":"GET","uri":"/web/index.html"},"status":500,"size":100,"duration":0.2}
EOF

# 日志过滤与流量统计应同时兼容 Caddy JSON 字段。
EMBY_PROXY_STATE_HOME="$TMP_DIR/state" EMBY_PROXY_CADDYFILE="$TMP_DIR/caddy/Caddyfile" \
EMBY_PROXY_CADDY_LOG_DIR="$TMP_DIR/log" EMBY_PROXY_NGINX_CONF_DIR="$TMP_DIR/nginx" \
EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" bash -c '
  set --
  source "$MANAGER_UNDER_TEST"
  show_stats ip-203.0.113.10-18080 24h >"$EMBY_PROXY_STATE_HOME/stats.out"
  view_logs ip-203.0.113.10-18080 --media >"$EMBY_PROXY_STATE_HOME/media.out"
  view_logs ip-203.0.113.10-18080 --errors >"$EMBY_PROXY_STATE_HOME/errors.out"
' || fail "日志/统计功能运行失败"
grep -F '请求数：2' "$TMP_DIR/state/stats.out" >/dev/null || fail "统计请求数错误"
grep -F '4xx/5xx：1' "$TMP_DIR/state/stats.out" >/dev/null || fail "统计错误数错误"
grep -F '/Videos/1/stream' "$TMP_DIR/state/media.out" >/dev/null || fail "媒体过滤失败"
grep -F '/web/index.html' "$TMP_DIR/state/errors.out" >/dev/null || fail "错误过滤失败"

# IP 入口诊断在服务、监听、配置、健康和源站都正常时不应产生错误。
EMBY_PROXY_STATE_HOME="$TMP_DIR/state" EMBY_PROXY_CADDYFILE="$TMP_DIR/caddy/Caddyfile" \
EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" bash -c '
  set --
  source "$MANAGER_UNDER_TEST"
  systemctl() { [[ "$1" == is-active ]] && return 0; return 0; }
  caddy() { return 0; }
  ss() { printf "LISTEN 0 4096 0.0.0.0:18080 0.0.0.0:*\n"; }
  curl() { printf 200; }
  doctor_site "$EMBY_PROXY_STATE_HOME/sites.d/ip-203.0.113.10-18080.json" "" >"$EMBY_PROXY_STATE_HOME/doctor.out"
  [[ "$DOCTOR_ERROR" == 0 ]]
' || fail "入口诊断产生错误"
grep -F '本机入口健康检查 HTTP 200' "$TMP_DIR/state/doctor.out" >/dev/null || fail "诊断缺少健康检查"

# 只有 Caddy/IP 入口时，Nginx 和域名计数为 0 不能被 pipefail 当成错误。
EMBY_PROXY_STATE_HOME="$TMP_DIR/state" EMBY_PROXY_CADDYFILE="$TMP_DIR/caddy/Caddyfile" \
EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" bash -c '
  set --
  source "$MANAGER_UNDER_TEST"
  systemctl() { return 1; }
  caddy() { printf "test-caddy"; }
  print_status >"$EMBY_PROXY_STATE_HOME/status.out"
' || fail "零项引擎/模式统计导致状态页面退出"
grep -F '托管入口：1（域名 HTTPS 0，IP HTTP 1）' "$TMP_DIR/state/status.out" >/dev/null || fail "状态页面入口计数错误"
grep -F '引擎分布：Caddy 1，Nginx 0' "$TMP_DIR/state/status.out" >/dev/null || fail "状态页面引擎计数错误"

# 完整诊断不能因为 /etc/os-release 中也存在 VERSION 变量而与管理器版本冲突。
EMBY_PROXY_STATE_HOME="$TMP_DIR/state" EMBY_PROXY_CADDYFILE="$TMP_DIR/caddy/Caddyfile" \
EMBY_PROXY_OS_RELEASE_FILE="$TMP_DIR/os-release" EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" bash -c '
  set --
  source "$MANAGER_UNDER_TEST"
  systemctl() { [[ "$1" == is-active ]] && return 0; return 0; }
  caddy() { return 0; }
  ss() { printf "LISTEN 0 4096 0.0.0.0:18080 0.0.0.0:*\n"; }
  curl() { printf 200; }
  run_doctor ip-203.0.113.10-18080 >"$EMBY_PROXY_STATE_HOME/full-doctor.out"
' || fail "完整诊断读取 os-release 失败"
grep -F '系统：Test Debian' "$TMP_DIR/state/full-doctor.out" >/dev/null || fail "完整诊断未读取系统名称"

# 备份必须带元数据和哈希，恢复前再次备份，并恢复配置内容。
EMBY_PROXY_STATE_HOME="$TMP_DIR/state" EMBY_PROXY_CADDYFILE="$TMP_DIR/caddy/Caddyfile" \
EMBY_PROXY_NGINX_CONF_DIR="$TMP_DIR/nginx" EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" bash -c '
  set --
  source "$MANAGER_UNDER_TEST"
  systemctl() { return 0; }
  caddy() { return 0; }
  chown() { return 0; }
  chmod() { if [[ "$1" == --reference=* ]]; then command chmod 0644 "${@: -1}"; else command chmod "$@"; fi; }
  dir="$(backup_target ip-203.0.113.10-18080 "$EMBY_PROXY_CADDYFILE" test-backup)"
  printf "changed\n" >"$EMBY_PROXY_CADDYFILE"
  restore_backup "$(basename "$dir")" <<<y >"$EMBY_PROXY_STATE_HOME/restore.out"
' || fail "备份恢复失败"
grep -F 'respond "before" 200' "$TMP_DIR/caddy/Caddyfile" >/dev/null || fail "备份内容未恢复"
find "$TMP_DIR/state/backups" -name metadata.json -print -quit | grep -q . || fail "备份缺少 metadata.json"

# 自更新必须校验两个文件的 SHA256，并原子安装管理器和后端。
mkdir -p "$TMP_DIR/update-source" "$TMP_DIR/installed/bin" "$TMP_DIR/installed/lib"
cp "$MANAGER" "$TMP_DIR/update-source/emby-proxy"
cp "$INSTALLER" "$TMP_DIR/update-source/setup-emby-proxy.sh"
(
  cd "$TMP_DIR/update-source"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum emby-proxy setup-emby-proxy.sh >checksums.txt
  else
    shasum -a 256 emby-proxy setup-emby-proxy.sh >checksums.txt
  fi
)
printf '#!/usr/bin/env bash\necho old\n' >"$TMP_DIR/installed/bin/emby-proxy"
printf '#!/usr/bin/env bash\necho old-backend\n' >"$TMP_DIR/installed/lib/setup-emby-proxy.sh"
chmod +x "$TMP_DIR/installed/bin/emby-proxy" "$TMP_DIR/installed/lib/setup-emby-proxy.sh"
EMBY_PROXY_STATE_HOME="$TMP_DIR/state" \
EMBY_PROXY_MANAGER_BIN="$TMP_DIR/installed/bin/emby-proxy" \
EMBY_PROXY_INSTALLED_BACKEND="$TMP_DIR/installed/lib/setup-emby-proxy.sh" \
EMBY_PROXY_UPDATE_BASE_URL="file://$TMP_DIR/update-source" \
EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" bash -c '
  set --
  source "$MANAGER_UNDER_TEST"
  self_update --force >"$EMBY_PROXY_STATE_HOME/update.out"
' || fail "带校验自更新失败"
cmp "$MANAGER" "$TMP_DIR/installed/bin/emby-proxy" >/dev/null || fail "管理器未更新"
cmp "$INSTALLER" "$TMP_DIR/installed/lib/setup-emby-proxy.sh" >/dev/null || fail "安装后端未更新"

# 仓库发布校验文件必须与当前两个可执行文件一致。
[[ -f "$ROOT_DIR/checksums.txt" ]] || fail "仓库缺少 checksums.txt"
(
  cd "$ROOT_DIR"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c checksums.txt >/dev/null
  else
    shasum -a 256 -c checksums.txt >/dev/null
  fi
) || fail "仓库 checksums.txt 已过期"

printf 'PASS: doctor, log filters, traffic stats, backup restore, checksum update\n'
