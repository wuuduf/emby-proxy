#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
# Exercise the real installer entry point. Only platform/network/host inventory
# are replaced; any package install, manager write or service change is fatal.
EMBY_PROXY_LIB_ONLY=1 source "$ROOT_DIR/setup-emby-proxy.sh" --node-preflight \
  --engine caddy --domain preflight.example.com --domain-mode subdomain \
  --upstream https://origin.example.com --address-family ipv4
require_root() { :; }
check_platform() { :; }
detect_existing_services() { :; }
curl() { printf 403; }
ss() { printf 'LISTEN 0 100 0.0.0.0:443 0.0.0.0:* users:(("other-service",pid=1,fd=9))\n'; }
apt_install_prerequisites() { echo 'BUG: packages modified' >&2; exit 99; }
install_manager_command() { echo 'BUG: manager modified' >&2; exit 99; }
apply_config() { echo 'BUG: config modified' >&2; exit 99; }
if ( main ) >"$TMP_DIR/conflict.log" 2>&1; then echo 'FAIL: occupied port was accepted' >&2; exit 1; fi
grep -F '其他程序占用' "$TMP_DIR/conflict.log" >/dev/null
! grep -F 'BUG:' "$TMP_DIR/conflict.log" >/dev/null
ss() { :; }
( main ) >"$TMP_DIR/ok.log" 2>&1
grep -F '预检通过' "$TMP_DIR/ok.log" >/dev/null
! grep -F 'BUG:' "$TMP_DIR/ok.log" >/dev/null
echo 'PASS: edge backend read-only preflight rejects conflicts without installation'
