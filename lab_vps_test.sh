#!/usr/bin/env bash
set -Eeuo pipefail
state=/tmp/ep-lab-vps-state.json
log=/tmp/ep-lab-vps-controller.log
rm -f "$state" /tmp/ep-lab-vps-a.token /tmp/ep-lab-vps-b.token "$log"
python3 /tmp/lab_controller.py --listen 127.0.0.1:19090 --entry-id vps-entry --source https://origin.test \
  --state "$state" --token line-a=token-a --token line-b=token-b >"$log" 2>&1 &
ctl=$!
trap 'kill "$ctl" 2>/dev/null || true; rm -f /tmp/ep-lab-vps-a.token /tmp/ep-lab-vps-b.token' EXIT
sleep 1
A="$(curl -fsS -X POST http://127.0.0.1:19090/enroll -H 'Content-Type: application/json' \
  -d '{"entry_id":"vps-entry","node_id":"line-a","name":"fast","priority":100,"quota_bytes":1000,"enroll_token":"token-a"}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["node_token"])')"
B="$(curl -fsS -X POST http://127.0.0.1:19090/enroll -H 'Content-Type: application/json' \
  -d '{"entry_id":"vps-entry","node_id":"line-b","name":"slow","priority":80,"quota_bytes":1000,"enroll_token":"token-b"}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["node_token"])')"
curl -fsS -X POST http://127.0.0.1:19090/heartbeat -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $A" -d '{"node_id":"line-a","healthy":true,"used_bytes":100,"event":"edge_started"}' >/dev/null
curl -fsS -X POST http://127.0.0.1:19090/heartbeat -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $B" -d '{"node_id":"line-b","healthy":true,"used_bytes":50,"event":"edge_started"}' >/dev/null
S="$(curl -fsS http://127.0.0.1:19090/status)"
printf '%s\n' "$S" | python3 -c 'import json,sys; s=json.load(sys.stdin); assert s["selected_node"]=="line-a",s; print("selected after enroll:",s["selected_node"])'
curl -fsS -X POST http://127.0.0.1:19090/heartbeat -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $A" -d '{"node_id":"line-a","healthy":true,"used_bytes":1000,"event":"quota_reached"}' >/dev/null
S="$(curl -fsS http://127.0.0.1:19090/status)"
printf '%s\n' "$S" | python3 -c 'import json,sys; s=json.load(sys.stdin); assert s["selected_node"]=="line-b",s; print("selected after quota:",s["selected_node"])'
printf 'PASS: VPS control-plane enrollment, heartbeat, priority and quota failover\n'
