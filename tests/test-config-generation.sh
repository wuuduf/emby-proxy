#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/setup-emby-proxy.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -F -- "$2" "$1" >/dev/null || fail "$1 缺少：$2"; }
assert_not_contains() { ! grep -F -- "$2" "$1" >/dev/null || fail "$1 不应包含：$2"; }
assert_count() {
  local actual
  actual="$(grep -cF -- "$2" "$1" || true)"
  [[ "$actual" == "$3" ]] || fail "$1 中 '$2' 数量为 $actual，期望 $3"
}

EMBY_PROXY_LIB_ONLY=1 source "$SCRIPT"

# 新版本不再创建 IP HTTP 入口；旧参数与模式必须在 CLI 层拒绝。
SCRIPT_UNDER_TEST="$SCRIPT" EMBY_PROXY_LIB_ONLY=1 bash -c '
  set -- --mode ip
  source "$SCRIPT_UNDER_TEST"
  normalize_access_mode
' >/dev/null 2>&1 && fail "IP 模式仍能通过模式校验" || true

# 域名冲突检测按完整 token 匹配，不能把 a.example.com 错认成 ba.example.com。
domain_pattern="$(domain_token_regex 'a.example.com')"
printf '%s\n' 'ba.example.com {' | grep -E "$domain_pattern" >/dev/null && fail "域名 token 匹配出现子串误判"
printf '%s\n' 'a.example.com {' | grep -E "$domain_pattern" >/dev/null || fail "域名 token 未匹配完整域名"

set_domain() {
  ACCESS_MODE="domain"
  HTTPS_PORT="443"
  DOMAIN_ENTRY_TYPE="path"
  PROXY_DOMAIN="$1"
  normalize_proxy_domain "$PROXY_DOMAIN"
  ROUTE_PATHS=("/" "/a")
  ROUTE_URLS=("https://origin.example.net" "http://10.0.0.3:8096")
  ROUTE_HOSTS=("origin.example.net" "10.0.0.3")
}

# Nginx：正式配置固定上游、拒绝伪造 XFF，并为每个域名使用唯一变量。
set_domain one.example.com
one_nginx_id="$NGINX_ID"
write_nginx_https_config "$TMP_DIR/nginx-one.conf"
write_nginx_http_config "$TMP_DIR/nginx-one-acme.conf"
assert_contains "$TMP_DIR/nginx-one.conf" 'proxy_set_header X-Forwarded-For $remote_addr;'
assert_contains "$TMP_DIR/nginx-one.conf" '"ts":$msec'
assert_not_contains "$TMP_DIR/nginx-one.conf" '$proxy_add_x_forwarded_for'
assert_contains "$TMP_DIR/nginx-one.conf" "\$emby_connection_upgrade_${one_nginx_id}"
assert_contains "$TMP_DIR/nginx-one.conf" '"~*^/a(?:/|$)" $upstream_http_location;'
assert_contains "$TMP_DIR/nginx-one.conf" "add_header Location \$emby_proxy_location_${one_nginx_id}_1 always;"
assert_not_contains "$TMP_DIR/nginx-one.conf" 'proxy_pass $'

# TCP 80 只处理共享 ACME 与 HTTPS 跳转；不能暴露明文 Emby。
assert_contains "$TMP_DIR/nginx-one-acme.conf" '# MANAGED EMBY ACME: one.example.com'
assert_contains "$TMP_DIR/nginx-one-acme.conf" 'return 308 https://one.example.com$request_uri;'
assert_contains "$TMP_DIR/nginx-one-acme.conf" 'location ^~ /.well-known/acme-challenge/'
assert_not_contains "$TMP_DIR/nginx-one-acme.conf" 'proxy_pass '
assert_not_contains "$TMP_DIR/nginx-one-acme.conf" 'origin.example.net'

set_domain two.example.com
two_nginx_id="$NGINX_ID"
[[ "$one_nginx_id" != "$two_nginx_id" ]] || fail "不同入口生成了相同 Nginx 短标识"
[[ "$one_nginx_id" =~ ^s[0-9a-f]{12}$ && "$two_nginx_id" =~ ^s[0-9a-f]{12}$ ]] || fail "Nginx 短标识格式错误"
write_nginx_https_config "$TMP_DIR/nginx-two.conf"
assert_contains "$TMP_DIR/nginx-two.conf" "log_format emby_proxy_${two_nginx_id}_v1"
assert_not_contains "$TMP_DIR/nginx-two.conf" "emby_proxy_${one_nginx_id}"

# 同一域名的独立 HTTPS 端口必须生成独立标识、URL、日志和监听，不重复声明 TCP 80。
ACCESS_MODE="domain"; DOMAIN_ENTRY_TYPE="port"; HTTPS_PORT="18443"; PROXY_DOMAIN="ports.example.com"
normalize_proxy_domain "$PROXY_DOMAIN"
ROUTE_PATHS=("/"); ROUTE_URLS=("https://origin.example.net"); ROUTE_HOSTS=("origin.example.net")
write_nginx_https_config "$TMP_DIR/nginx-port.conf"
assert_contains "$TMP_DIR/nginx-port.conf" '# MANAGED EMBY SITE: ports.example.com-https-18443'
assert_contains "$TMP_DIR/nginx-port.conf" 'listen 18443 ssl http2;'
assert_not_contains "$TMP_DIR/nginx-port.conf" 'listen 80;'
assert_contains "$TMP_DIR/nginx-port.conf" '"https://ports.example.com:18443/$1";'
[[ "$PUBLIC_BASE_URL" == "https://ports.example.com:18443" ]] || fail "自定义 HTTPS 端口公共 URL 错误"
[[ "$NGINX_CONFIG" == */emby-proxy-ports.example.com-https-18443.conf ]] || fail "自定义 HTTPS 端口配置文件未隔离"

: >"$TMP_DIR/Caddyfile.ports"
build_candidate_config "$TMP_DIR/Caddyfile.ports" "$TMP_DIR/Caddyfile.port-one"
HTTPS_PORT="19443"; normalize_proxy_domain "$PROXY_DOMAIN"
ROUTE_PATHS=("/"); ROUTE_URLS=("https://origin-two.example.net"); ROUTE_HOSTS=("origin-two.example.net")
build_candidate_config "$TMP_DIR/Caddyfile.port-one" "$TMP_DIR/Caddyfile.port-two"
assert_contains "$TMP_DIR/Caddyfile.port-two" 'https://ports.example.com:18443 {'
assert_contains "$TMP_DIR/Caddyfile.port-two" 'https://ports.example.com:19443 {'
assert_count "$TMP_DIR/Caddyfile.port-two" '# BEGIN MANAGED EMBY REVERSE PROXY: ports.example.com-https-' 2

# 同一 Caddy 域名的 443 与自定义端口也能并存，冲突检查不能把 :PORT 错判成 443。
HTTPS_PORT="443"; DOMAIN_ENTRY_TYPE="subdomain"; normalize_proxy_domain "$PROXY_DOMAIN"
ROUTE_URLS=("https://origin-root.example.net"); ROUTE_HOSTS=("origin-root.example.net")
build_candidate_config "$TMP_DIR/Caddyfile.port-two" "$TMP_DIR/Caddyfile.port-and-443"
assert_contains "$TMP_DIR/Caddyfile.port-and-443" 'ports.example.com {'
assert_contains "$TMP_DIR/Caddyfile.port-and-443" 'https://ports.example.com:18443 {'

# Caddy：同一 Caddyfile 可保留多个域名；重跑一个域名只替换自己的托管块。
: >"$TMP_DIR/Caddyfile.empty"
set_domain one.example.com
build_candidate_config "$TMP_DIR/Caddyfile.empty" "$TMP_DIR/Caddyfile.one"
set_domain two.example.com
ROUTE_URLS=("https://origin-two.example.net" "http://10.0.0.4:8096")
ROUTE_HOSTS=("origin-two.example.net" "10.0.0.4")
build_candidate_config "$TMP_DIR/Caddyfile.one" "$TMP_DIR/Caddyfile.two"
set_domain one.example.com
ROUTE_URLS=("https://origin-one-new.example.net" "http://10.0.0.5:8096")
ROUTE_HOSTS=("origin-one-new.example.net" "10.0.0.5")
build_candidate_config "$TMP_DIR/Caddyfile.two" "$TMP_DIR/Caddyfile.final"
assert_count "$TMP_DIR/Caddyfile.final" '# BEGIN MANAGED EMBY REVERSE PROXY: one.example.com' 1
assert_count "$TMP_DIR/Caddyfile.final" '# BEGIN MANAGED EMBY REVERSE PROXY: two.example.com' 1
assert_contains "$TMP_DIR/Caddyfile.final" 'reverse_proxy https://origin-one-new.example.net {'
assert_contains "$TMP_DIR/Caddyfile.final" 'reverse_proxy https://origin-two.example.net {'
assert_not_contains "$TMP_DIR/Caddyfile.final" 'reverse_proxy https://origin.example.net {'

# 子路径响应头改写必须先保护已有 /a 前缀，避免生成 /a/a。
assert_contains "$TMP_DIR/Caddyfile.final" 'header_down Location "^/a(?:/(.*))?$" "emby-proxy-prefix-preserved://$1"'
assert_contains "$TMP_DIR/Caddyfile.final" 'header_down Location "^emby-proxy-prefix-preserved://(.*)$" "/a/$1"'
assert_contains "$TMP_DIR/Caddyfile.final" 'header_down Content-Location "^emby-proxy-prefix-preserved://(.*)$" "/a/$1"'
assert_not_contains "$TMP_DIR/Caddyfile.final" 'reverse_proxy {'

# 上游 IPv6 仍可作为域名 HTTPS 入口的固定源站。
parse_upstream 'https://[2001:db8::20]:8443'
[[ "$UPSTREAM_URL" == 'https://[2001:db8::20]:8443' && "$UPSTREAM_HOST" == '2001:db8::20' ]] || fail "IPv6 源站解析失败"

# 旧版无域名托管标记在更新旧域名时应迁移，新域名不能把它删除。
cat >"$TMP_DIR/Caddyfile.legacy" <<'EOF'
# BEGIN MANAGED EMBY REVERSE PROXY
legacy.example.com {
    reverse_proxy https://legacy-origin.example.net
}
# END MANAGED EMBY REVERSE PROXY
EOF
set_domain fresh.example.com
build_candidate_config "$TMP_DIR/Caddyfile.legacy" "$TMP_DIR/Caddyfile.legacy-plus-new"
assert_contains "$TMP_DIR/Caddyfile.legacy-plus-new" '# BEGIN MANAGED EMBY REVERSE PROXY'
assert_contains "$TMP_DIR/Caddyfile.legacy-plus-new" 'legacy.example.com {'
set_domain legacy.example.com
ROUTE_URLS=("https://legacy-new.example.net" "http://10.0.0.6:8096")
ROUTE_HOSTS=("legacy-new.example.net" "10.0.0.6")
build_candidate_config "$TMP_DIR/Caddyfile.legacy-plus-new" "$TMP_DIR/Caddyfile.legacy-migrated"
assert_count "$TMP_DIR/Caddyfile.legacy-migrated" '# BEGIN MANAGED EMBY REVERSE PROXY' 2
assert_count "$TMP_DIR/Caddyfile.legacy-migrated" '# BEGIN MANAGED EMBY REVERSE PROXY: legacy.example.com' 1
assert_not_contains "$TMP_DIR/Caddyfile.legacy-migrated" 'reverse_proxy https://legacy-origin.example.net'

# 已有手工 Caddy 域名：定位唯一站点块，只插入非根路径，并可幂等更新同一路径。
existing_dir="$TMP_DIR/existing-caddy"
mkdir -p "$existing_dir"
cat >"$existing_dir/Caddyfile" <<'EOF'
{
    email admin@example.com
}

existing.example.com {
    encode gzip
    respond "original-site" 200
}
EOF
PROXY_DOMAIN=existing.example.com
normalize_proxy_domain "$PROXY_DOMAIN"
CADDY_SCAN_ROOT="$existing_dir"
locate_existing_caddy_site || fail "未定位到已有 Caddy 站点"
[[ "$CADDY_EXISTING_SITE_FILE" == "$existing_dir/Caddyfile" ]] || fail "定位到了错误的 Caddy 文件"
ROUTE_PATHS=("/media")
ROUTE_URLS=("https://media-origin.example.net")
ROUTE_HOSTS=("media-origin.example.net")
check_existing_caddy_route_conflict /media
build_existing_caddy_candidate "$CADDY_EXISTING_SITE_FILE" "$existing_dir/with-route.caddy"
assert_contains "$existing_dir/with-route.caddy" 'respond "original-site" 200'
assert_contains "$existing_dir/with-route.caddy" '# BEGIN MANAGED EMBY EXISTING ROUTE: existing.example.com /media'
assert_contains "$existing_dir/with-route.caddy" 'handle /media/_emby_proxy_health {'
assert_contains "$existing_dir/with-route.caddy" 'handle_path /media/* {'

location="$(find_caddy_site_in_file "$existing_dir/with-route.caddy" "$PROXY_DOMAIN")"
CADDY_EXISTING_SITE_FILE="$existing_dir/with-route.caddy"
CADDY_EXISTING_SITE_OPEN_LINE="${location%%$'\t'*}"
CADDY_EXISTING_SITE_CLOSE_LINE="${location##*$'\t'}"
ROUTE_URLS=("https://media-origin-new.example.net")
ROUTE_HOSTS=("media-origin-new.example.net")
check_existing_caddy_route_conflict /media
build_existing_caddy_candidate "$CADDY_EXISTING_SITE_FILE" "$existing_dir/updated.caddy"
assert_count "$existing_dir/updated.caddy" '# BEGIN MANAGED EMBY EXISTING ROUTE: existing.example.com /media' 1
assert_contains "$existing_dir/updated.caddy" 'reverse_proxy https://media-origin-new.example.net {'
assert_not_contains "$existing_dir/updated.caddy" 'reverse_proxy https://media-origin.example.net {'

# 已有路径发生重叠时必须拒绝，不能覆盖手工路由。
conflict_dir="$TMP_DIR/conflict-caddy"
mkdir -p "$conflict_dir"
cat >"$conflict_dir/Caddyfile" <<'EOF'
existing.example.com {
    handle_path /taken/* {
        reverse_proxy http://127.0.0.1:8096
    }
}
EOF
if SCRIPT_UNDER_TEST="$SCRIPT" CADDY_SCAN_ROOT="$conflict_dir" EMBY_PROXY_LIB_ONLY=1 bash -c '
  set --
  source "$SCRIPT_UNDER_TEST"
  PROXY_DOMAIN=existing.example.com
  normalize_proxy_domain "$PROXY_DOMAIN"
  locate_existing_caddy_site
  check_existing_caddy_route_conflict /taken/sub
' >/dev/null 2>&1; then
  fail "重叠的已有 Caddy 路径未被拒绝"
fi
unset CADDY_SCAN_ROOT

# 若本机有 Caddy，再执行官方适配器的完整配置验证。
if command -v caddy >/dev/null 2>&1; then
  validation_dir="$TMP_DIR/caddy-validation"
  mkdir -p "$validation_dir"
  sed "s#/var/log/caddy/emby-proxy-[^ ]*-access.log#$validation_dir/access.log#g" \
    "$TMP_DIR/Caddyfile.final" >"$validation_dir/Caddyfile"
  caddy adapt --config "$validation_dir/Caddyfile" --adapter caddyfile --validate >/dev/null
  caddy adapt --config "$existing_dir/updated.caddy" --adapter caddyfile --validate >/dev/null
  sed "s#/var/log/caddy/emby-proxy-ip-[^ ]*-access.log#$validation_dir/ip-access.log#g" \
    "$TMP_DIR/Caddyfile.ip" >"$validation_dir/Caddyfile.ip"
  caddy adapt --config "$validation_dir/Caddyfile.ip" --adapter caddyfile --validate >/dev/null
fi

printf 'PASS: domain HTTPS only, existing-site path attach, multi-domain isolation, ACME-only HTTP, XFF hardening, idempotent rewrites\n'
