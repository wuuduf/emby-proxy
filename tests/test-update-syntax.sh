#!/usr/bin/env bash
# The update path must syntax-check both downloaded release files.
set -Eeuo pipefail
ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/source" "$TMP_DIR/installed/bin" "$TMP_DIR/installed/lib" "$TMP_DIR/state"
cp "$ROOT_DIR/emby-proxy" "$TMP_DIR/source/emby-proxy"
printf '%s\n' '#!/usr/bin/env bash' 'if broken syntax' >"$TMP_DIR/source/setup-emby-proxy.sh"
chmod +x "$TMP_DIR/source/emby-proxy" "$TMP_DIR/source/setup-emby-proxy.sh"
(
  cd "$TMP_DIR/source"
  sha256sum emby-proxy setup-emby-proxy.sh >checksums.txt
)
printf '%s\n' '#!/usr/bin/env bash' 'echo old-manager' >"$TMP_DIR/installed/bin/emby-proxy"
printf '%s\n' '#!/usr/bin/env bash' 'echo old-backend' >"$TMP_DIR/installed/lib/setup-emby-proxy.sh"
chmod +x "$TMP_DIR/installed/bin/emby-proxy" "$TMP_DIR/installed/lib/setup-emby-proxy.sh"
if EMBY_PROXY_STATE_HOME="$TMP_DIR/state" \
  EMBY_PROXY_MANAGER_BIN="$TMP_DIR/installed/bin/emby-proxy" \
  EMBY_PROXY_INSTALLED_BACKEND="$TMP_DIR/installed/lib/setup-emby-proxy.sh" \
  EMBY_PROXY_UPDATE_BASE_URL="file://$TMP_DIR/source" EMBY_PROXY_MANAGER_LIB_ONLY=1 \
  MANAGER_UNDER_TEST="$ROOT_DIR/emby-proxy" bash -c '
    source "$MANAGER_UNDER_TEST"
    acquire_lock() { :; }; release_lock() { :; }; ensure_short_command() { :; }
    self_update --force
  ' >"$TMP_DIR/out" 2>"$TMP_DIR/err"; then
  echo 'FAIL: update accepted syntax-invalid backend' >&2
  exit 1
fi
grep -F '更新文件语法验证失败' "$TMP_DIR/err" >/dev/null || {
  echo 'FAIL: update did not report backend syntax failure' >&2
  exit 1
}
grep -Fx 'echo old-backend' "$TMP_DIR/installed/lib/setup-emby-proxy.sh" >/dev/null
printf 'PASS: update checks syntax of manager and backend separately\n'
