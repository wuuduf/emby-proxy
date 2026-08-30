#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

STATE=/etc/emby-proxy/edge-node.json
USED_FILE=/var/lib/emby-proxy-edge/used_bytes
command -v jq >/dev/null 2>&1 || exit 1
[[ -r "$STATE" ]] || exit 1

controller="$(jq -er '.controller' "$STATE")"
token="$(jq -er '.node_token' "$STATE")"
node="$(jq -er '.node_id' "$STATE")"
used="$(jq -r '.used_bytes // 0' "$STATE")"
if [[ -r "$USED_FILE" ]]; then
  candidate="$(tr -d '[:space:]' <"$USED_FILE")"
  [[ "$candidate" =~ ^[0-9]+$ ]] && used="$candidate"
fi
public_ip="$(jq -r '.public_ip // ""' "$STATE")"
healthy=0
for service in caddy nginx; do
  if systemctl is-active --quiet "$service" 2>/dev/null; then healthy=1; break; fi
done

payload="$(jq -nc --arg node "$node" --arg public_ip "$public_ip" --argjson used "$used" --argjson healthy "$healthy" \
  '{node_id:$node,used_bytes:$used,healthy:($healthy==1),event:"edge_heartbeat",version:"edge-0.1"} + (if $public_ip != "" then {public_ip:$public_ip} else {} end)')"
curl -fsSL --connect-timeout 8 --max-time 15 -X POST "$controller/heartbeat" \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $token" --data "$payload" >/dev/null
