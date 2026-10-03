#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
MANAGER="$ROOT_DIR/emby-proxy"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# same-name systemd units must not be removed merely because their filename is
# emby-proxy-master/node. Only our exact generated command/marker is owned.
owned="$TMP_DIR/emby-proxy-master.service"
third="$TMP_DIR/emby-proxy-node.service"
trace="$TMP_DIR/systemctl.trace"
cat >"$owned" <<'EOF'
[Unit]
Description=emby-proxy multiline master
[Service]
ExecStart=/usr/local/sbin/emby-proxy controller serve --state "/etc/emby-proxy/controller.json" --listen "127.0.0.1:19090" --reconcile-interval 30
EOF
cat >"$third" <<'EOF'
[Unit]
Description=unrelated service
[Service]
ExecStart=/usr/local/bin/other-controller
EOF
EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" OWNED="$owned" THIRD="$third" TRACE="$trace" \
bash -c '
  set --; source "$MANAGER_UNDER_TEST"
  systemctl() { printf "%s " "$@" >>"$TRACE"; printf "\n" >>"$TRACE"; }
  uninstall_remove_owned_systemd_unit "$OWNED" master
  uninstall_remove_owned_systemd_unit "$THIRD" node
' || fail "ownership helper failed"
[[ ! -e "$owned" ]] || fail "owned master unit was not removed"
[[ -e "$third" ]] || fail "unrelated same-name unit was removed"
grep -F 'disable --now emby-proxy-master.service' "$trace" >/dev/null || fail "owned unit was not disabled"
if grep -F 'emby-proxy-node.service' "$trace" >/dev/null; then fail "unrelated unit was touched"; fi

# Uninstall cleanup must not follow or remove operator-owned config symlinks.
caddy_target="$TMP_DIR/real-Caddyfile"
caddy_link="$TMP_DIR/Caddyfile"
cat >"$caddy_target" <<'EOF'
# BEGIN MANAGED EMBY REVERSE PROXY: test.example.com
test.example.com { respond "ok" 200 }
# END MANAGED EMBY REVERSE PROXY: test.example.com
EOF
ln -s "$caddy_target" "$caddy_link"
EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" TARGET="$caddy_link" bash -c '
  set --; source "$MANAGER_UNDER_TEST"; uninstall_remove_caddy_markers "$TARGET"
' >/dev/null 2>&1 || fail "Caddy symlink cleanup returned failure"
[[ -L "$caddy_link" && -f "$caddy_target" ]] || fail "Caddy symlink was modified or removed"

nginx_target="$TMP_DIR/real-nginx.conf"
nginx_link="$TMP_DIR/nginx.conf"
printf '# MANAGED EMBY SITE: test.example.com\n' >"$nginx_target"
ln -s "$nginx_target" "$nginx_link"
EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" TARGET="$nginx_link" bash -c '
  set --; source "$MANAGER_UNDER_TEST"; uninstall_remove_nginx_owned_file "$TARGET" "# MANAGED EMBY SITE:"
' >/dev/null 2>&1 || fail "Nginx symlink cleanup returned failure"
[[ -L "$nginx_link" && -f "$nginx_target" ]] || fail "Nginx symlink was modified or removed"

# The Certbot deploy hook is removed only when the ownership marker is ours;
# an existing unmarked hook must remain untouched.
owned_hook="$TMP_DIR/reload-nginx.sh"
printf '#!/bin/sh\n# MANAGED EMBY-PROXY: Nginx renew hook\nsystemctl reload nginx\n' >"$owned_hook"
EMBY_PROXY_NGINX_RENEW_HOOK="$owned_hook" EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" \
bash -c 'set --; source "$MANAGER_UNDER_TEST"; uninstall_remove_nginx_renew_hook' \
  >/dev/null 2>&1 || fail "托管 Certbot 钩子清理返回失败"
[[ ! -e "$owned_hook" ]] || fail "托管 Certbot 钩子未删除"

foreign_hook="$TMP_DIR/foreign-reload-nginx.sh"
printf '#!/bin/sh\nsystemctl reload nginx\n# operator-owned\n' >"$foreign_hook"
EMBY_PROXY_NGINX_RENEW_HOOK="$foreign_hook" EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" \
bash -c 'set --; source "$MANAGER_UNDER_TEST"; uninstall_remove_nginx_renew_hook' \
  >/dev/null 2>&1 || fail "非托管 Certbot 钩子检查返回失败"
[[ -e "$foreign_hook" ]] || fail "非托管 Certbot 钩子被删除"

# systemd specifiers must be escaped as %% in generated Telegram unit paths.
state_dir="$TMP_DIR/state%dir"
unit="$TMP_DIR/telegram%unit/emby-proxy-telegram.service"
mkdir -p "$state_dir" "$(dirname "$unit")"
cat >"$state_dir/controller.json" <<'JSON'
{"schema_version":1,"entry_id":"domain-test.example.com","telegram":{"enabled":true}}
JSON
EMBY_PROXY_TELEGRAM_UNIT="$unit" EMBY_PROXY_NGINX_RENEW_HOOK="$foreign_hook" EMBY_PROXY_STATE_HOME="$state_dir" \
EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" STATE="$state_dir/controller.json" TRACE="$trace" \
bash -c '
  set --; source "$MANAGER_UNDER_TEST"
  controller_require_state() { printf "%s" "$STATE"; }
  systemctl() { printf "%s\n" "$*" >>"$TRACE"; return 0; }
  controller_telegram_install
' >/dev/null 2>"$TMP_DIR/install.err" || fail "Telegram unit install failed"
escaped_dir="${state_dir//%/%%}"
grep -F "ReadWritePaths=\"${escaped_dir}\"" "$unit" >/dev/null || fail "Telegram ReadWritePaths did not escape %%"
grep -F -- "--state=\"${escaped_dir}/controller.json\"" "$unit" >/dev/null || fail "Telegram state path did not escape %%"

# The uninstall archive must retain a managed custom Telegram unit for
# recovery, just like the other project-owned service files.
archive="$TMP_DIR/backups/archive.tar.gz"
mkdir -p "$(dirname "$archive")"
archive_path_file="$TMP_DIR/archive.path"
EMBY_PROXY_TELEGRAM_UNIT="$unit" EMBY_PROXY_NGINX_RENEW_HOOK="$foreign_hook" EMBY_PROXY_STATE_HOME="$state_dir" \
  EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" bash -c '
    source "$MANAGER_UNDER_TEST"; uninstall_archive "$(dirname "$1")" archive-test
  ' bash "$archive" >"$archive_path_file"
archive_path="$(cat "$archive_path_file")"
tar -tzf "$archive_path" | grep -F "$(basename "$unit")" >/dev/null || fail "Telegram unit missing from uninstall archive"
tar -tzf "$archive_path" | grep -F "$(basename "$foreign_hook")" >/dev/null || fail "Certbot hook missing from uninstall archive"
rm -f "$archive_path_file"

# Known controller/node lock paths are removed without sweeping unrelated
# files in a custom state directory.
for lock in controller.json.lock controller.json.telegram.poll.lock controller.json.cert-issue.lock \
  controller.json.https-proxy.lock controller.json.sync.lock multiline-node.json.lock \
  multiline-node.json.cert-issue.lock usage.offset.lock; do
  : >"$state_dir/$lock"
done
: >"$state_dir/keep-user.lock"
EMBY_PROXY_STATE_HOME="$state_dir" EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" \
bash -c 'set --; source "$MANAGER_UNDER_TEST"; uninstall_remove_known_locks'
for lock in controller.json.lock controller.json.telegram.poll.lock controller.json.cert-issue.lock \
  controller.json.https-proxy.lock controller.json.sync.lock multiline-node.json.lock \
  multiline-node.json.cert-issue.lock usage.offset.lock; do
  [[ ! -e "$state_dir/$lock" ]] || fail "known lock was left behind: $lock"
done
[[ -e "$state_dir/keep-user.lock" ]] || fail "unrelated lock was removed"

printf 'PASS: uninstall ownership and systemd specifier escaping\n'
