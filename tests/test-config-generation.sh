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

# 域名冲突检测按完整 token 匹配，不能把 a.example.com 错认成 ba.example.com。
domain_pattern="$(domain_token_regex 'a.example.com')"
printf '%s\n' 'ba.example.com {' | grep -E "$domain_pattern" >/dev/null && fail "域名 token 匹配出现子串误判"
printf '%s\n' 'a.example.com {' | grep -E "$domain_pattern" >/dev/null || fail "域名 token 未匹配完整域名"

set_domain() {
  PROXY_DOMAIN="$1"
  normalize_proxy_domain "$PROXY_DOMAIN"
  ROUTE_PATHS=("/" "/a")
  ROUTE_URLS=("https://origin.example.net" "http://10.0.0.3:8096")
  ROUTE_HOSTS=("origin.example.net" "10.0.0.3")
}

# Nginx：正式配置固定上游、拒绝伪造 XFF，并为每个域名使用唯一变量。
set_domain one.example.com
write_nginx_https_config "$TMP_DIR/nginx-one.conf"
write_nginx_http_config "$TMP_DIR/nginx-one-acme.conf"
assert_contains "$TMP_DIR/nginx-one.conf" 'proxy_set_header X-Forwarded-For $remote_addr;'
assert_not_contains "$TMP_DIR/nginx-one.conf" '$proxy_add_x_forwarded_for'
assert_contains "$TMP_DIR/nginx-one.conf" '$emby_connection_upgrade_one_dot_example_dot_com'
assert_contains "$TMP_DIR/nginx-one.conf" '"~*^/a(?:/|$)" $upstream_http_location;'
assert_contains "$TMP_DIR/nginx-one.conf" 'add_header Location $emby_proxy_location_one_dot_example_dot_com_1 always;'
assert_not_contains "$TMP_DIR/nginx-one.conf" 'proxy_pass $'

# 证书申请阶段只能处理 ACME；不能在 80 端口临时暴露 Emby。
assert_contains "$TMP_DIR/nginx-one-acme.conf" 'return 503 "HTTPS certificate is being provisioned";'
assert_contains "$TMP_DIR/nginx-one-acme.conf" 'location ^~ /.well-known/acme-challenge/'
assert_not_contains "$TMP_DIR/nginx-one-acme.conf" 'proxy_pass '
assert_not_contains "$TMP_DIR/nginx-one-acme.conf" 'origin.example.net'

set_domain two.example.com
write_nginx_https_config "$TMP_DIR/nginx-two.conf"
assert_contains "$TMP_DIR/nginx-two.conf" 'log_format emby_proxy_two_dot_example_dot_com_v1'
assert_not_contains "$TMP_DIR/nginx-two.conf" 'emby_proxy_one_dot_example_dot_com'

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

# 若本机有 Caddy，再执行官方适配器的完整配置验证。
if command -v caddy >/dev/null 2>&1; then
  validation_dir="$TMP_DIR/caddy-validation"
  mkdir -p "$validation_dir"
  sed "s#/var/log/caddy/emby-proxy-[^ ]*-access.log#$validation_dir/access.log#g" \
    "$TMP_DIR/Caddyfile.final" >"$validation_dir/Caddyfile"
  caddy adapt --config "$validation_dir/Caddyfile" --adapter caddyfile --validate >/dev/null
fi

printf 'PASS: config generation, multi-domain isolation, ACME-only HTTP, XFF hardening, idempotent rewrites\n'
