#!/usr/bin/env bash
# 兼容旧文件名：实际脚本现已同时支持 Caddy 与 Nginx。
set -Eeuo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
exec "$SCRIPT_DIR/setup-emby-proxy.sh" "$@"
