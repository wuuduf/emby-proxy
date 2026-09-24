#!/usr/bin/env bash
# Regression: same-version updates must propagate the changed flag out of the subshell.
set -Eeuo pipefail
ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

for scenario in changed unchanged cancelled failed; do
  SCENARIO="$scenario" TRACE="$TMP_DIR/$scenario" \
  EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$ROOT_DIR/emby-proxy" bash -c '
    source "$MANAGER_UNDER_TEST"
    self_update() {
      case "$SCENARIO" in
        changed) UPDATE_CHANGED=1 ;;
        unchanged|cancelled) UPDATE_CHANGED=0 ;;
        failed) UPDATE_CHANGED=1; die "simulated failure" ;;
      esac
    }
    restart_updated_manager() {
      [[ "$1" == "$VERSION" ]] || exit 2
      if (( UPDATE_CHANGED == 1 )); then printf "restart\n" >>"$TRACE"; fi
    }
    ui_pause() { printf "pause\n" >>"$TRACE"; }
    # A previous update must not leak its success into this attempt.
    UPDATE_CHANGED=0
    [[ "$SCENARIO" != unchanged ]] || UPDATE_CHANGED=1
    menu_update
    printf "survived\n" >>"$TRACE"
  ' >"$TMP_DIR/$scenario.out" 2>"$TMP_DIR/$scenario.err"
  grep -qx survived "$TMP_DIR/$scenario"
  grep -qx pause "$TMP_DIR/$scenario"
  if [[ "$scenario" == changed ]]; then
    grep -qx restart "$TMP_DIR/$scenario" || {
      echo 'FAIL: same-version menu update lost UPDATE_CHANGED'; exit 1;
    }
  elif grep -qx restart "$TMP_DIR/$scenario"; then
    echo "FAIL: $scenario must not restart"; exit 1
  fi
done
echo 'PASS: same-version update restarts; no change/cancel/failure stay in menu'
