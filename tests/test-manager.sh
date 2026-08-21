#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
MANAGER="$ROOT_DIR/emby-proxy"
INSTALLER="$ROOT_DIR/setup-emby-proxy.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_jq() { jq -e "$2" "$1" >/dev/null || fail "$1 不满足 jq 条件：$2"; }
assert_arg() { grep -Fx -- "$2" "$1" >/dev/null || fail "$1 缺少参数：$2"; }

EMBY_PROXY_LIB_ONLY=1 INSTALLER_UNDER_TEST="$INSTALLER" bash -c '
  set -- --manager-only
  source "$INSTALLER_UNDER_TEST"
  [[ "$MANAGER_ONLY" == 1 ]]
' || fail "--manager-only 参数解析失败"

mkdir -p "$TMP_DIR/caddy" "$TMP_DIR/nginx" "$TMP_DIR/state"
cat >"$TMP_DIR/caddy/Caddyfile" <<'EOF'
# BEGIN MANAGED EMBY REVERSE PROXY: one.example.com
one.example.com {
    handle /_emby_proxy_health {
        respond "ok" 200
    }
    handle_path /a/* {
        reverse_proxy https://origin-a.example.net {
        }
    }
    handle {
        reverse_proxy https://origin-one.example.net {
        }
    }
}
# END MANAGED EMBY REVERSE PROXY: one.example.com

# BEGIN MANAGED EMBY REVERSE PROXY: ip-203.0.113.10-18080
http://203.0.113.10:18080 {
    handle /_emby_proxy_health {
        respond "ok" 200
    }
    handle {
        reverse_proxy http://127.0.0.1:8096 {
        }
    }
}
# END MANAGED EMBY REVERSE PROXY: ip-203.0.113.10-18080

# BEGIN MANAGED EMBY REVERSE PROXY: one.example.com-https-18443
https://one.example.com:18443 {
    handle {
        reverse_proxy https://origin-port.example.net {
        }
    }
}
# END MANAGED EMBY REVERSE PROXY: one.example.com-https-18443
EOF

cat >"$TMP_DIR/caddy/existing.caddy" <<'EOF'
existing.example.com {
    respond "original" 200

# BEGIN MANAGED EMBY EXISTING ROUTE: existing.example.com /media
    redir /media /media/ 308
    handle_path /media/* {
        reverse_proxy https://media-origin.example.net {
        }
    }
# END MANAGED EMBY EXISTING ROUTE: existing.example.com /media
}
EOF

cat >"$TMP_DIR/nginx/emby-proxy-nginx.example.com.conf" <<'EOF'
# 由 setup-emby-proxy.sh 自动管理，请勿在此文件中混入其他站点。
server {
    listen 443 ssl;
    server_name nginx.example.com;
    location = /b { return 308 /b/; }
    location ^~ /b/ {
        proxy_pass https://origin-b.example.net/;
    }
    location / {
        proxy_pass http://10.0.0.3:8096;
    }
}
EOF

cat >"$TMP_DIR/nginx/emby-proxy-nginx.example.com-https-19443.conf" <<'EOF'
# MANAGED EMBY SITE: nginx.example.com-https-19443
server {
    listen 19443 ssl;
    server_name nginx.example.com;
    location / {
        proxy_pass https://origin-port-nginx.example.net;
    }
}
EOF

EMBY_PROXY_STATE_HOME="$TMP_DIR/state" \
EMBY_PROXY_CADDYFILE="$TMP_DIR/caddy/Caddyfile" \
EMBY_PROXY_NGINX_CONF_DIR="$TMP_DIR/nginx" \
EMBY_PROXY_MANAGER_LIB_ONLY=1 \
MANAGER_UNDER_TEST="$MANAGER" bash -c '
  set --
  source "$MANAGER_UNDER_TEST"
  require_jq
  ensure_state_dirs
  [[ "$(import_caddy_standalone)" == 3 ]]
  [[ "$(import_caddy_attached)" == 1 ]]
  [[ "$(import_nginx)" == 2 ]]
' || fail "旧配置导入失败"

assert_jq "$TMP_DIR/state/sites.d/domain-one.example.com.json" '.engine=="caddy" and .mode=="domain" and (.routes|length)==2'
assert_jq "$TMP_DIR/state/sites.d/domain-one.example.com.json" 'any(.routes[]; .path=="/" and .upstream=="https://origin-one.example.net")'
assert_jq "$TMP_DIR/state/sites.d/ip-203.0.113.10-18080.json" '.mode=="ip" and .listen_port==18080 and .public_url=="http://203.0.113.10:18080"'
assert_jq "$TMP_DIR/state/sites.d/domain-existing.example.com.json" '.managed_kind=="caddy_attached" and .routes[0].path=="/media"'
assert_jq "$TMP_DIR/state/sites.d/domain-nginx.example.com.json" '.engine=="nginx" and (.routes|length)==2'
assert_jq "$TMP_DIR/state/sites.d/domain-one.example.com-https-18443.json" '.engine=="caddy" and .listen_port==18443 and .entry_type=="port" and .public_url=="https://one.example.com:18443"'
assert_jq "$TMP_DIR/state/sites.d/domain-nginx.example.com-https-19443.json" '.engine=="nginx" and .listen_port==19443 and .public_url=="https://nginx.example.com:19443"'

# 管理器应把状态文件无损转换回安装后端参数。
cat >"$TMP_DIR/fake-backend" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_ARGS_OUT"
EOF
chmod +x "$TMP_DIR/fake-backend"
FAKE_ARGS_OUT="$TMP_DIR/backend.args" EMBY_PROXY_BACKEND="$TMP_DIR/fake-backend" \
EMBY_PROXY_STATE_HOME="$TMP_DIR/state" EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" bash -c '
  set --
  source "$MANAGER_UNDER_TEST"
  run_backend_for_state "$EMBY_PROXY_STATE_HOME/sites.d/domain-one.example.com.json"
' || fail "状态转后端参数失败"
assert_arg "$TMP_DIR/backend.args" '--engine'
assert_arg "$TMP_DIR/backend.args" 'caddy'
assert_arg "$TMP_DIR/backend.args" '--domain'
assert_arg "$TMP_DIR/backend.args" 'one.example.com'
assert_arg "$TMP_DIR/backend.args" '--upstream'
assert_arg "$TMP_DIR/backend.args" 'https://origin-one.example.net'
assert_arg "$TMP_DIR/backend.args" '/a=https://origin-a.example.net'

FAKE_ARGS_OUT="$TMP_DIR/backend-port.args" EMBY_PROXY_BACKEND="$TMP_DIR/fake-backend" \
EMBY_PROXY_STATE_HOME="$TMP_DIR/state" EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" bash -c '
  set --
  source "$MANAGER_UNDER_TEST"
  run_backend_for_state "$EMBY_PROXY_STATE_HOME/sites.d/domain-one.example.com-https-18443.json"
' || fail "自定义 HTTPS 端口状态转后端参数失败"
assert_arg "$TMP_DIR/backend-port.args" '--domain-mode'
assert_arg "$TMP_DIR/backend-port.args" 'port'
assert_arg "$TMP_DIR/backend-port.args" '--https-port'
assert_arg "$TMP_DIR/backend-port.args" '18443'

FAKE_ARGS_OUT="$TMP_DIR/route-add.args" EMBY_PROXY_BACKEND="$TMP_DIR/fake-backend" \
EMBY_PROXY_STATE_HOME="$TMP_DIR/state" EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" bash -c '
  set --
  source "$MANAGER_UNDER_TEST"
  route_upsert add domain-one.example.com <<EOF
/c
https://origin-c.example.net
EOF
' >/dev/null || fail "管理器新增路径失败"
assert_arg "$TMP_DIR/route-add.args" '/c=https://origin-c.example.net'

# 安装后端成功后应写入可被管理器读取的状态索引。
EMBY_PROXY_STATE_HOME="$TMP_DIR/persisted" EMBY_PROXY_LIB_ONLY=1 INSTALLER_UNDER_TEST="$INSTALLER" bash -c '
  set --
  source "$INSTALLER_UNDER_TEST"
  ACCESS_MODE=ip
  PROXY_ENGINE=caddy
  PROXY_IP=198.51.100.20
  LISTEN_PORT=18081
  set_ip_access_target >/dev/null
  ROUTE_PATHS=(/ /a)
  ROUTE_URLS=(http://127.0.0.1:8096 https://origin-a.example.net)
  ROUTE_HOSTS=(127.0.0.1 origin-a.example.net)
  persist_site_state >/dev/null
' || fail "安装后端写入管理索引失败"
assert_jq "$TMP_DIR/persisted/sites.d/ip-198.51.100.20-18081.json" '.engine=="caddy" and (.routes|length)==2'

# 删除只能移除精确托管片段，必须保留手工站点和其他独立入口。
EMBY_PROXY_STATE_HOME="$TMP_DIR/state" EMBY_PROXY_CADDYFILE="$TMP_DIR/caddy/Caddyfile" \
EMBY_PROXY_NGINX_CONF_DIR="$TMP_DIR/nginx" EMBY_PROXY_MANAGER_LIB_ONLY=1 \
MANAGER_UNDER_TEST="$MANAGER" bash -c '
  set --
  source "$MANAGER_UNDER_TEST"
  caddy() { return 0; }
  systemctl() { return 0; }
  chown() { return 0; }
  chmod() { return 0; }
  remove_attached_route domain-existing.example.com \
    "$EMBY_PROXY_STATE_HOME/sites.d/domain-existing.example.com.json" /media
  delete_site domain-one.example.com <<<y
  nginx() { return 0; }
  delete_site domain-nginx.example.com <<<y
' >/dev/null || fail "安全删除托管片段失败"
grep -F 'respond "original" 200' "$TMP_DIR/caddy/existing.caddy" >/dev/null || fail "删除附加路径破坏了手工站点"
! grep -F 'MANAGED EMBY EXISTING ROUTE' "$TMP_DIR/caddy/existing.caddy" >/dev/null || fail "附加路径标记未删除"
grep -F '# BEGIN MANAGED EMBY REVERSE PROXY: ip-203.0.113.10-18080' "$TMP_DIR/caddy/Caddyfile" >/dev/null || fail "删除一个入口误删了其他入口"
! grep -Fx '# BEGIN MANAGED EMBY REVERSE PROXY: one.example.com' "$TMP_DIR/caddy/Caddyfile" >/dev/null || fail "独立入口未删除"
grep -Fx '# BEGIN MANAGED EMBY REVERSE PROXY: one.example.com-https-18443' "$TMP_DIR/caddy/Caddyfile" >/dev/null || fail "删除 443 入口误删同域名自定义端口"
[[ ! -e "$TMP_DIR/nginx/emby-proxy-nginx.example.com.conf" ]] || fail "Nginx 独立入口未删除"

# 一键安装后端应把自身和管理命令安装到长期路径。
EMBY_PROXY_LIBEXEC="$TMP_DIR/installed/lib" EMBY_PROXY_MANAGER_BIN="$TMP_DIR/installed/bin/emby-proxy" \
EMBY_PROXY_LIB_ONLY=1 INSTALLER_UNDER_TEST="$INSTALLER" bash -c '
  set --
  source "$INSTALLER_UNDER_TEST"
  mkdir -p "$(dirname "$MANAGER_BIN")"
  install_manager_command >/dev/null
' || fail "管理命令安装失败"
[[ -x "$TMP_DIR/installed/lib/setup-emby-proxy.sh" ]] || fail "未安装配置后端"
[[ -x "$TMP_DIR/installed/bin/emby-proxy" ]] || fail "未安装 emby-proxy 命令"
"$TMP_DIR/installed/bin/emby-proxy" version | grep -F '2.2.1-modes' >/dev/null || fail "已安装管理命令不可运行"

printf 'PASS: manager install/import, state registry, route replay, exact-marker deletion\n'
