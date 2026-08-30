#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

CONTROLLER=""; ENTRY_ID=""; NODE_ID=""; NODE_NAME=""; PRIORITY=""; QUOTA_BYTES=0; ENROLL_TOKEN=""; ENGINE="caddy"; PUBLIC_IP=""
while (($#)); do
  case "$1" in
    --controller) CONTROLLER="$2"; shift 2;;
    --entry-id) ENTRY_ID="$2"; shift 2;;
    --node-id) NODE_ID="$2"; shift 2;;
    --name) NODE_NAME="$2"; shift 2;;
    --priority) PRIORITY="$2"; shift 2;;
    --quota-bytes) QUOTA_BYTES="$2"; shift 2;;
    --enroll-token) ENROLL_TOKEN="$2"; shift 2;;
    --engine) ENGINE="$2"; shift 2;;
    --public-ip) PUBLIC_IP="$2"; shift 2;;
    *) echo "未知参数：$1" >&2; exit 2;;
  esac
done
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '请使用 root 或 sudo 运行。' >&2; exit 1; }
for command in curl jq; do command -v "$command" >/dev/null || { echo "缺少 $command，请先安装。" >&2; exit 1; }; done
[[ -n "$CONTROLLER" && -n "$ENTRY_ID" && -n "$NODE_ID" && -n "$NODE_NAME" && -n "$PRIORITY" && -n "$ENROLL_TOKEN" ]] || { echo '缺少控制器、入口、节点或注册码参数。' >&2; exit 2; }
CONTROLLER="${CONTROLLER%/}"
response="$(curl -fsSL --connect-timeout 8 --max-time 20 -X POST "$CONTROLLER/enroll" -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg entry "$ENTRY_ID" --arg node "$NODE_ID" --arg name "$NODE_NAME" --arg token "$ENROLL_TOKEN" --arg public_ip "$PUBLIC_IP" --argjson priority "$PRIORITY" --argjson quota "$QUOTA_BYTES" \
    '{entry_id:$entry,node_id:$node,name:$name,priority:$priority,quota_bytes:$quota,enroll_token:$token,version:"edge-0.1"} + (if $public_ip != "" then {public_ip:$public_ip} else {} end)')")"
NODE_TOKEN="$(jq -er '.node_token' <<<"$response")"
DOMAIN="$(jq -er '.domain' <<<"$response")"
SOURCE="$(jq -er '.source' <<<"$response")"
ENGINE="$(jq -er '.engine // "caddy"' <<<"$response")"
STATE_DIR=/etc/emby-proxy
STATE_FILE="$STATE_DIR/edge-node.json"
install -d -m 0750 "$STATE_DIR" /var/lib/emby-proxy-edge
jq -n --arg controller "$CONTROLLER" --arg entry "$ENTRY_ID" --arg node "$NODE_ID" --arg token "$NODE_TOKEN" --arg public_ip "$PUBLIC_IP" \
  --arg domain "$DOMAIN" --arg source "$SOURCE" --arg engine "$ENGINE" \
  '{controller:$controller,entry_id:$entry,node_id:$node,node_token:$token,domain:$domain,source:$source,engine:$engine,public_ip:$public_ip,used_bytes:0,used_bytes_file:"/var/lib/emby-proxy-edge/used_bytes"}' >"$STATE_FILE"
chmod 0600 "$STATE_FILE"
printf '0\n' >/var/lib/emby-proxy-edge/used_bytes
chmod 0640 /var/lib/emby-proxy-edge/used_bytes
BACKEND="/usr/local/lib/emby-proxy/setup-emby-proxy.sh"
if [[ ! -x "$BACKEND" ]]; then
  install -d -m 0755 "$(dirname "$BACKEND")"
  tmp="$(mktemp /tmp/emby-proxy-backend.XXXXXX)"
  curl -fsSL --connect-timeout 8 --max-time 30 'https://raw.githubusercontent.com/wuuduf/emby-proxy/main/setup-emby-proxy.sh' -o "$tmp"
  install -m 0755 "$tmp" "$BACKEND"; rm -f "$tmp"
fi
"$BACKEND" --engine "$ENGINE" --domain "$DOMAIN" --upstream "$SOURCE"
agent_tmp="$(mktemp /tmp/emby-proxy-edge-agent.XXXXXX)"
curl -fsSL --connect-timeout 8 --max-time 20 "$CONTROLLER/edge-agent.sh" -o "$agent_tmp"
install -d -m 0755 /usr/local/lib/emby-proxy
install -m 0755 "$agent_tmp" /usr/local/lib/emby-proxy/edge-agent.sh
rm -f "$agent_tmp"
cat >/etc/systemd/system/emby-proxy-edge.service <<'UNIT'
[Unit]
Description=emby-proxy edge heartbeat agent
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/lib/emby-proxy/edge-agent.sh
UNIT
cat >/etc/systemd/system/emby-proxy-edge.timer <<'UNIT'
[Unit]
Description=emby-proxy edge heartbeat timer

[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now emby-proxy-edge.timer
systemctl start emby-proxy-edge.service
printf '边缘节点注册成功：%s（%s）\n' "$NODE_ID" "$DOMAIN"
