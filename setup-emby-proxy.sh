#!/usr/bin/env bash
# 在 Debian/Ubuntu VPS 上安装 Caddy 或 Nginx，并为 Emby 配置域名 HTTPS 或 IP HTTP 反向代理。

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
readonly CADDYFILE="/etc/caddy/Caddyfile"
readonly BEGIN_MARKER="# BEGIN MANAGED EMBY REVERSE PROXY"
readonly END_MARKER="# END MANAGED EMBY REVERSE PROXY"
readonly NGINX_LEGACY_CONFIG="/etc/nginx/conf.d/emby-proxy-managed.conf"
readonly NGINX_ACME_ROOT="/var/www/emby-proxy-acme"
readonly NGINX_DEFAULT_SITE_LINK="${EMBY_PROXY_NGINX_DEFAULT_SITE_LINK:-/etc/nginx/sites-enabled/default}"
readonly NGINX_HASH_CONFIG="${EMBY_PROXY_NGINX_HASH_CONFIG:-/etc/nginx/conf.d/00-emby-proxy-hash.conf}"
readonly HEALTH_PATH="/_emby_proxy_health"
readonly MANAGER_COMMAND_URL="https://raw.githubusercontent.com/wuuduf/emby-reverse-proxy-installer/main/emby-proxy"
readonly MANAGER_HOME="${EMBY_PROXY_STATE_HOME:-/etc/emby-proxy}"
readonly MANAGER_LIBEXEC="${EMBY_PROXY_LIBEXEC:-/usr/local/lib/emby-proxy}"
readonly MANAGER_BIN="${EMBY_PROXY_MANAGER_BIN:-/usr/local/sbin/emby-proxy}"

PROXY_ENGINE=""
MANAGER_ONLY=0
BOOTSTRAP_MENU=0
ENTRY_WIZARD=0
SHOW_UNSAFE_IP_MODE="${EMBY_PROXY_SHOW_UNSAFE_IP_MODE:-0}"
ACCESS_MODE=""
ACCESS_SCHEME=""
PROXY_IP=""
LISTEN_PORT=""
HTTPS_PORT=""
DOMAIN_ENTRY_TYPE=""
PUBLIC_AUTHORITY=""
PUBLIC_BASE_URL=""
PROXY_KEY=""
USING_EXISTING_SERVICE=0
HAS_CADDY=0
HAS_NGINX=0
CADDY_ACTIVE=0
NGINX_ACTIVE=0
PROXY_DOMAIN=""
PRIMARY_ROUTE_INPUT=""
UPSTREAM_INPUT=""
UPSTREAM_URL=""
UPSTREAM_HOST=""
BACKUP_FILE=""
NGINX_HAD_CONFIG=0
NGINX_NEWLY_INSTALLED=0
NGINX_DEFAULT_DISABLED=0
NGINX_DEFAULT_LINK_TARGET=""
NGINX_ID=""
NGINX_CONFIG=""
NGINX_ACME_CONFIG=""
NGINX_ACME_CREATED=0
NGINX_HASH_CONFIG_CREATED=0
CADDY_ACCESS_LOG=""
NGINX_ACCESS_LOG=""
CADDY_ATTACH_EXISTING=0
CADDY_EXISTING_SITE_FILE=""
CADDY_EXISTING_SITE_OPEN_LINE=0
CADDY_EXISTING_SITE_CLOSE_LINE=0
declare -a ROUTE_SPECS=()
declare -a ROUTE_PATHS=()
declare -a ROUTE_INPUTS=()
declare -a ROUTE_URLS=()
declare -a ROUTE_HOSTS=()
LOCK_FD=""

# 无参数运行下载的一键脚本时，只初始化长期管理命令并进入菜单。
# 真正新增入口由菜单显式传入内部参数 --entry-wizard，避免首次安装直接掉进配置向导。
(($# == 0)) && BOOTSTRAP_MENU=1

if [[ -t 1 ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

info()  { printf '%s[信息]%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()    { printf '%s[成功]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()  { printf '%s[提醒]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
error() { printf '%s[错误]%s %s\n' "$RED" "$RESET" "$*" >&2; }
die()   { error "$*"; exit 1; }

usage() {
  cat <<EOF
用法：
  sudo ./${SCRIPT_NAME}
  sudo ./${SCRIPT_NAME} --manager-only
  sudo ./${SCRIPT_NAME} --engine nginx --domain emby.example.com --upstream origin.example.com
  sudo ./${SCRIPT_NAME} --engine nginx --domain emby.example.com --https-port 18443 --upstream origin.example.com
  sudo ./${SCRIPT_NAME} --show-unsafe-ip-mode --engine caddy --mode ip --listen-port 8080 --upstream origin.example.com

选项：
  -e, --engine ENGINE       反代程序：caddy 或 nginx；不填写时交互选择
      --manager-only        只安装 emby-proxy 管理命令并导入旧配置，不新增反代
      --show-unsafe-ip-mode 显示/允许“公网 IP + 明文 HTTP”模式；默认隐藏
  -m, --mode MODE           访问模式：domain（域名 HTTPS）或 ip（公网 IPv4 + HTTP）
  -d, --domain DOMAIN       对外访问的反代域名（必须已解析到本 VPS）
  -i, --ip-address IPV4     IP 模式的对外访问 IPv4；不填写时自动检测公网 IPv4
  -l, --listen-port PORT    IP 模式的独立 HTTP 端口，默认 8080（范围 1024-65535）
      --https-port PORT     域名模式的 HTTPS 端口，默认 443；自定义范围 1024-65535
      --domain-mode MODE    域名入口：subdomain、port 或 path
  -p, --path PATH           主源站的访问路径，默认 /；已有 Caddy 域名必须填写非根路径
  -u, --upstream ADDRESS    Emby 源站域名或 URL，可带端口
                            例如 origin.example.com、https://origin.example.com、http://1.2.3.4:8096
  -r, --route PATH=ADDRESS  增加一个路径源站，可重复使用；例如 /a=https://emby-a.example.com
  -h, --help                显示帮助

只输入源站域名时，脚本会先探测 HTTPS，失败后再探测 HTTP；不会关闭 TLS 证书验证。
EOF
}

while (($#)); do
  case "$1" in
    -e|--engine)
      [[ $# -ge 2 ]] || die "$1 缺少参数。"
      PROXY_ENGINE="$2"; shift 2 ;;
    --manager-only)
      MANAGER_ONLY=1; shift ;;
    --entry-wizard)
      ENTRY_WIZARD=1; BOOTSTRAP_MENU=0; shift ;;
    --show-unsafe-ip-mode|--allow-insecure-ip)
      SHOW_UNSAFE_IP_MODE=1; shift ;;
    -m|--mode)
      [[ $# -ge 2 ]] || die "$1 缺少参数。"
      ACCESS_MODE="$2"; shift 2 ;;
    -d|--domain)
      [[ $# -ge 2 ]] || die "$1 缺少参数。"
      PROXY_DOMAIN="$2"; shift 2 ;;
    -i|--ip-address)
      [[ $# -ge 2 ]] || die "$1 缺少参数。"
      PROXY_IP="$2"; shift 2 ;;
    -l|--listen-port)
      [[ $# -ge 2 ]] || die "$1 缺少参数。"
      LISTEN_PORT="$2"; shift 2 ;;
    --https-port)
      [[ $# -ge 2 ]] || die "$1 缺少参数。"
      HTTPS_PORT="$2"; shift 2 ;;
    --domain-mode)
      [[ $# -ge 2 ]] || die "$1 缺少参数。"
      DOMAIN_ENTRY_TYPE="$2"; shift 2 ;;
    -p|--path)
      [[ $# -ge 2 ]] || die "$1 缺少参数。"
      PRIMARY_ROUTE_INPUT="$2"; shift 2 ;;
    -u|--upstream)
      [[ $# -ge 2 ]] || die "$1 缺少参数。"
      UPSTREAM_INPUT="$2"; shift 2 ;;
    -r|--route)
      [[ $# -ge 2 ]] || die "$1 缺少参数。"
      ROUTE_SPECS+=("$2"); shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "未知参数：$1（使用 --help 查看帮助）" ;;
  esac
done

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    local -a sudo_args=()
    command -v sudo >/dev/null 2>&1 || die "请切换到 root 后重新运行：su -c 'bash ${SCRIPT_NAME}'"
    info "需要管理员权限，正在通过 sudo 重新运行……"
    [[ -n "$PROXY_ENGINE" ]] && sudo_args+=(--engine "$PROXY_ENGINE")
    (( MANAGER_ONLY )) && sudo_args+=(--manager-only)
    (( ENTRY_WIZARD )) && sudo_args+=(--entry-wizard)
    case "$SHOW_UNSAFE_IP_MODE" in 1|true|TRUE|yes|YES|on|ON) sudo_args+=(--show-unsafe-ip-mode) ;; esac
    [[ -n "$ACCESS_MODE" ]] && sudo_args+=(--mode "$ACCESS_MODE")
    [[ -n "$PROXY_DOMAIN" ]] && sudo_args+=(--domain "$PROXY_DOMAIN")
    [[ -n "$PROXY_IP" ]] && sudo_args+=(--ip-address "$PROXY_IP")
    [[ -n "$LISTEN_PORT" ]] && sudo_args+=(--listen-port "$LISTEN_PORT")
    [[ -n "$HTTPS_PORT" ]] && sudo_args+=(--https-port "$HTTPS_PORT")
    [[ -n "$DOMAIN_ENTRY_TYPE" ]] && sudo_args+=(--domain-mode "$DOMAIN_ENTRY_TYPE")
    [[ -n "$PRIMARY_ROUTE_INPUT" ]] && sudo_args+=(--path "$PRIMARY_ROUTE_INPUT")
    [[ -n "$UPSTREAM_INPUT" ]] && sudo_args+=(--upstream "$UPSTREAM_INPUT")
    local route_spec
    for route_spec in "${ROUTE_SPECS[@]}"; do
      sudo_args+=(--route "$route_spec")
    done
    exec sudo -- "$SCRIPT_PATH" "${sudo_args[@]}"
  fi
}

acquire_operation_lock() {
  command -v flock >/dev/null 2>&1 || return 0
  mkdir -p /run/lock
  exec {LOCK_FD}>/run/lock/emby-proxy.lock
  flock -n "$LOCK_FD" || die "另一个 emby-proxy 配置任务正在运行，请等待它完成后重试。"
}

release_operation_lock() {
  [[ -n "$LOCK_FD" ]] || return 0
  flock -u "$LOCK_FD" 2>/dev/null || true
  eval "exec ${LOCK_FD}>&-"
  LOCK_FD=""
}

check_platform() {
  [[ -r /etc/os-release ]] || die "无法识别系统：缺少 /etc/os-release。仅支持采用 apt + systemd 的 Debian/Ubuntu。"
  # shellcheck disable=SC1091
  source /etc/os-release
  local family="${ID:-} ${ID_LIKE:-}"
  [[ " $family " == *" debian "* || " $family " == *" ubuntu "* ]] || \
    die "当前系统为 ${PRETTY_NAME:-未知}。此脚本仅支持 Debian/Ubuntu 及其兼容发行版。"
  command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get。"
  command -v systemctl >/dev/null 2>&1 || die "未找到 systemd/systemctl；容器或非 systemd 系统不能使用此脚本。"
  [[ "$(uname -m)" =~ ^(x86_64|aarch64|armv7l|armv6l)$ ]] || warn "架构 $(uname -m) 可能没有可用的 Caddy/Nginx 软件包。"
  ok "系统检查通过：${PRETTY_NAME:-$ID} / $(uname -m)"
}

trim() {
  local value="$*"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

valid_domain() {
  local d="$1"
  [[ ${#d} -le 253 ]] &&
    [[ "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

valid_ipv4() {
  local value="$1" octet
  local -a octets=()
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"$value"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
  done
}

normalize_access_mode() {
  ACCESS_MODE="$(printf '%s' "$(trim "$ACCESS_MODE")" | tr '[:upper:]' '[:lower:]')"
  case "$ACCESS_MODE" in
    1|domain|https) ACCESS_MODE="domain" ;;
    2|ip|http) ACCESS_MODE="ip" ;;
    *) die "访问模式只能选择 1/domain 或 2/ip。" ;;
  esac
}

normalize_unsafe_ip_visibility() {
  SHOW_UNSAFE_IP_MODE="$(printf '%s' "$(trim "$SHOW_UNSAFE_IP_MODE")" | tr '[:upper:]' '[:lower:]')"
  case "$SHOW_UNSAFE_IP_MODE" in
    1|true|yes|on) SHOW_UNSAFE_IP_MODE=1 ;;
    0|false|no|off|"") SHOW_UNSAFE_IP_MODE=0 ;;
    *) die "EMBY_PROXY_SHOW_UNSAFE_IP_MODE 只能是 0/1 或 true/false。" ;;
  esac
}

require_unsafe_ip_opt_in() {
  if [[ "$ACCESS_MODE" == "ip" && "$SHOW_UNSAFE_IP_MODE" != "1" ]]; then
    die "IP 模式是明文 HTTP，默认已禁用。若确认接受凭据和媒体流未加密的风险，请显式添加 --show-unsafe-ip-mode。"
  fi
}

normalize_listen_port() {
  LISTEN_PORT="$(trim "${LISTEN_PORT:-8080}")"
  [[ "$LISTEN_PORT" =~ ^[0-9]{1,5}$ ]] || die "监听端口必须是数字：$LISTEN_PORT"
  ((10#$LISTEN_PORT >= 1024 && 10#$LISTEN_PORT <= 65535)) || \
    die "为避免影响现有 Web 服务，IP 模式只使用 1024-65535 的独立端口。"
  LISTEN_PORT="$((10#$LISTEN_PORT))"
}

normalize_https_port() {
  HTTPS_PORT="$(trim "${HTTPS_PORT:-443}")"
  [[ "$HTTPS_PORT" =~ ^[0-9]{1,5}$ ]] || die "HTTPS 监听端口必须是数字：$HTTPS_PORT"
  HTTPS_PORT="$((10#$HTTPS_PORT))"
  if [[ "$HTTPS_PORT" != "443" ]] && ((HTTPS_PORT < 1024 || HTTPS_PORT > 65535)); then
    die "域名自定义 HTTPS 端口只允许 1024-65535；标准 HTTPS 请使用 443。"
  fi
}

normalize_domain_entry_type() {
  DOMAIN_ENTRY_TYPE="$(printf '%s' "$(trim "${DOMAIN_ENTRY_TYPE:-}")" | tr '[:upper:]' '[:lower:]')"
  case "$DOMAIN_ENTRY_TYPE" in
    "")
      if [[ -n "$HTTPS_PORT" && "$HTTPS_PORT" != "443" ]]; then DOMAIN_ENTRY_TYPE="port"
      elif [[ -n "$PRIMARY_ROUTE_INPUT" || ${#ROUTE_SPECS[@]} -gt 0 ]]; then DOMAIN_ENTRY_TYPE="path"
      else DOMAIN_ENTRY_TYPE="subdomain"; fi ;;
    1|subdomain|domain|standard) DOMAIN_ENTRY_TYPE="subdomain" ;;
    2|port|https-port) DOMAIN_ENTRY_TYPE="port" ;;
    3|path|paths) DOMAIN_ENTRY_TYPE="path" ;;
    *) die "域名入口类型只能是 subdomain、port 或 path。" ;;
  esac
}

set_nginx_id() {
  local value="$1" hash
  if command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$value" | sha256sum | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    hash="$(printf '%s' "$value" | shasum -a 256 | awk '{print $1}')"
  else
    die "缺少 sha256sum/shasum，无法生成安全的 Nginx 入口标识。"
  fi
  NGINX_ID="s${hash:0:12}"
}

set_ip_access_target() {
  PROXY_IP="$(trim "$PROXY_IP")"
  if [[ -z "$PROXY_IP" ]]; then
    info "正在检测本机公网 IPv4……"
    PROXY_IP="$(public_ip 4 -4 https://api.ipify.org)"
    [[ -n "$PROXY_IP" ]] || die "无法自动检测公网 IPv4，请重新运行并使用 --ip-address 1.2.3.4 指定。"
  fi
  valid_ipv4 "$PROXY_IP" || die "访问 IPv4 格式无效：$PROXY_IP"
  normalize_listen_port
  PROXY_DOMAIN="$PROXY_IP"
  ACCESS_SCHEME="http"
  PUBLIC_AUTHORITY="${PROXY_IP}:${LISTEN_PORT}"
  PUBLIC_BASE_URL="http://${PUBLIC_AUTHORITY}"
  PROXY_KEY="ip-${PROXY_IP}-${LISTEN_PORT}"
  set_nginx_id "$PROXY_KEY"
  NGINX_CONFIG="/etc/nginx/conf.d/emby-proxy-${PROXY_KEY}.conf"
  CADDY_ACCESS_LOG="/var/log/caddy/emby-proxy-${PROXY_KEY}-access.log"
  NGINX_ACCESS_LOG="/var/log/nginx/emby-proxy-${PROXY_KEY}-access.log"
  ok "IP 访问入口：$PUBLIC_BASE_URL"
  warn "IP HTTP 模式不提供传输加密；登录凭据和媒体流会以明文经过客户端到本 VPS 的网络。"
}

domain_token_regex() {
  local escaped="${1//./\\.}"
  printf '(^|[^A-Za-z0-9.-])%s([^A-Za-z0-9.-]|$)' "$escaped"
}

normalize_proxy_domain() {
  local value
  value="$(trim "$1")"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%/}"
  value="${value%.}"
  [[ "$value" != */* && "$value" != *:* && "$value" != *\?* && "$value" != *\#* && "$value" != *@* ]] || \
    die "反代访问地址只能填写域名，不能带端口、路径、参数或账号信息。"
  valid_domain "$value" || die "反代域名格式无效：${value}（示例：emby.example.com）"
  PROXY_DOMAIN="$value"
  normalize_https_port
  ACCESS_SCHEME="https"
  if [[ "$HTTPS_PORT" == "443" ]]; then
    PUBLIC_AUTHORITY="$PROXY_DOMAIN"
    PROXY_KEY="$PROXY_DOMAIN"
    NGINX_CONFIG="/etc/nginx/conf.d/emby-proxy-${PROXY_DOMAIN}.conf"
    CADDY_ACCESS_LOG="/var/log/caddy/emby-proxy-${PROXY_DOMAIN}-access.log"
    NGINX_ACCESS_LOG="/var/log/nginx/emby-proxy-${PROXY_DOMAIN}-access.log"
  else
    PUBLIC_AUTHORITY="${PROXY_DOMAIN}:${HTTPS_PORT}"
    PROXY_KEY="${PROXY_DOMAIN}-https-${HTTPS_PORT}"
    NGINX_CONFIG="/etc/nginx/conf.d/emby-proxy-${PROXY_DOMAIN}-https-${HTTPS_PORT}.conf"
    CADDY_ACCESS_LOG="/var/log/caddy/emby-proxy-${PROXY_KEY}-access.log"
    NGINX_ACCESS_LOG="/var/log/nginx/emby-proxy-${PROXY_KEY}-access.log"
  fi
  PUBLIC_BASE_URL="https://$PUBLIC_AUTHORITY"
  # 稳定短哈希既隔离不同入口，也避免长域名/IP+端口使 Nginx variables_hash 超出默认桶大小。
  set_nginx_id "$PROXY_KEY"
  NGINX_ACME_CONFIG="/etc/nginx/conf.d/emby-proxy-acme-${PROXY_DOMAIN}.conf"
}

parse_upstream() {
  local raw scheme authority host host_lower port
  raw="$(trim "$1")"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  [[ -n "$raw" ]] || die "源站地址不能为空。"
  raw="${raw%/}"

  if [[ "$raw" == http://* ]]; then
    scheme="http"; authority="${raw#http://}"
  elif [[ "$raw" == https://* ]]; then
    scheme="https"; authority="${raw#https://}"
  elif [[ "$raw" == *://* ]]; then
    die "源站只支持 http:// 或 https://。"
  else
    scheme=""; authority="$raw"
  fi

  [[ -n "$authority" && "$authority" != */* && "$authority" != *\?* && "$authority" != *\#* && "$authority" != *@* ]] || \
    die "源站只能包含协议、主机名和端口，不能带路径、查询参数或账号信息。"
  [[ "$authority" =~ ^[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] || \
    die "源站格式无效：${authority}（示例：https://origin.example.com 或 http://1.2.3.4:8096）"

  host="${authority%%:*}"
  port=""
  [[ "$authority" == *:* ]] && port="${authority##*:}"
  if [[ -n "$port" ]] && ((10#$port < 1 || 10#$port > 65535)); then
    die "源站端口超出 1-65535 范围：$port"
  fi
  [[ "$host" =~ ^[A-Za-z0-9.-]+$ && "$host" != .* && "$host" != *. && "$host" != *..* ]] || die "源站主机名无效：$host"
  host_lower="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  if [[ "$host_lower" == "$PROXY_DOMAIN" ]]; then
    if [[ "$ACCESS_MODE" == "domain" ]]; then
      die "源站域名不能与反代域名相同，否则会形成代理循环。"
    elif [[ -n "$port" && "$port" == "$LISTEN_PORT" ]]; then
      die "源站不能指向当前 IP 入口的同一端口 ${LISTEN_PORT}，否则会形成代理循环。"
    fi
  fi
  UPSTREAM_HOST="$host_lower"

  if [[ -n "$scheme" ]]; then
    UPSTREAM_URL="${scheme}://${authority}"
  else
    UPSTREAM_URL="$authority" # 由 probe_upstream 自动补全协议
  fi
}

normalize_engine_choice() {
  PROXY_ENGINE="$(printf '%s' "$(trim "$PROXY_ENGINE")" | tr '[:upper:]' '[:lower:]')"
  case "$PROXY_ENGINE" in
    1|caddy) PROXY_ENGINE="caddy" ;;
    2|nginx|ngix|nigix) PROXY_ENGINE="nginx" ;;
    *) die "反代程序只能选择 1/caddy 或 2/nginx。" ;;
  esac
}

detect_existing_services() {
  if command -v caddy >/dev/null 2>&1 && systemctl cat caddy.service >/dev/null 2>&1; then
    HAS_CADDY=1
    systemctl is-active --quiet caddy && CADDY_ACTIVE=1 || true
  fi
  if command -v nginx >/dev/null 2>&1 && systemctl cat nginx.service >/dev/null 2>&1; then
    HAS_NGINX=1
    systemctl is-active --quiet nginx && NGINX_ACTIVE=1 || true
  fi

  info "现有反代服务预检："
  if (( HAS_CADDY )); then
    printf '  - Caddy：已安装，服务%s，版本 %s\n' \
      "$([[ $CADDY_ACTIVE -eq 1 ]] && printf '运行中' || printf '未运行')" \
      "$(caddy version 2>/dev/null || printf '未知')"
  else
    printf '  - Caddy：未检测到\n'
  fi
  if (( HAS_NGINX )); then
    printf '  - Nginx：已安装，服务%s，%s\n' \
      "$([[ $NGINX_ACTIVE -eq 1 ]] && printf '运行中' || printf '未运行')" \
      "$(nginx -v 2>&1 || printf '版本未知')"
  else
    printf '  - Nginx：未检测到\n'
  fi
}

confirm_existing_service() {
  local engine="$1" answer=""
  PROXY_ENGINE="$engine"
  if [[ ! -t 0 ]]; then
    die "检测到现有 $engine 服务。非交互运行时请显式添加 --engine ${engine}，确认在原服务上新增独立站点。"
  fi
  printf '\n检测到现有 %s。是否在其原配置基础上新增 Emby 反代域名或路径？[Y/n]：' "$engine"
  read -r answer
  if [[ "$answer" =~ ^[Nn]$ ]]; then
    die "已取消。为避免影响现有服务，脚本不会自动改用另一套 Web 服务。"
  fi
  USING_EXISTING_SERVICE=1
  ok "将使用现有 ${engine}，并仅写入脚本托管的独立站点配置。"
}

select_proxy_engine() {
  local requested="$PROXY_ENGINE" choice=""
  [[ -z "$requested" ]] || normalize_engine_choice
  requested="$PROXY_ENGINE"
  detect_existing_services

  # 两种服务同时运行时，无法保证端口及默认站点互不影响，因此拒绝自动修改。
  if (( CADDY_ACTIVE && NGINX_ACTIVE )); then
    die "检测到 Caddy 与 Nginx 同时运行。为保证不影响现有服务，脚本已停止；请先确认实际入口和 80/443 监听关系。"
  fi

  # 若只有一种服务正在运行，必须复用它，不能悄悄安装竞争 80/443 的另一种服务。
  if (( CADDY_ACTIVE )); then
    if [[ -n "$requested" && "$requested" != "caddy" ]]; then
      die "Caddy 正在运行，不能在不影响原服务的前提下改装 Nginx。请使用 --engine caddy，或先人工规划迁移。"
    fi
    if [[ -n "$requested" ]]; then
      PROXY_ENGINE="caddy"; USING_EXISTING_SERVICE=1
      ok "已确认在现有 Caddy 上新增独立反代站点。"
    else
      confirm_existing_service caddy
    fi
    return
  fi
  if (( NGINX_ACTIVE )); then
    if [[ -n "$requested" && "$requested" != "nginx" ]]; then
      die "Nginx 正在运行，不能在不影响原服务的前提下改装 Caddy。请使用 --engine nginx，或先人工规划迁移。"
    fi
    if [[ -n "$requested" ]]; then
      PROXY_ENGINE="nginx"; USING_EXISTING_SERVICE=1
      ok "已确认在现有 Nginx 上新增独立反代站点。"
    else
      confirm_existing_service nginx
    fi
    return
  fi

  # 已安装但未运行：仍优先让用户确认复用，只有两者都不存在时才显示全新安装选择。
  if (( HAS_CADDY + HAS_NGINX == 1 )); then
    local existing="caddy"
    (( HAS_NGINX )) && existing="nginx"
    if [[ -n "$requested" && "$requested" != "$existing" ]]; then
      die "已检测到现有 ${existing}。为避免改动两套 Web 服务，请复用它，或先人工卸载/迁移后重试。"
    fi
    if [[ -n "$requested" ]]; then
      PROXY_ENGINE="$existing"; USING_EXISTING_SERVICE=1
      ok "已确认在现有 $existing 上新增独立反代站点。"
    else
      confirm_existing_service "$existing"
    fi
    return
  fi

  if (( HAS_CADDY && HAS_NGINX )); then
    if [[ -n "$requested" ]]; then
      PROXY_ENGINE="$requested"; USING_EXISTING_SERVICE=1
      ok "两种服务均已安装但未运行，将按参数复用现有 ${PROXY_ENGINE}。"
      return
    fi
    [[ -t 0 ]] || die "Caddy 与 Nginx 均已安装但未运行；请用 --engine 明确选择要复用的服务。"
    printf '\n两种服务均已安装但未运行，请选择要在原配置基础上使用的服务：\n'
    printf '  1) Caddy\n  2) Nginx\n请输入 1 或 2：'
    read -r choice
    PROXY_ENGINE="$choice"
    normalize_engine_choice
    USING_EXISTING_SERVICE=1
    ok "将复用现有 ${PROXY_ENGINE}。"
    return
  fi

  # 只有此处（两种服务均不存在）才让用户自由选择安装哪一种。
  if [[ -z "$requested" ]]; then
    [[ -t 0 ]] || die "未检测到 Caddy/Nginx。非交互环境请使用 --engine、--domain 和 --upstream。"
    printf '\n未检测到 Caddy 或 Nginx，请选择要安装的反代程序：\n'
    printf '  1) Caddy（配置简单，自动管理 HTTPS 证书）\n'
    printf '  2) Nginx（使用 Certbot 管理 HTTPS 证书）\n'
    printf '请输入 1 或 2（默认 1）：'
    read -r PROXY_ENGINE
    PROXY_ENGINE="${PROXY_ENGINE:-1}"
    normalize_engine_choice
  else
    PROXY_ENGINE="$requested"
  fi
}

# 输出“起始行<TAB>结束行”。只接受顶层、显式写出域名且结束大括号独占一行的站点块；
# 复杂或无法唯一定位的配置一律不自动修改。
find_caddy_site_in_file() {
  local source_file="$1" domain="$2"
  awk -v wanted="$domain" '
    function structural(s,    i,ch,q,esc,out) {
      line_opens=0; line_closes=0; q=""; esc=0; out=""
      for (i=1; i<=length(s); i++) {
        ch=substr(s,i,1)
        if (q != "") {
          if (esc) { esc=0; continue }
          if (ch == "\\" && q == "\"") { esc=1; continue }
          if (ch == q) q=""
          continue
        }
        if (ch == "#") break
        if (ch == "\"" || ch == "`") { q=ch; continue }
        out=out ch
        if (ch == "{") line_opens++
        else if (ch == "}") line_closes++
      }
      return out
    }
    function trim(s) { sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); return s }
    function header_has_domain(header,    n,i,a,t) {
      gsub(/,/," ",header)
      n=split(header,a,/[[:space:]]+/)
      for (i=1; i<=n; i++) {
        t=a[i]
        sub(/^https?:\/\//,"",t)
        sub(/:[0-9]+$/,"",t)
        if (t == wanted) return 1
      }
      return 0
    }
    {
      clean=structural($0)
      before=depth
      if (!found && before == 0 && line_opens > 0) {
        header=clean
        sub(/\{.*/,"",header)
        header=trim(header)
        if (header_has_domain(header)) { found=1; start=NR }
      }
      depth += line_opens-line_closes
      if (found && depth == 0) {
        closing=clean
        closing=trim(closing)
        if (start == NR || closing != "}") exit 4
        print start "\t" NR
        exit
      }
      if (depth < 0) exit 5
    }
    END { if (found && depth != 0) exit 6 }
  ' "$source_file"
}

caddy_domain_is_script_managed() {
  local domain_begin legacy_domain
  [[ -f "$CADDYFILE" ]] || return 1
  domain_begin="$(caddy_domain_begin_marker)"
  grep -Fx "$domain_begin" "$CADDYFILE" >/dev/null 2>&1 && return 0
  legacy_domain="$(legacy_caddy_managed_domain "$CADDYFILE")"
  [[ "$legacy_domain" == "$PROXY_DOMAIN" ]]
}

locate_existing_caddy_site() {
  local scan_root="${CADDY_SCAN_ROOT:-/etc/caddy}" file location matches=0
  CADDY_EXISTING_SITE_FILE=""
  CADDY_EXISTING_SITE_OPEN_LINE=0
  CADDY_EXISTING_SITE_CLOSE_LINE=0
  [[ -d "$scan_root" ]] || return 1
  while IFS= read -r -d '' file; do
    location="$(find_caddy_site_in_file "$file" "$PROXY_DOMAIN" 2>/dev/null || true)"
    [[ -n "$location" ]] || continue
    ((matches+=1))
    CADDY_EXISTING_SITE_FILE="$file"
    CADDY_EXISTING_SITE_OPEN_LINE="${location%%$'\t'*}"
    CADDY_EXISTING_SITE_CLOSE_LINE="${location##*$'\t'}"
  done < <(find "$scan_root" -type f \( -name 'Caddyfile' -o -name '*.caddy' -o -name '*.conf' \) \
    ! -name '*.bak-*' ! -name 'Caddyfile.candidate.*' -print0 2>/dev/null)
  [[ $matches -eq 1 ]] || {
    if (( matches > 1 )); then
      die "域名 $PROXY_DOMAIN 出现在多个可修改的 Caddy 站点块中，无法安全确定目标文件。"
    fi
    return 1
  }
}

existing_caddy_route_begin_marker() { printf '# BEGIN MANAGED EMBY EXISTING ROUTE: %s %s' "$PROXY_DOMAIN" "$1"; }
existing_caddy_route_end_marker()   { printf '# END MANAGED EMBY EXISTING ROUTE: %s %s' "$PROXY_DOMAIN" "$1"; }

existing_caddy_route_is_managed() {
  local route_path="$1" marker
  marker="$(existing_caddy_route_begin_marker "$route_path")"
  grep -Fx "$marker" "$CADDY_EXISTING_SITE_FILE" >/dev/null 2>&1
}

check_existing_caddy_route_conflict() {
  local route_path="$1" token base conflict="" scan_file location open_line close_line temp=""
  scan_file="$CADDY_EXISTING_SITE_FILE"
  if existing_caddy_route_is_managed "$route_path"; then
    temp="$(mktemp /tmp/emby-caddy-conflict.XXXXXX)"
    strip_existing_caddy_route_block "$scan_file" "$temp" "$route_path"
    scan_file="$temp"
    location="$(find_caddy_site_in_file "$scan_file" "$PROXY_DOMAIN" 2>/dev/null || true)"
    [[ -n "$location" ]] || { rm -f "$temp"; die "移除旧托管路径后无法重新定位 Caddy 站点。"; }
    open_line="${location%%$'\t'*}"
    close_line="${location##*$'\t'}"
  else
    open_line="$CADDY_EXISTING_SITE_OPEN_LINE"
    close_line="$CADDY_EXISTING_SITE_CLOSE_LINE"
  fi
  while IFS= read -r token; do
    [[ "$token" == //* ]] && continue
    token="${token%\*}"
    while [[ "$token" != "/" && "$token" == */ ]]; do token="${token%/}"; done
    [[ "$token" != "/" && -n "$token" ]] || continue
    base="$token"
    if [[ "$route_path" == "$base" || "$route_path" == "$base"/* || "$base" == "$route_path"/* ]]; then
      conflict="$token"
      break
    fi
  done < <(
    sed -n "${open_line},${close_line}p" "$scan_file" |
      sed 's/[[:space:]]*#.*$//' | grep -Eo '/[A-Za-z0-9._~*/-]+' || true
  )
  [[ -z "$temp" ]] || rm -f "$temp"
  [[ -z "$conflict" ]] || \
    die "已有 Caddy 站点 $PROXY_DOMAIN 中检测到与 $route_path 重叠的路径 ${conflict}。为避免覆盖原路由，脚本已停止。"
}

detect_existing_caddy_domain_mode() {
  [[ "$PROXY_ENGINE" == "caddy" && -f "$CADDYFILE" ]] || return 0
  [[ "$HTTPS_PORT" == "443" && "$DOMAIN_ENTRY_TYPE" == "path" ]] || return 0
  caddy_domain_is_script_managed && return 0
  if locate_existing_caddy_site; then
    CADDY_ATTACH_EXISTING=1
    info "域名 $PROXY_DOMAIN 已存在于 ${CADDY_EXISTING_SITE_FILE}。"
    info "将只在该站点内新增独立非根路径，不会替换原站点或原有根路径。"
  fi
}

prompt_inputs() {
  local interactive_upstream=0 primary_route="/" i mode_choice="" domain_choice="" listen_port_provided=0 domain_type_provided=0
  [[ -z "$LISTEN_PORT" ]] || listen_port_provided=1
  [[ -z "$DOMAIN_ENTRY_TYPE" ]] || domain_type_provided=1
  normalize_unsafe_ip_visibility
  select_proxy_engine

  if [[ -z "$ACCESS_MODE" ]]; then
    if [[ -n "$PROXY_DOMAIN" ]]; then
      ACCESS_MODE="domain"
    elif [[ -n "$PROXY_IP" || -n "$LISTEN_PORT" ]]; then
      ACCESS_MODE="ip"
    else
      [[ -t 0 ]] || die "非交互环境请提供 --domain；如确需不安全的 IP HTTP 模式，必须同时使用 --show-unsafe-ip-mode --mode ip。"
      if [[ "$SHOW_UNSAFE_IP_MODE" == "1" ]]; then
        printf '\n请选择对外访问方式：\n'
        printf '  1) 域名 + HTTPS（安全，推荐）\n'
        printf '  2) 公网 IPv4 + HTTP 独立端口（不安全：明文传输）\n'
        printf '请输入 1 或 2（默认 1）：'
        read -r mode_choice
        ACCESS_MODE="${mode_choice:-1}"
      else
        ACCESS_MODE="domain"
        info "默认仅提供域名 HTTPS 模式；不安全的 IP 明文 HTTP 模式已隐藏。"
        info "确需临时使用时，重新运行并显式添加：--show-unsafe-ip-mode"
      fi
    fi
  fi
  normalize_access_mode
  require_unsafe_ip_opt_in

  if [[ "$ACCESS_MODE" == "domain" ]]; then
    [[ -z "$PROXY_IP" && -z "$LISTEN_PORT" ]] || die "域名模式不能同时使用 --ip-address 或 --listen-port。"
    normalize_domain_entry_type
    if [[ -t 0 && $domain_type_provided -eq 0 && -z "${HTTPS_PORT:-}" && -z "${PRIMARY_ROUTE_INPUT:-}" && ${#ROUTE_SPECS[@]} -eq 0 ]]; then
      printf '\n请选择域名入口结构：\n'
      printf '  1) 独立子域名 + HTTPS 443（首选，兼容性最好）\n'
      printf '  2) 同一域名 + 独立 HTTPS 端口（每个 Emby 一个端口）\n'
      printf '  3) 同一域名 + 不同路径（高级兼容模式）\n'
      printf '请输入 1、2 或 3（默认 1）：'
      read -r domain_choice
      DOMAIN_ENTRY_TYPE="${domain_choice:-1}"
      normalize_domain_entry_type
    fi
    case "$DOMAIN_ENTRY_TYPE" in
      subdomain)
        [[ -z "$HTTPS_PORT" || "$HTTPS_PORT" == "443" ]] || die "subdomain 模式固定使用 HTTPS 443；自定义端口请选择 port 模式。"
        HTTPS_PORT="443" ;;
      port)
        if [[ -z "$HTTPS_PORT" || "$HTTPS_PORT" == "443" ]]; then
          [[ -t 0 ]] || die "port 模式必须使用 --https-port 指定 1024-65535 的独立端口。"
          printf '%s请输入独立 HTTPS 监听端口%s（例如 18443）：' "$BOLD" "$RESET"
          read -r HTTPS_PORT
        fi
        normalize_https_port
        [[ "$HTTPS_PORT" != "443" ]] || die "独立端口模式不能使用 443；请选择 1024-65535。" ;;
      path)
        [[ -z "$HTTPS_PORT" || "$HTTPS_PORT" == "443" ]] || die "path 模式固定使用 HTTPS 443；自定义端口请选择 port 模式。"
        HTTPS_PORT="443"
        warn "高级路径模式可能与 Emby Web、原生客户端或 Emby Connect 不兼容；能使用独立子域名/端口时不要选它。" ;;
    esac
    if [[ -z "$PROXY_DOMAIN" ]]; then
      [[ -t 0 ]] || die "域名模式非交互运行时必须使用 --domain。"
      printf '%s请输入对外访问的反代域名%s（例如 emby.example.com）：' "$BOLD" "$RESET"
      read -r PROXY_DOMAIN
    fi
    normalize_proxy_domain "$PROXY_DOMAIN"
    detect_existing_caddy_domain_mode
  else
    [[ -z "$PROXY_DOMAIN" && -z "$HTTPS_PORT" && -z "$DOMAIN_ENTRY_TYPE" ]] || die "IP 模式不需要 --domain、--https-port 或 --domain-mode，请删除这些参数。"
    LISTEN_PORT="${LISTEN_PORT:-8080}"
    normalize_listen_port
    if [[ -t 0 && -z "$PROXY_IP" ]]; then
      printf '%s请输入对外访问的公网 IPv4%s（直接回车自动检测）：' "$BOLD" "$RESET"
      read -r PROXY_IP
    fi
    [[ -z "$PROXY_IP" ]] || valid_ipv4 "$(trim "$PROXY_IP")" || die "访问 IPv4 格式无效：$PROXY_IP"
    if [[ -t 0 && $listen_port_provided -eq 0 ]]; then
      printf '%s请输入独立 HTTP 监听端口%s（默认 %s）：' "$BOLD" "$RESET" "$LISTEN_PORT"
      read -r mode_choice
      [[ -z "$mode_choice" ]] || LISTEN_PORT="$mode_choice"
      normalize_listen_port
    fi
  fi

  if (( CADDY_ATTACH_EXISTING )); then
    if [[ -z "$PRIMARY_ROUTE_INPUT" ]]; then
      [[ -t 0 ]] || die "域名已存在。非交互运行时必须使用 --path /a 指定要新增的非根路径。"
      printf '%s请输入要添加到现有域名的访问路径%s（例如 /a 或 /emby2）：' "$BOLD" "$RESET"
      read -r PRIMARY_ROUTE_INPUT
    fi
    primary_route="$(normalize_route_path "$PRIMARY_ROUTE_INPUT")"
    [[ "$primary_route" != "/" ]] || die "已有域名不能自动接管根路径 /，请使用 /a、/emby2 等独立路径。"
  elif [[ -n "$PRIMARY_ROUTE_INPUT" ]]; then
    primary_route="$(normalize_route_path "$PRIMARY_ROUTE_INPUT")"
    [[ "$primary_route" == "/" ]] || die "--path 的非根路径模式仅用于向已有 Caddy 域名追加路由；新入口的主源站固定使用 /。"
  fi

  if [[ -z "$UPSTREAM_INPUT" ]]; then
    [[ -t 0 ]] || die "非交互环境请使用 --engine、访问模式参数和 --upstream。"
    printf '%s请输入 Emby 源站域名或 URL%s（例如 origin.example.com）：' "$BOLD" "$RESET"
    read -r UPSTREAM_INPUT
    interactive_upstream=1
  fi

  ROUTE_PATHS=("$primary_route")
  ROUTE_INPUTS=("$UPSTREAM_INPUT")

  if [[ -t 0 && $interactive_upstream -eq 1 && "$ACCESS_MODE" == "domain" && "$DOMAIN_ENTRY_TYPE" == "path" ]]; then
    local add_more="" route_path="" route_upstream=""
    while true; do
      printf '是否添加另一个路径反代（例如 /a）？[y/N]：'
      read -r add_more
      [[ "$add_more" =~ ^[Yy]$ ]] || break
      printf '请输入访问路径（例如 /a）：'
      read -r route_path
      printf '请输入该路径对应的 Emby 源站：'
      read -r route_upstream
      ROUTE_SPECS+=("${route_path}=${route_upstream}")
    done
  fi
  parse_route_specs
  if [[ "$ACCESS_MODE" == "ip" && ${#ROUTE_PATHS[@]} -gt 1 ]]; then
    warn "检测到旧式 IP 多路径参数；仅为兼容旧配置继续执行。新配置应为每个 Emby 分配一个独立 HTTP 端口。"
  elif [[ "$ACCESS_MODE" == "domain" && "$DOMAIN_ENTRY_TYPE" != "path" && ${#ROUTE_PATHS[@]} -gt 1 ]]; then
    die "subdomain/port 模式每个入口只允许一个根路径源站；多源站请分别新增子域名或独立 HTTPS 端口。"
  fi
  if (( CADDY_ATTACH_EXISTING )); then
    for ((i=0; i<${#ROUTE_PATHS[@]}; i++)); do
      [[ "${ROUTE_PATHS[$i]}" != "/" ]] || die "已有 Caddy 域名只能新增非根路径。"
      check_existing_caddy_route_conflict "${ROUTE_PATHS[$i]}"
    done
  fi
}

normalize_route_path() {
  local value lower
  value="$(trim "$1")"
  [[ -n "$value" ]] || die "路径不能为空。"
  [[ "$value" == /* ]] || value="/$value"
  while [[ "$value" != "/" && "$value" == */ ]]; do value="${value%/}"; done
  [[ ${#value} -le 128 ]] || die "路径过长：$value"
  if [[ "$value" == "/" ]]; then
    printf '/'
    return
  fi
  [[ "$value" =~ ^/([A-Za-z0-9._~-]+/)*[A-Za-z0-9._~-]+$ ]] || \
    die "路径格式无效：${value}。只允许字母、数字、点、下划线、波浪线、连字符和斜杠。"
  lower="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    /emby|/emby/*|/web|/web/*|/.well-known|/.well-known/*|/_emby_proxy_health|/_emby_proxy_health/*)
      die "路径 $value 会与 Emby、健康检查或证书验证的保留路径冲突，请换成 /a、/b 等独立前缀。" ;;
  esac
  printf '%s' "$value"
}

parse_route_specs() {
  local spec path input existing
  for spec in "${ROUTE_SPECS[@]}"; do
    [[ "$spec" == *=* ]] || die "路径映射格式无效：${spec}（正确示例：/a=https://origin.example.com）"
    path="$(normalize_route_path "${spec%%=*}")"
    input="$(trim "${spec#*=}")"
    [[ -n "$input" ]] || die "路径 $path 的源站不能为空。"
    for existing in "${ROUTE_PATHS[@]}"; do
      [[ "$existing" != "$path" ]] || die "路径重复：$path"
    done
    ROUTE_PATHS+=("$path")
    ROUTE_INPUTS+=("$input")
  done
}

prepare_routes() {
  local i
  ROUTE_URLS=()
  ROUTE_HOSTS=()
  for ((i=0; i<${#ROUTE_PATHS[@]}; i++)); do
    info "检查路径 ${ROUTE_PATHS[$i]} 对应的源站……"
    parse_upstream "${ROUTE_INPUTS[$i]}"
    probe_upstream
    ROUTE_URLS+=("$UPSTREAM_URL")
    ROUTE_HOSTS+=("$UPSTREAM_HOST")
  done
  # 保留根路径标量，供已有诊断输出兼容使用。
  UPSTREAM_URL="${ROUTE_URLS[0]}"
  UPSTREAM_HOST="${ROUTE_HOSTS[0]}"
}

apt_install_prerequisites() {
  export DEBIAN_FRONTEND=noninteractive
  info "更新 apt 索引并安装检测/签名依赖……"
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    debian-keyring debian-archive-keyring apt-transport-https \
    ca-certificates curl gnupg dnsutils iproute2 jq util-linux >/dev/null
  ok "基础依赖已就绪。"
}

install_manager_command() {
  local install_mode="${1:-fallback}" source_candidate temp manager_source=""
  temp="$(mktemp /tmp/emby-proxy-manager.XXXXXX)"
  source_candidate="$(dirname -- "$SCRIPT_PATH")/emby-proxy"
  if [[ -f "$source_candidate" ]]; then
    cp -a "$source_candidate" "$temp"
    manager_source="$source_candidate"
  elif [[ "$install_mode" == "current" ]]; then
    if curl -fsSL --connect-timeout 8 --max-time 30 "$MANAGER_COMMAND_URL" -o "$temp"; then
      manager_source="$MANAGER_COMMAND_URL"
    else
      rm -f "$temp"
      warn "无法下载与当前安装后端配套的 emby-proxy 管理命令。请检查 GitHub 网络后重试。"
      return 1
    fi
  elif [[ -f "$MANAGER_BIN" ]]; then
    cp -a "$MANAGER_BIN" "$temp"
    manager_source="$MANAGER_BIN"
  elif curl -fsSL --connect-timeout 8 --max-time 30 "$MANAGER_COMMAND_URL" -o "$temp"; then
    manager_source="$MANAGER_COMMAND_URL"
  else
    rm -f "$temp"
    warn "暂时无法下载 emby-proxy 管理命令；本次反代仍会继续配置，稍后可重新运行安装脚本补齐。"
    return 0
  fi
  if ! bash -n "$temp"; then
    rm -f "$temp"
    warn "管理命令语法验证失败，来源：${manager_source}；为避免安装损坏文件，本次跳过。"
    [[ "$install_mode" != "current" ]] || return 1
    return 0
  fi
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    install -d -o root -g root -m 0755 "$MANAGER_LIBEXEC"
    if [[ "$SCRIPT_PATH" != "$(readlink -f "$MANAGER_LIBEXEC/setup-emby-proxy.sh" 2>/dev/null || true)" ]]; then
      install -o root -g root -m 0755 "$SCRIPT_PATH" "$MANAGER_LIBEXEC/setup-emby-proxy.sh"
    fi
    install -o root -g root -m 0755 "$temp" "$MANAGER_BIN"
  else
    install -d -m 0755 "$MANAGER_LIBEXEC"
    install -m 0755 "$SCRIPT_PATH" "$MANAGER_LIBEXEC/setup-emby-proxy.sh"
    install -m 0755 "$temp" "$MANAGER_BIN"
  fi
  rm -f "$temp"
  ok "管理命令已安装：sudo emby-proxy"
}

site_state_id() {
  if [[ "$ACCESS_MODE" == "ip" ]]; then
    printf 'ip-%s-%s' "$PROXY_IP" "$LISTEN_PORT"
  elif [[ "$HTTPS_PORT" != "443" ]]; then
    printf 'domain-%s-https-%s' "$PROXY_DOMAIN" "$HTTPS_PORT"
  else
    printf 'domain-%s' "$PROXY_DOMAIN"
  fi
}

persist_site_state() {
  local site_id state_file temp created_at now managed_kind config_file routes_json i
  command -v jq >/dev/null 2>&1 || { warn "缺少 jq，无法写入管理索引；反代配置本身已经生效。"; return 0; }
  site_id="$(site_state_id)"
  state_file="$MANAGER_HOME/sites.d/${site_id}.json"
  temp="$(mktemp /tmp/emby-proxy-state.XXXXXX)"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  created_at="$now"
  [[ ! -f "$state_file" ]] || created_at="$(jq -r '.created_at // empty' "$state_file" 2>/dev/null || true)"
  [[ -n "$created_at" ]] || created_at="$now"
  managed_kind="standalone"
  config_file="$([[ "$PROXY_ENGINE" == "caddy" ]] && printf '%s' "$CADDYFILE" || printf '%s' "$NGINX_CONFIG")"
  if (( CADDY_ATTACH_EXISTING )); then
    managed_kind="caddy_attached"
    config_file="$CADDY_EXISTING_SITE_FILE"
  fi
  routes_json='[]'
  for ((i=0; i<${#ROUTE_PATHS[@]}; i++)); do
    routes_json="$(jq -c --arg path "${ROUTE_PATHS[$i]}" --arg upstream "${ROUTE_URLS[$i]}" \
      '. + [{path:$path,upstream:$upstream}]' <<<"$routes_json")"
  done
  if [[ "$managed_kind" == "caddy_attached" && -f "$state_file" ]]; then
    routes_json="$(jq -c --argjson incoming "$routes_json" '
      (.routes // []) as $old |
      reduce $incoming[] as $item ($old; map(select(.path != $item.path)) + [$item])
    ' "$state_file" 2>/dev/null || printf '%s' "$routes_json")"
  fi
  routes_json="$(jq -c 'sort_by([if .path=="/" then 0 else 1 end,.path])' <<<"$routes_json")"
  jq -n \
    --argjson schema_version 1 \
    --arg id "$site_id" --arg engine "$PROXY_ENGINE" --arg mode "$ACCESS_MODE" \
    --arg domain "$([[ "$ACCESS_MODE" == "domain" ]] && printf '%s' "$PROXY_DOMAIN" || true)" \
    --arg ip "$PROXY_IP" --arg listen_port "$([[ "$ACCESS_MODE" == "domain" ]] && printf '%s' "$HTTPS_PORT" || printf '%s' "$LISTEN_PORT")" --arg public_url "$PUBLIC_BASE_URL" \
    --arg entry_type "$([[ "$ACCESS_MODE" == "domain" ]] && printf '%s' "$DOMAIN_ENTRY_TYPE" || printf 'port')" \
    --arg managed_kind "$managed_kind" --arg config_file "$config_file" \
    --arg created_at "$created_at" --arg updated_at "$now" --argjson routes "$routes_json" \
    '{schema_version:$schema_version,id:$id,engine:$engine,mode:$mode,domain:$domain,ip:$ip,
      listen_port:($listen_port|if .=="" then null else tonumber end),entry_type:$entry_type,public_url:$public_url,
      managed_kind:$managed_kind,config_file:$config_file,created_at:$created_at,updated_at:$updated_at,routes:$routes}' \
    >"$temp"
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    install -d -o root -g root -m 0750 "$MANAGER_HOME/sites.d" "$MANAGER_HOME/backups"
    install -o root -g root -m 0640 "$temp" "$state_file"
  else
    # 仅供本地配置生成测试；正式安装始终由 root 执行。
    install -d -m 0750 "$MANAGER_HOME/sites.d" "$MANAGER_HOME/backups"
    install -m 0640 "$temp" "$state_file"
  fi
  rm -f "$temp"
  ok "已写入管理索引：${site_id}（以后可运行 sudo emby-proxy 管理）"
}

public_ip() {
  local family="$1" flag="$2" endpoint="$3" result
  result="$(curl "$flag" --noproxy '*' -fsS --connect-timeout 4 --max-time 8 "$endpoint" 2>/dev/null || true)"
  if [[ "$family" == "4" && "$result" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s' "$result"
  elif [[ "$family" == "6" && "$result" == *:* && "$result" != *[[:space:]]* ]]; then
    printf '%s' "$result"
  fi
}

join_by() {
  local delimiter="$1"; shift
  local first=1 item
  for item in "$@"; do
    (( first )) || printf '%s' "$delimiter"
    printf '%s' "$item"; first=0
  done
}

contains_exact() {
  local needle="$1"; shift
  local item
  for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
  return 1
}

check_dns() {
  local ipv4 ipv6 dns_ok=0 bad_record=0
  local -a records_a=() records_aaaa=()
  mapfile -t records_a < <(dig +time=3 +tries=1 +short A "$PROXY_DOMAIN" @1.1.1.1 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u || true)
  mapfile -t records_aaaa < <(dig +time=3 +tries=1 +short AAAA "$PROXY_DOMAIN" @1.1.1.1 2>/dev/null | grep ':' | sort -u || true)
  # 某些机房会屏蔽外部 DNS 的 UDP/53，此时回退到系统解析器。
  if [[ ${#records_a[@]} -eq 0 && ${#records_aaaa[@]} -eq 0 ]]; then
    mapfile -t records_a < <(dig +time=3 +tries=1 +short A "$PROXY_DOMAIN" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u || true)
    mapfile -t records_aaaa < <(dig +time=3 +tries=1 +short AAAA "$PROXY_DOMAIN" 2>/dev/null | grep ':' | sort -u || true)
  fi
  ipv4="$(public_ip 4 -4 https://api.ipify.org)"
  ipv6="$(public_ip 6 -6 https://api64.ipify.org)"

  info "DNS A 记录：$([[ ${#records_a[@]} -gt 0 ]] && join_by ', ' "${records_a[@]}" || printf '未找到')"
  info "DNS AAAA 记录：$([[ ${#records_aaaa[@]} -gt 0 ]] && join_by ', ' "${records_aaaa[@]}" || printf '未找到')"
  [[ -n "$ipv4" ]] && info "本机公网 IPv4：$ipv4" || warn "无法从公网查询本机 IPv4，将在部署后通过证书申请结果继续验证。"
  [[ -n "$ipv6" ]] && info "本机公网 IPv6：$ipv6"

  if [[ ${#records_a[@]} -eq 0 && ${#records_aaaa[@]} -eq 0 ]]; then
    error "域名 $PROXY_DOMAIN 尚无公网 A/AAAA 记录。"
    printf '修复方法：在 DNS 服务商处添加 A 记录指向本 VPS 公网 IPv4；如未配置 IPv6，请不要添加 AAAA 记录。\n' >&2
    exit 1
  fi

  if [[ -n "$ipv4" && ${#records_a[@]} -gt 0 ]]; then
    local record
    contains_exact "$ipv4" "${records_a[@]}" && dns_ok=1 || bad_record=1
    for record in "${records_a[@]}"; do
      [[ "$record" == "$ipv4" ]] || bad_record=1
    done
  fi
  if [[ -n "$ipv6" && ${#records_aaaa[@]} -gt 0 ]]; then
    contains_exact "$ipv6" "${records_aaaa[@]}" && dns_ok=1 || bad_record=1
    for record in "${records_aaaa[@]}"; do
      [[ "$record" == "$ipv6" ]] || bad_record=1
    done
  elif [[ -z "$ipv6" && ${#records_aaaa[@]} -gt 0 ]]; then
    bad_record=1
  fi

  if (( bad_record )); then
    error "DNS 中存在不指向本 VPS 的 A/AAAA 记录，自动申请证书或用户访问可能失败。"
    printf '修复方法：删除错误记录；A 指向本机 IPv4%s。若使用 Cloudflare，请先设为“仅 DNS（灰云）”。\n' \
      "$([[ -n "$ipv4" ]] && printf ' %s' "$ipv4" || true)" >&2
    exit 1
  fi
  if [[ -n "$ipv4$ipv6" && $dns_ok -eq 0 ]]; then
    die "DNS 记录没有任何一项指向本 VPS。请修正解析并等待生效后重试。"
  fi
  ok "DNS 预检通过。"
}

prepare_access_target() {
  if [[ "$ACCESS_MODE" == "ip" ]]; then
    set_ip_access_target
  else
    check_dns
  fi
}

probe_url() {
  local url="$1" code
  code="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 20 "$url/" 2>/dev/null || true)"
  [[ "$code" =~ ^[1-5][0-9][0-9]$ && "$code" != "000" ]] || return 1
  printf '%s' "$code"
}

probe_upstream() {
  local code=""
  if [[ "$UPSTREAM_URL" == http://* || "$UPSTREAM_URL" == https://* ]]; then
    info "检测源站连通性：$UPSTREAM_URL"
    if ! code="$(probe_url "$UPSTREAM_URL")"; then
      error "VPS 无法访问源站 ${UPSTREAM_URL}。"
      printf '修复方法：检查源站协议/端口、防火墙、IP 白名单和 HTTPS 证书；可在 VPS 上执行：\n  curl -v --connect-timeout 10 %q/\n' "$UPSTREAM_URL" >&2
      exit 1
    fi
  else
    info "未指定源站协议，先检测 HTTPS……"
    if code="$(probe_url "https://$UPSTREAM_URL")"; then
      UPSTREAM_URL="https://$UPSTREAM_URL"
    else
      warn "HTTPS 不可用，继续检测 HTTP……"
      if code="$(probe_url "http://$UPSTREAM_URL")"; then
        UPSTREAM_URL="http://$UPSTREAM_URL"
      else
        error "HTTPS 和 HTTP 均无法连接源站 ${UPSTREAM_URL}。"
        printf '修复方法：确认源站域名、端口、源站服务状态及防火墙；如使用非标准端口，请写成 host:port。\n' >&2
        exit 1
      fi
    fi
  fi
  ok "源站可访问：${UPSTREAM_URL}（HTTP ${code}）"
  if [[ "$UPSTREAM_URL" == http://* ]]; then
    warn "源站链路使用明文 HTTP；仅在可信内网或本机回源时推荐。"
  fi
  return 0
}

check_port_conflicts() {
  local listeners foreign allowed_pattern own_marker
  if [[ "$ACCESS_MODE" == "ip" ]]; then
    listeners="$(ss -H -lntp 2>/dev/null | awk -v port=":$LISTEN_PORT" '$4 ~ (port "$") {print}' || true)"
    [[ -z "$listeners" ]] && return 0
    own_marker="# MANAGED EMBY SITE: $PROXY_KEY"
    if [[ "$PROXY_ENGINE" == "caddy" && -f "$CADDYFILE" ]] && \
       grep -F "$(caddy_domain_begin_marker)" "$CADDYFILE" >/dev/null 2>&1 && \
       ! printf '%s\n' "$listeners" | grep -vi caddy >/dev/null 2>&1; then
      info "端口 $LISTEN_PORT 已由本脚本管理的 Caddy IP 站点监听，将安全更新配置。"
      return 0
    fi
    if [[ "$PROXY_ENGINE" == "nginx" && -f "$NGINX_CONFIG" ]] && \
       grep -Fx "$own_marker" "$NGINX_CONFIG" >/dev/null 2>&1 && \
       ! printf '%s\n' "$listeners" | grep -vi nginx >/dev/null 2>&1; then
      info "端口 $LISTEN_PORT 已由本脚本管理的 Nginx IP 站点监听，将安全更新配置。"
      return 0
    fi
    error "独立端口 $LISTEN_PORT 已被占用，脚本不会修改或抢占它："
    printf '%s\n' "$listeners" >&2
    printf '修复方法：重新运行脚本并选择其他 1024-65535 端口，例如 18080；同时在云安全组中放行该端口。\n' >&2
    exit 1
  fi
  if [[ "$HTTPS_PORT" == "443" ]]; then
    listeners="$(ss -H -lntp 2>/dev/null | awk '$4 ~ /:80$|:443$/ {print}' || true)"
  else
    listeners="$(ss -H -lntp 2>/dev/null | awk -v port=":$HTTPS_PORT" '$4 ~ /:80$/ || $4 ~ (port "$") {print}' || true)"
  fi
  [[ -z "$listeners" ]] && return 0
  allowed_pattern="$PROXY_ENGINE"
  foreign="$(printf '%s\n' "$listeners" | grep -vi "$allowed_pattern" || true)"
  if [[ -n "$foreign" ]]; then
    error "域名入口所需端口（TCP 80 和 ${HTTPS_PORT}）已被其他程序占用，无法启用 ${PROXY_ENGINE}："
    printf '%s\n' "$foreign" >&2
    printf '修复方法：确认占用者没有承载其他站点后，再停止它或修改监听端口。不要直接删除全部 Docker 容器。\n' >&2
    [[ "$foreign" == *caddy* ]] && printf '如确定不再使用 Caddy：systemctl disable --now caddy\n' >&2
    [[ "$foreign" == *nginx* ]] && printf '如确定不再使用 Nginx：systemctl disable --now nginx\n' >&2
    exit 1
  fi
  info "所需端口当前由已有 $PROXY_ENGINE 监听，将安全更新配置。"
}

install_caddy() {
  if command -v caddy >/dev/null 2>&1 && systemctl cat caddy.service >/dev/null 2>&1; then
    ok "检测到 Caddy：$(caddy version 2>/dev/null || printf '版本未知')"
    return
  fi

  if command -v caddy >/dev/null 2>&1; then
    warn "检测到 Caddy 可执行文件但没有 caddy.service，将安装官方 Debian 软件包以补齐 systemd 服务。"
  fi

  info "按 Caddy 官方 Debian stable 软件源步骤安装……"
  rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  rm -f /etc/apt/sources.list.d/caddy-stable.list
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' |
    gpg --dearmor --batch --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' |
    tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  chmod o+r /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y caddy >/dev/null
  command -v caddy >/dev/null 2>&1 || die "Caddy 安装后仍未找到可执行文件。"
  ok "Caddy 安装完成：$(caddy version)"
}

install_nginx() {
  export DEBIAN_FRONTEND=noninteractive
  if command -v nginx >/dev/null 2>&1 && systemctl cat nginx.service >/dev/null 2>&1; then
    ok "检测到 Nginx：$(nginx -v 2>&1)"
    [[ "$ACCESS_MODE" == "ip" ]] || apt-get install -y --no-install-recommends certbot >/dev/null
  else
    NGINX_NEWLY_INSTALLED=1
    if [[ "$ACCESS_MODE" == "ip" ]]; then
      info "从 Debian/Ubuntu 软件源安装 Nginx……"
      apt-get install -y nginx >/dev/null
    else
      info "从 Debian/Ubuntu 软件源安装 Nginx 与 Certbot……"
      apt-get install -y nginx certbot >/dev/null
    fi
  fi
  command -v nginx >/dev/null 2>&1 || die "Nginx 安装后仍未找到可执行文件。"
  if [[ "$ACCESS_MODE" == "ip" ]]; then
    ok "Nginx 已就绪：$(nginx -v 2>&1)"
  else
    command -v certbot >/dev/null 2>&1 || die "Certbot 安装后仍未找到可执行文件。"
    ok "Nginx/Certbot 已就绪：$(nginx -v 2>&1)"
  fi
}

disable_new_nginx_default_site() {
  (( NGINX_NEWLY_INSTALLED == 1 )) || return 0
  [[ "$ACCESS_MODE" == "ip" && -L "$NGINX_DEFAULT_SITE_LINK" ]] || return 0
  NGINX_DEFAULT_LINK_TARGET="$(readlink "$NGINX_DEFAULT_SITE_LINK")"
  rm -f "$NGINX_DEFAULT_SITE_LINK"
  NGINX_DEFAULT_DISABLED=1
  info "IP 模式已禁用本次新装 Nginx 的 Debian 默认站点，不额外占用 TCP 80。"
}

restore_new_nginx_default_site() {
  (( NGINX_DEFAULT_DISABLED == 1 )) || return 0
  [[ -n "$NGINX_DEFAULT_LINK_TARGET" && ! -e "$NGINX_DEFAULT_SITE_LINK" ]] || return 0
  mkdir -p "$(dirname "$NGINX_DEFAULT_SITE_LINK")"
  ln -s "$NGINX_DEFAULT_LINK_TARGET" "$NGINX_DEFAULT_SITE_LINK"
  NGINX_DEFAULT_DISABLED=0
}

emit_nginx_header_maps() {
  local i route_path upstream_host escaped_host escaped_route public_prefix location_var content_var
  for ((i=0; i<${#ROUTE_PATHS[@]}; i++)); do
    route_path="${ROUTE_PATHS[$i]}"
    upstream_host="${ROUTE_HOSTS[$i]}"
    # 源站主机已限制为字母、数字、点和连字符；这里只需转义正则中的点。
    escaped_host="${upstream_host//./\\.}"
    public_prefix=""
    [[ "$route_path" == "/" ]] || public_prefix="$route_path"
    location_var="emby_proxy_location_${NGINX_ID}_$i"
    content_var="emby_proxy_content_location_${NGINX_ID}_$i"
    cat <<EOF
map \$upstream_http_location \$$location_var {
    default \$upstream_http_location;
    "~*^https?://${escaped_host}(?::[0-9]+)?\$" "$PUBLIC_BASE_URL${public_prefix}/";
    "~*^https?://${escaped_host}(?::[0-9]+)?/(.*)\$" "$PUBLIC_BASE_URL${public_prefix}/\$1";
EOF
    if [[ "$route_path" != "/" ]]; then
      escaped_route="${route_path//./\\.}"
      printf '    "~*^%s(?:/|$)" $upstream_http_location;\n' "$escaped_route"
    fi
    cat <<EOF
    "~*^/(.*)\$" "${public_prefix}/\$1";
}

map \$upstream_http_content_location \$$content_var {
    default \$upstream_http_content_location;
    "~*^https?://${escaped_host}(?::[0-9]+)?\$" "$PUBLIC_BASE_URL${public_prefix}/";
    "~*^https?://${escaped_host}(?::[0-9]+)?/(.*)\$" "$PUBLIC_BASE_URL${public_prefix}/\$1";
EOF
    if [[ "$route_path" != "/" ]]; then
      printf '    "~*^%s(?:/|$)" $upstream_http_content_location;\n' "$escaped_route"
    fi
    cat <<EOF
    "~*^/(.*)\$" "${public_prefix}/\$1";
}

EOF
  done
}

emit_nginx_http_prelude() {
  cat <<EOF
map \$http_upgrade \$emby_connection_upgrade_$NGINX_ID {
    default upgrade;
    ''      close;
}

# 不记录查询参数，避免 api_key/token 落盘；每条请求仍记录状态、字节数与耗时。
log_format emby_proxy_${NGINX_ID}_v1 escape=json
    '{"ts":\$msec,"time":"\$time_iso8601","client":"\$remote_addr","method":"\$request_method",'
    '"host":"\$host","path":"\$uri","status":\$status,"bytes_sent":\$body_bytes_sent,'
    '"request_time":\$request_time,"upstream_time":"\$upstream_response_time",'
    '"upstream_status":"\$upstream_status","upstream":"\$upstream_addr"}';

EOF
  emit_nginx_header_maps
}

emit_nginx_proxy_location() {
  local route_index="$1" route_path="$2" upstream="$3" upstream_host="$4" proxy_pass_value
  if [[ "$route_path" == "/" ]]; then
    proxy_pass_value="$upstream"
    printf '    location / {\n'
  else
    proxy_pass_value="${upstream}/"
    cat <<EOF
    location = $route_path {
        return 308 ${route_path}/\$is_args\$args;
    }

    location ^~ ${route_path}/ {
EOF
  fi
  cat <<EOF
        proxy_pass $proxy_pass_value;
        proxy_http_version 1.1;
        proxy_set_header Host \$proxy_host;
        proxy_set_header X-Real-IP \$remote_addr;
        # 不继承客户端自带的 X-Forwarded-For，避免伪造来源链。
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$emby_connection_upgrade_$NGINX_ID;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        # 只改写固定源站或根相对 URL；第三方绝对 URL 原样保留。
        proxy_hide_header Location;
        add_header Location \$emby_proxy_location_${NGINX_ID}_$route_index always;
        proxy_hide_header Content-Location;
        add_header Content-Location \$emby_proxy_content_location_${NGINX_ID}_$route_index always;
EOF
  if [[ "$route_path" != "/" ]]; then
    printf '        proxy_set_header X-Forwarded-Prefix %s;\n' "$route_path"
  fi
  if [[ "$upstream" == https://* ]]; then
    cat <<EOF
        proxy_ssl_server_name on;
        proxy_ssl_name $upstream_host;
        proxy_ssl_verify on;
        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
        proxy_ssl_verify_depth 5;
EOF
  fi
  printf '    }\n'
}

write_nginx_http_config() {
  local target="$1"
  cat >"$target" <<EOF
# MANAGED EMBY ACME: $PROXY_DOMAIN
# 由 $SCRIPT_NAME 自动管理；同一域名的多个 HTTPS 端口共享此 ACME/HTTP 入口。
server {
    listen 80;
    listen [::]:80;
    server_name $PROXY_DOMAIN;

    access_log off;

    # 只接受脚本配置的域名，避免该 server 被未知 Host 当作通用入口。
    if (\$host != $PROXY_DOMAIN) { return 444; }

    location ^~ /.well-known/acme-challenge/ {
        root $NGINX_ACME_ROOT;
        default_type text/plain;
    }

    location = $HEALTH_PATH {
        return 308 $PUBLIC_BASE_URL\$request_uri;
    }

    location / {
        return 308 $PUBLIC_BASE_URL\$request_uri;
    }
}
EOF
}

write_nginx_https_config() {
  local target="$1" i
  {
    cat <<EOF
# 由 $SCRIPT_NAME 自动管理，请勿在此文件中混入其他站点。
# MANAGED EMBY SITE: $PROXY_KEY
EOF
    emit_nginx_http_prelude
    cat <<EOF
server {
    listen $HTTPS_PORT ssl http2;
    listen [::]:$HTTPS_PORT ssl http2;
    server_name $PROXY_DOMAIN;

    access_log $NGINX_ACCESS_LOG emby_proxy_${NGINX_ID}_v1;

    # 同时锁定 TLS SNI 与 HTTP Host；未知域名不会进入 Emby 反代。
    if (\$ssl_server_name != $PROXY_DOMAIN) { return 421; }
    if (\$host != $PROXY_DOMAIN) { return 421; }

    ssl_certificate /etc/letsencrypt/live/$PROXY_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PROXY_DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:EMBY_SSL_${NGINX_ID}:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    client_max_body_size 0;

    location = $HEALTH_PATH {
        default_type text/plain;
        return 200 "ok";
    }

EOF
    for ((i=1; i<${#ROUTE_PATHS[@]}; i++)); do
      emit_nginx_proxy_location "$i" "${ROUTE_PATHS[$i]}" "${ROUTE_URLS[$i]}" "${ROUTE_HOSTS[$i]}"
      printf '\n'
    done
    emit_nginx_proxy_location 0 "/" "${ROUTE_URLS[0]}" "${ROUTE_HOSTS[0]}"
    printf '}\n'
  } >"$target"
}

write_nginx_ip_config() {
  local target="$1" i
  {
    cat <<EOF
# MANAGED EMBY SITE: $PROXY_KEY
# 由 $SCRIPT_NAME 自动管理；这是固定公网 IPv4 + 独立端口的明文 HTTP 入口。
EOF
    emit_nginx_http_prelude
    cat <<EOF
server {
    listen $LISTEN_PORT;
    listen [::]:$LISTEN_PORT;
    server_name $PROXY_IP;

    access_log $NGINX_ACCESS_LOG emby_proxy_${NGINX_ID}_v1;

    # 只接受当前 IP 作为 Host；客户端不能借 Host 选择其他回源。
    if (\$host != $PROXY_IP) { return 444; }

    client_max_body_size 0;

    location = $HEALTH_PATH {
        default_type text/plain;
        return 200 "ok";
    }

EOF
    for ((i=1; i<${#ROUTE_PATHS[@]}; i++)); do
      emit_nginx_proxy_location "$i" "${ROUTE_PATHS[$i]}" "${ROUTE_URLS[$i]}" "${ROUTE_HOSTS[$i]}"
      printf '\n'
    done
    emit_nginx_proxy_location 0 "/" "${ROUTE_URLS[0]}" "${ROUTE_HOSTS[0]}"
    printf '}\n'
  } >"$target"
}

rollback_nginx() {
  if (( NGINX_HAD_CONFIG )); then
    cp -a "$BACKUP_FILE" "$NGINX_CONFIG"
  else
    rm -f "$NGINX_CONFIG"
  fi
  (( NGINX_ACME_CREATED == 0 )) || rm -f "$NGINX_ACME_CONFIG"
  (( NGINX_HASH_CONFIG_CREATED == 0 )) || rm -f "$NGINX_HASH_CONFIG"
  restore_new_nginx_default_site
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
}

ensure_nginx_hash_capacity() {
  local candidate
  if [[ -f "$NGINX_HASH_CONFIG" ]]; then
    grep -Fx '# MANAGED EMBY NGINX HASH CAPACITY' "$NGINX_HASH_CONFIG" >/dev/null 2>&1 || \
      warn "Nginx 哈希容量文件已存在但不是脚本托管：$NGINX_HASH_CONFIG；脚本不会覆盖。"
    return 0
  fi
  if nginx -T 2>/dev/null | grep -Eq '^[[:space:]]*variables_hash_(max_size|bucket_size)[[:space:]]+'; then
    info "检测到现有 Nginx variables_hash 容量设置，保留原配置。"
    return 0
  fi
  candidate="$(mktemp /tmp/emby-nginx-hash.XXXXXX.conf)"
  cat >"$candidate" <<'EOF'
# MANAGED EMBY NGINX HASH CAPACITY
# 多入口/多路径会创建较多固定 map 变量；只提高哈希表容量，不改变请求路由。
variables_hash_max_size 4096;
variables_hash_bucket_size 128;
EOF
  install -o root -g root -m 0644 "$candidate" "$NGINX_HASH_CONFIG"
  rm -f "$candidate"
  NGINX_HASH_CONFIG_CREATED=1
  info "已加入 Nginx 多入口变量哈希容量配置：$NGINX_HASH_CONFIG"
}

reload_or_start_nginx() {
  systemctl enable nginx >/dev/null
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx
  else
    systemctl start nginx
  fi
}

legacy_nginx_managed_domain() {
  awk '$1 == "server_name" {
    domain=$2
    sub(/;$/, "", domain)
    print domain
    exit
  }' "$NGINX_LEGACY_CONFIG"
}

migrate_legacy_nginx_config() {
  local legacy_domain destination migration_backup
  [[ -f "$NGINX_LEGACY_CONFIG" ]] || return 0
  legacy_domain="$(legacy_nginx_managed_domain)"
  valid_domain "$legacy_domain" || \
    die "无法从旧配置 $NGINX_LEGACY_CONFIG 识别唯一域名。为避免影响现有站点，请先人工确认。"
  destination="/etc/nginx/conf.d/emby-proxy-${legacy_domain}.conf"
  [[ ! -e "$destination" ]] || \
    die "旧配置和每域名配置同时存在：${NGINX_LEGACY_CONFIG}、${destination}。请人工去重后重试。"
  migration_backup="${NGINX_LEGACY_CONFIG}.bak-migration-$(date +%Y%m%d-%H%M%S)"
  cp -a "$NGINX_LEGACY_CONFIG" "$migration_backup"
  mv "$NGINX_LEGACY_CONFIG" "$destination"
  if ! nginx -t >/dev/null 2>&1; then
    mv "$destination" "$NGINX_LEGACY_CONFIG"
    die "旧 Nginx 配置迁移后的完整配置验证失败，已恢复原文件；备份：$migration_backup"
  fi
  ok "已把旧版单域名 Nginx 配置迁移为：${destination}（内容未改变，备份：${migration_backup}）"
}

check_nginx_domain_conflict() {
  local conflict="" domain_pattern file marker listen_port
  domain_pattern="$(domain_token_regex "$PROXY_DOMAIN")"
  if [[ -f "$NGINX_CONFIG" ]] && ! grep -Fx "# MANAGED EMBY SITE: $PROXY_KEY" "$NGINX_CONFIG" >/dev/null 2>&1; then
    if [[ "$HTTPS_PORT" != "443" ]] || ! grep -q '^# 由 .*自动管理' "$NGINX_CONFIG"; then
      die "目标 Nginx 配置已存在但不是当前入口的托管文件：$NGINX_CONFIG"
    fi
    warn "检测到旧版脚本托管的 Nginx 域名配置；本次会在备份后升级为带入口标记的新格式。"
  fi
  if [[ -f "$NGINX_ACME_CONFIG" ]] && ! grep -Fx "# MANAGED EMBY ACME: $PROXY_DOMAIN" "$NGINX_ACME_CONFIG" >/dev/null 2>&1; then
    die "域名 $PROXY_DOMAIN 的共享 ACME 配置已存在但不是脚本托管：$NGINX_ACME_CONFIG"
  fi
  if [[ -d /etc/nginx ]]; then
    while IFS= read -r file; do
      [[ "$file" == "$NGINX_CONFIG" || "$file" == "$NGINX_ACME_CONFIG" ]] && continue
      marker="$(sed -n 's/^# MANAGED EMBY SITE: //p' "$file" | head -n1)"
      if [[ -z "$marker" && "$(basename "$file")" == "emby-proxy-${PROXY_DOMAIN}.conf" ]]; then
        marker="$PROXY_DOMAIN"
      fi
      if [[ "$marker" == "$PROXY_DOMAIN" || "$marker" == "$PROXY_DOMAIN-https-"* ]]; then
        listen_port="$(awk '$1=="listen" && $0~/ssl/ {gsub(/[^0-9]/,"",$2); print $2; exit}' "$file")"
        [[ "$listen_port" != "$HTTPS_PORT" ]] && continue
      fi
      conflict="$file"; break
    done < <(grep -RIlE --include='*.conf' "$domain_pattern" /etc/nginx 2>/dev/null || true)
  fi
  if [[ -n "$conflict" ]]; then
    die "入口 $PUBLIC_BASE_URL 与其他 Nginx 配置冲突：${conflict}。同一域名可以使用不同 HTTPS 端口，但同一域名+端口只能有一个站点。"
  fi
}

check_nginx_ip_conflict() {
  local conflict="" marker="# MANAGED EMBY SITE: $PROXY_KEY"
  if [[ -f "$NGINX_CONFIG" ]] && ! grep -Fx "$marker" "$NGINX_CONFIG" >/dev/null 2>&1; then
    die "目标配置文件已存在但不是本脚本管理：${NGINX_CONFIG}。为避免覆盖，脚本已停止。"
  fi
  if [[ -d /etc/nginx ]]; then
    conflict="$(grep -RIlE --include='*.conf' --exclude="$(basename "$NGINX_CONFIG")" \
      "listen[[:space:]]+([^[:space:];]*:)?${LISTEN_PORT}([[:space:];]|$)" /etc/nginx 2>/dev/null | head -n 1 || true)"
  fi
  [[ -z "$conflict" ]] || die "Nginx 配置 $conflict 已声明端口 ${LISTEN_PORT}。为避免监听冲突，请选择其他独立端口。"
}

apply_nginx_ip_config() {
  local timestamp candidate
  timestamp="$(date +%Y%m%d-%H%M%S)"
  candidate="$(mktemp /tmp/emby-nginx-ip.XXXXXX.conf)"
  mkdir -p "$(dirname "$NGINX_CONFIG")"
  check_nginx_ip_conflict

  if [[ -f "$NGINX_CONFIG" ]]; then
    NGINX_HAD_CONFIG=1
    BACKUP_FILE="${NGINX_CONFIG}.bak-${timestamp}"
    cp -a "$NGINX_CONFIG" "$BACKUP_FILE"
  else
    NGINX_HAD_CONFIG=0
    BACKUP_FILE="首次创建，无旧文件"
  fi
  ensure_nginx_hash_capacity

  write_nginx_ip_config "$candidate"
  install -o root -g root -m 0644 "$candidate" "$NGINX_CONFIG"
  disable_new_nginx_default_site
  if ! nginx -t; then
    rollback_nginx
    rm -f "$candidate"
    die "Nginx IP HTTP 候选配置验证失败，已恢复原配置。"
  fi
  if ! nginx -T 2>&1 | grep -F "configuration file $NGINX_CONFIG:" >/dev/null; then
    rollback_nginx
    rm -f "$candidate"
    die "主 nginx.conf 没有加载 ${NGINX_CONFIG}。请确认 http 块中包含：include /etc/nginx/conf.d/*.conf;"
  fi
  if ! reload_or_start_nginx; then
    rollback_nginx
    rm -f "$candidate"
    die "Nginx 重载失败，已恢复原配置。查看日志：journalctl -u nginx -n 100 --no-pager"
  fi
  rm -f "$candidate"
  ok "Nginx IP HTTP 配置已生效；备份：$BACKUP_FILE"
}

apply_nginx_config() {
  local timestamp candidate acme_candidate cert_dir
  if [[ "$ACCESS_MODE" == "ip" ]]; then
    apply_nginx_ip_config
    return
  fi
  timestamp="$(date +%Y%m%d-%H%M%S)"
  candidate="$(mktemp /tmp/emby-nginx.XXXXXX.conf)"
  acme_candidate="$(mktemp /tmp/emby-nginx-acme.XXXXXX.conf)"
  cert_dir="/etc/letsencrypt/live/$PROXY_DOMAIN"
  mkdir -p "$(dirname "$NGINX_CONFIG")" "$NGINX_ACME_ROOT/.well-known/acme-challenge"
  migrate_legacy_nginx_config
  check_nginx_domain_conflict

  if [[ -f "$NGINX_CONFIG" ]]; then
    NGINX_HAD_CONFIG=1
    BACKUP_FILE="${NGINX_CONFIG}.bak-${timestamp}"
    cp -a "$NGINX_CONFIG" "$BACKUP_FILE"
  else
    NGINX_HAD_CONFIG=0
    BACKUP_FILE="首次创建，无旧文件"
  fi
  ensure_nginx_hash_capacity

  if [[ ! -f "$NGINX_ACME_CONFIG" ]]; then
    write_nginx_http_config "$acme_candidate"
    install -o root -g root -m 0644 "$acme_candidate" "$NGINX_ACME_CONFIG"
    NGINX_ACME_CREATED=1
  fi

  if [[ ! -s "$cert_dir/fullchain.pem" || ! -s "$cert_dir/privkey.pem" ]]; then
    info "先启用共享 TCP 80 ACME 站点，以便完成域名验证……"
    if ! nginx -t; then
      rollback_nginx
      rm -f "$candidate" "$acme_candidate"
      die "Nginx ACME 候选配置验证失败，已恢复原配置。"
    fi
    if ! nginx -T 2>&1 | grep -F "configuration file $NGINX_ACME_CONFIG:" >/dev/null; then
      rollback_nginx
      rm -f "$candidate" "$acme_candidate"
      die "主 nginx.conf 没有加载 ${NGINX_ACME_CONFIG}。请确认 http 块中包含：include /etc/nginx/conf.d/*.conf;"
    fi
    if ! reload_or_start_nginx; then
      rollback_nginx
      rm -f "$candidate" "$acme_candidate"
      die "Nginx 启动/重载失败，已恢复原配置。查看日志：journalctl -u nginx -n 100 --no-pager"
    fi

    info "通过 Let's Encrypt 为 $PROXY_DOMAIN 申请证书……"
    if ! certbot certonly --webroot -w "$NGINX_ACME_ROOT" -d "$PROXY_DOMAIN" \
      --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring; then
      rollback_nginx
      rm -f "$candidate" "$acme_candidate"
      error "证书申请失败，已恢复原 Nginx 配置。"
      printf '修复方法：确认 DNS 指向本 VPS，云安全组与防火墙开放 TCP 80，并查看 /var/log/letsencrypt/letsencrypt.log。\n' >&2
      exit 1
    fi
  else
    ok "检测到可用的现有证书：$cert_dir/fullchain.pem"
  fi

  write_nginx_https_config "$candidate"
  install -o root -g root -m 0644 "$candidate" "$NGINX_CONFIG"
  if ! nginx -t; then
    rollback_nginx
    rm -f "$candidate" "$acme_candidate"
    die "Nginx HTTPS 配置验证失败，已恢复原配置。"
  fi
  if ! nginx -T 2>&1 | grep -F "configuration file $NGINX_CONFIG:" >/dev/null; then
    rollback_nginx
    rm -f "$candidate" "$acme_candidate"
    die "主 nginx.conf 没有加载 ${NGINX_CONFIG}。请确认 http 块中包含：include /etc/nginx/conf.d/*.conf;"
  fi
  if ! reload_or_start_nginx; then
    rollback_nginx
    rm -f "$candidate" "$acme_candidate"
    die "Nginx 重载失败，已恢复原配置。查看日志：journalctl -u nginx -n 100 --no-pager"
  fi
  rm -f "$candidate" "$acme_candidate"

  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
systemctl reload nginx
EOF
  chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
  if systemctl list-unit-files --type=timer 2>/dev/null | grep -q '^certbot.timer'; then
    if ! systemctl enable --now certbot.timer >/dev/null; then
      warn "无法启用 certbot.timer；证书当前可用，但请检查：systemctl status certbot.timer"
    fi
  elif [[ ! -e /etc/cron.d/certbot ]]; then
    warn "未发现 Certbot systemd timer 或 cron 任务，请手动确认自动续期：certbot renew --dry-run"
  fi
  ok "Nginx HTTPS 配置已生效；备份：$BACKUP_FILE"
}

show_plan() {
  local i
  printf '\n%s即将应用以下配置：%s\n' "$BOLD" "$RESET"
  printf '  反代程序： %s\n' "$PROXY_ENGINE"
  if [[ "$ACCESS_MODE" == "ip" ]]; then
    printf '  访问模式： 公网 IPv4 + HTTP 独立端口（每个 Emby 一个端口）\n'
  else
    case "$DOMAIN_ENTRY_TYPE" in
      subdomain) printf '  访问模式： 独立子域名 + HTTPS 443（首选）\n' ;;
      port) printf '  访问模式： 同一域名 + 独立 HTTPS 端口 %s\n' "$HTTPS_PORT" ;;
      path) printf '  访问模式： 同一域名 + 不同路径（高级兼容模式）\n' ;;
    esac
  fi
  if (( CADDY_ATTACH_EXISTING )); then
    printf '  部署方式： 保留现有 Caddy 域名，仅新增/更新独立路径\n'
  elif (( USING_EXISTING_SERVICE )); then
    printf '  部署方式： 复用现有服务，仅新增/更新脚本托管站点\n'
  else
    printf '  部署方式： 未发现现有服务，将全新安装\n'
  fi
  printf '  访问地址： %s\n' "$PUBLIC_BASE_URL"
  printf '  路径映射：\n'
  for ((i=0; i<${#ROUTE_PATHS[@]}; i++)); do
    printf '    %-16s -> %s\n' "${ROUTE_PATHS[$i]}" "${ROUTE_URLS[$i]}"
  done
  if [[ ${#ROUTE_PATHS[@]} -gt 1 || "${ROUTE_PATHS[0]}" != "/" ]]; then
    warn "【高级模式警告】子路径会在回源前被剥离；部分 Emby Web、原生客户端或 Emby Connect 不支持额外子路径。优先改用独立子域名或独立端口。"
  fi
  if [[ "$PROXY_ENGINE" == "caddy" ]]; then
    if (( CADDY_ATTACH_EXISTING )); then
      printf '  配置文件： %s（仅修改对应站点块，会先创建带时间戳备份）\n\n' "$CADDY_EXISTING_SITE_FILE"
    else
      printf '  配置文件： %s（会先创建带时间戳备份）\n\n' "$CADDYFILE"
    fi
  else
    printf '  配置文件： %s（会先创建带时间戳备份）\n\n' "$NGINX_CONFIG"
  fi
}

caddy_domain_begin_marker() { printf '%s: %s' "$BEGIN_MARKER" "$PROXY_KEY"; }
caddy_domain_end_marker()   { printf '%s: %s' "$END_MARKER" "$PROXY_KEY"; }

legacy_caddy_managed_domain() {
  local source_file="$1"
  awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
    $0 == begin { inside=1; next }
    inside && $0 == end { exit }
    inside && $0 ~ /^[[:space:]]*[A-Za-z0-9.-]+[[:space:]]*\{[[:space:]]*$/ {
      line=$0
      sub(/^[[:space:]]*/, "", line)
      sub(/[[:space:]]*\{[[:space:]]*$/, "", line)
      print line
      exit
    }
  ' "$source_file"
}

validate_caddy_managed_markers() {
  local source_file="$1" domain_begin domain_end
  local legacy_begins legacy_ends domain_begins domain_ends legacy_domain
  domain_begin="$(caddy_domain_begin_marker)"
  domain_end="$(caddy_domain_end_marker)"
  legacy_begins="$(grep -cFx "$BEGIN_MARKER" "$source_file" 2>/dev/null || true)"
  legacy_ends="$(grep -cFx "$END_MARKER" "$source_file" 2>/dev/null || true)"
  domain_begins="$(grep -cFx "$domain_begin" "$source_file" 2>/dev/null || true)"
  domain_ends="$(grep -cFx "$domain_end" "$source_file" 2>/dev/null || true)"
  [[ "$legacy_begins" == "$legacy_ends" && "$legacy_begins" -le 1 ]] || \
    die "检测到不完整或重复的旧版脚本托管标记，请检查 ${CADDYFILE}。"
  [[ "$domain_begins" == "$domain_ends" && "$domain_begins" -le 1 ]] || \
    die "域名 $PROXY_DOMAIN 的 Caddy 托管标记不完整或重复，请检查 ${CADDYFILE}。"
  legacy_domain="$(legacy_caddy_managed_domain "$source_file")"
  if [[ "$HTTPS_PORT" == "443" && "$legacy_domain" == "$PROXY_DOMAIN" && "$domain_begins" -eq 1 ]]; then
    die "域名 $PROXY_DOMAIN 同时存在旧版和新版托管块，请人工合并后重试。"
  fi
}

strip_current_caddy_managed() {
  local source_file="$1" target_file="$2" domain_begin domain_end legacy_domain
  domain_begin="$(caddy_domain_begin_marker)"
  domain_end="$(caddy_domain_end_marker)"
  legacy_domain="$(legacy_caddy_managed_domain "$source_file")"
  awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" \
      -v domain_begin="$domain_begin" -v domain_end="$domain_end" \
      -v legacy_domain="$legacy_domain" -v current_domain="$([[ "$HTTPS_PORT" == "443" ]] && printf '%s' "$PROXY_DOMAIN" || true)" '
    $0 == domain_begin { skipping_domain=1; next }
    skipping_domain && $0 == domain_end { skipping_domain=0; next }
    $0 == begin && legacy_domain == current_domain { skipping_legacy=1; next }
    skipping_legacy && $0 == end { skipping_legacy=0; next }
    !skipping_domain && !skipping_legacy { print }
  ' "$source_file" >"$target_file"
}

emit_caddy_header_rewrites() {
  local route_path="$1" upstream_host="$2" escaped_host escaped_route public_prefix
  escaped_host="${upstream_host//./\\.}"
  public_prefix=""
  [[ "$route_path" == "/" ]] || public_prefix="$route_path"

  # 仅识别当前固定源站和根相对 URL。由源站返回的第三方绝对 URL 不会被改写。
  printf '            header_down Location "(?i)^https?://%s(?::[0-9]+)?$" "%s%s/"\n' \
    "$escaped_host" "$PUBLIC_BASE_URL" "$public_prefix"
  printf '            header_down Location "(?i)^https?://%s(?::[0-9]+)?/(.*)$" "%s%s/$1"\n' \
    "$escaped_host" "$PUBLIC_BASE_URL" "$public_prefix"
  printf '            header_down Content-Location "(?i)^https?://%s(?::[0-9]+)?$" "%s%s/"\n' \
    "$escaped_host" "$PUBLIC_BASE_URL" "$public_prefix"
  printf '            header_down Content-Location "(?i)^https?://%s(?::[0-9]+)?/(.*)$" "%s%s/$1"\n' \
    "$escaped_host" "$PUBLIC_BASE_URL" "$public_prefix"
  if [[ "$route_path" == "/" ]]; then
    printf '            header_down Location "^/(.*)$" "/$1"\n'
    printf '            header_down Content-Location "^/(.*)$" "/$1"\n'
  else
    # 先保护已经带前缀的相对 URL，再改写其余根相对 URL，最后恢复；避免 /a 变成 /a/a。
    escaped_route="${route_path//./\\.}"
    printf '            header_down Location "^%s(?:/(.*))?$" "emby-proxy-prefix-preserved://$1"\n' "$escaped_route"
    printf '            header_down Location "^/(.*)$" "%s/$1"\n' "$public_prefix"
    printf '            header_down Location "^emby-proxy-prefix-preserved://(.*)$" "%s/$1"\n' "$public_prefix"
    printf '            header_down Content-Location "^%s(?:/(.*))?$" "emby-proxy-prefix-preserved://$1"\n' "$escaped_route"
    printf '            header_down Content-Location "^/(.*)$" "%s/$1"\n' "$public_prefix"
    printf '            header_down Content-Location "^emby-proxy-prefix-preserved://(.*)$" "%s/$1"\n' "$public_prefix"
  fi
}

strip_existing_caddy_route_block() {
  local source_file="$1" target_file="$2" route_path="$3" begin end begins ends
  begin="$(existing_caddy_route_begin_marker "$route_path")"
  end="$(existing_caddy_route_end_marker "$route_path")"
  begins="$(grep -cFx "$begin" "$source_file" 2>/dev/null || true)"
  ends="$(grep -cFx "$end" "$source_file" 2>/dev/null || true)"
  [[ "$begins" == "$ends" && "$begins" -le 1 ]] || \
    die "路径 $route_path 的脚本托管标记不完整或重复，请检查 ${CADDY_EXISTING_SITE_FILE}。"
  awk -v begin="$begin" -v end="$end" '
    $0 == begin { skipping=1; next }
    skipping && $0 == end { skipping=0; next }
    !skipping { print }
  ' "$source_file" >"$target_file"
}

emit_existing_caddy_route() {
  local route_index="$1" route_path upstream upstream_host health_path begin end
  route_path="${ROUTE_PATHS[$route_index]}"
  upstream="${ROUTE_URLS[$route_index]}"
  upstream_host="${ROUTE_HOSTS[$route_index]}"
  health_path="${route_path}${HEALTH_PATH}"
  begin="$(existing_caddy_route_begin_marker "$route_path")"
  end="$(existing_caddy_route_end_marker "$route_path")"
  cat <<EOF
$begin
    redir $route_path ${route_path}/ 308
    handle $health_path {
        respond "ok" 200
    }
    handle_path ${route_path}/* {
        reverse_proxy $upstream {
            header_up X-Forwarded-Prefix $route_path
            header_up Host {upstream_hostport}
EOF
  emit_caddy_header_rewrites "$route_path" "$upstream_host"
  cat <<EOF
        }
    }
$end
EOF
}

build_existing_caddy_candidate() {
  local source_file="$1" candidate="$2" work next location close_line i
  work="$(mktemp /tmp/emby-caddy-existing-work.XXXXXX)"
  cp -a "$source_file" "$work"
  for ((i=0; i<${#ROUTE_PATHS[@]}; i++)); do
    next="$(mktemp /tmp/emby-caddy-existing-strip.XXXXXX)"
    strip_existing_caddy_route_block "$work" "$next" "${ROUTE_PATHS[$i]}"
    mv "$next" "$work"
  done
  location="$(find_caddy_site_in_file "$work" "$PROXY_DOMAIN" 2>/dev/null || true)"
  [[ -n "$location" ]] || {
    rm -f "$work"
    die "更新前无法再次定位 $PROXY_DOMAIN 的站点结束位置；原配置未修改。"
  }
  close_line="${location##*$'\t'}"
  {
    if (( close_line > 1 )); then sed -n "1,$((close_line-1))p" "$work"; fi
    printf '\n'
    for ((i=0; i<${#ROUTE_PATHS[@]}; i++)); do
      emit_existing_caddy_route "$i"
      printf '\n'
    done
    sed -n "${close_line},\$p" "$work"
  } >"$candidate"
  rm -f "$work"
}

build_candidate_config() {
  local source_file="$1" candidate="$2" site_address
  local i route_path upstream upstream_host length domain_begin domain_end
  validate_caddy_managed_markers "$source_file"
  strip_current_caddy_managed "$source_file" "$candidate"
  domain_begin="$(caddy_domain_begin_marker)"
  domain_end="$(caddy_domain_end_marker)"

  site_address="$PROXY_DOMAIN"
  [[ "$ACCESS_MODE" != "domain" || "$HTTPS_PORT" == "443" ]] || site_address="https://${PROXY_DOMAIN}:${HTTPS_PORT}"
  [[ "$ACCESS_MODE" == "ip" ]] && site_address="http://${PROXY_IP}:${LISTEN_PORT}"

  # 上游地址经过严格白名单校验，可安全写入 Caddyfile。
  {
    printf '\n%s\n' "$domain_begin"
    printf '%s {\n' "$site_address"
    cat <<EOF
    log {
        output file $CADDY_ACCESS_LOG {
            mode 0640
            roll_size 100MiB
            roll_keep 5
            roll_keep_for 720h
        }
        # Emby token 常在查询参数或自定义头中；日志保留路径、字节数和耗时，但隐藏凭据。
        format filter {
            request>uri query {
                replace api_key REDACTED
                replace ApiKey REDACTED
                replace token REDACTED
                replace access_token REDACTED
            }
            request>headers>X-Emby-Token delete
            request>headers>X-MediaBrowser-Token delete
            wrap json
        }
    }

    handle $HEALTH_PATH {
        respond "ok" 200
    }

EOF
    # 精确路径先跳转到带斜杠形式；更长的子路径必须排在更短路径之前。
    while IFS=$'\t' read -r length i; do
      [[ -n "$i" ]] || continue
      route_path="${ROUTE_PATHS[$i]}"
      upstream="${ROUTE_URLS[$i]}"
      upstream_host="${ROUTE_HOSTS[$i]}"
      printf '    redir %s %s/ 308\n' "$route_path" "$route_path"
      printf '    handle_path %s/* {\n' "$route_path"
      printf '        reverse_proxy %s {\n' "$upstream"
      printf '            header_up X-Forwarded-Prefix %s\n' "$route_path"
      # HTTP 与 HTTPS 回源都固定 Host，绝不把客户端提供的任意 Host 传给源站。
      printf '            header_up Host {upstream_hostport}\n'
      emit_caddy_header_rewrites "$route_path" "$upstream_host"
      printf '        }\n'
      printf '    }\n'
    done < <(
      for ((i=1; i<${#ROUTE_PATHS[@]}; i++)); do
        printf '%06d\t%d\n' "${#ROUTE_PATHS[$i]}" "$i"
      done | sort -rn -k1,1
    )

    printf '    handle {\n'
    upstream="${ROUTE_URLS[0]}"
    upstream_host="${ROUTE_HOSTS[0]}"
    printf '        reverse_proxy %s {\n' "$upstream"
    printf '            header_up Host {upstream_hostport}\n'
    emit_caddy_header_rewrites "/" "$upstream_host"
    printf '        }\n'
    printf '    }\n'
    printf '}\n%s\n' "$domain_end"
  } >>"$candidate"
}

check_caddy_domain_conflict() {
  local cleaned other_conflict="" domain_pattern
  (( CADDY_ATTACH_EXISTING )) && return 0
  if [[ "$ACCESS_MODE" == "ip" ]]; then
    # 同一端口上的其他显式主机可以由 Caddy 安全分流；但精确 IP 或 :PORT 通配站点会与本入口重叠。
    domain_pattern="(http://${PROXY_IP//./\\.}:${LISTEN_PORT}([[:space:]]|\\{|,|$)|^[[:space:]]*(http://)?(:|\\*:)${LISTEN_PORT}([[:space:]]|\\{|,|$))"
  else
    if [[ "$HTTPS_PORT" == "443" ]]; then
      domain_pattern="(^|[[:space:],])((https://)?${PROXY_DOMAIN//./\\.})([[:space:],{]|$)"
    else
      domain_pattern="(^|[[:space:],])((https://)?${PROXY_DOMAIN//./\\.}):${HTTPS_PORT}([[:space:],{]|$)"
    fi
  fi
  cleaned="$(mktemp /tmp/emby-caddy-existing.XXXXXX)"
  if [[ -f "$CADDYFILE" ]]; then
    validate_caddy_managed_markers "$CADDYFILE"
    strip_current_caddy_managed "$CADDYFILE" "$cleaned"
    if grep -E "$domain_pattern" "$cleaned" >/dev/null 2>&1; then
      rm -f "$cleaned"
      die "入口 $PUBLIC_BASE_URL 已存在于原 $CADDYFILE 中。为避免覆盖原站点，脚本不会修改它。"
    fi
  fi
  rm -f "$cleaned"

  if [[ -d /etc/caddy ]]; then
    other_conflict="$(grep -RIlE --exclude='Caddyfile' --exclude='*.bak-*' --exclude='Caddyfile.candidate.*' \
      "$domain_pattern" /etc/caddy 2>/dev/null | head -n 1 || true)"
  fi
  if [[ -n "$other_conflict" ]]; then
    die "入口 $PUBLIC_BASE_URL 已存在于其他 Caddy 配置：${other_conflict}。为避免影响原站点，请先人工确认。"
  fi
}

configure_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    if [[ "$ACCESS_MODE" == "ip" ]]; then
      info "检测到 UFW 已启用，放行 TCP ${LISTEN_PORT}……"
      ufw allow "$LISTEN_PORT/tcp" >/dev/null
    else
      info "检测到 UFW 已启用，放行 TCP 80/${HTTPS_PORT}……"
      ufw allow 80/tcp >/dev/null
      ufw allow "$HTTPS_PORT/tcp" >/dev/null
    fi
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    if [[ "$ACCESS_MODE" == "ip" ]]; then
      info "检测到 firewalld 已启用，放行 TCP ${LISTEN_PORT}……"
      firewall-cmd --permanent --add-port="$LISTEN_PORT/tcp" >/dev/null
    else
      info "检测到 firewalld 已启用，放行 TCP 80/${HTTPS_PORT}……"
      firewall-cmd --permanent --add-port=80/tcp >/dev/null
      firewall-cmd --permanent --add-port="$HTTPS_PORT/tcp" >/dev/null
    fi
    firewall-cmd --reload >/dev/null
  fi
  printf '\n%s【必须放行端口】%s\n' "$YELLOW$BOLD" "$RESET" >&2
  if [[ "$ACCESS_MODE" == "ip" ]]; then
    warn "请在 VPS 厂商防火墙/云安全组中放行入站 TCP ${LISTEN_PORT}；否则本机配置正确，公网也无法访问。"
  elif [[ "$HTTPS_PORT" == "443" ]]; then
    warn "请在 VPS 厂商防火墙/云安全组中放行入站 TCP 80 和 443（证书申请/续期 + HTTPS 访问）。"
  else
    warn "请在 VPS 厂商防火墙/云安全组中放行入站 TCP 80 和 ${HTTPS_PORT}（证书申请/续期 + 自定义 HTTPS 访问）。"
    warn "访问地址必须带端口：${PUBLIC_BASE_URL}/"
  fi
  warn "脚本只能自动处理已启用的 UFW/firewalld，无法替你修改云厂商安全组。"
  return 0
}

apply_existing_caddy_routes() {
  local timestamp candidate target="$CADDY_EXISTING_SITE_FILE"
  timestamp="$(date +%Y%m%d-%H%M%S)"
  [[ -f "$target" ]] || die "已有 Caddy 站点文件不存在：$target"
  BACKUP_FILE="${target}.bak-${timestamp}"
  cp -a "$target" "$BACKUP_FILE"
  candidate="$(mktemp /tmp/emby-caddy-existing-candidate.XXXXXX)"
  trap 'rm -f "${candidate:-}"' RETURN
  build_existing_caddy_candidate "$target" "$candidate"
  install -o root -g root -m 0644 "$candidate" "$target"

  info "验证包含原有站点和新增路径的完整 Caddy 配置……"
  if ! caddy validate --config "$CADDYFILE" --adapter caddyfile; then
    cp -a "$BACKUP_FILE" "$target"
    trap - RETURN
    rm -f "$candidate"
    die "新增路径的候选配置验证失败，已恢复原文件：$BACKUP_FILE"
  fi
  if ! systemctl reload caddy; then
    cp -a "$BACKUP_FILE" "$target"
    systemctl reload caddy >/dev/null 2>&1 || true
    trap - RETURN
    rm -f "$candidate"
    die "Caddy 重载失败，已恢复原站点配置。查看日志：journalctl -u caddy -n 100 --no-pager"
  fi
  trap - RETURN
  rm -f "$candidate"
  ok "已在原 Caddy 域名中加入独立路径；原站点内容保留，备份：$BACKUP_FILE"
}

apply_config() {
  local timestamp candidate
  if (( CADDY_ATTACH_EXISTING )); then
    apply_existing_caddy_routes
    return
  fi
  timestamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p /etc/caddy
  if id caddy >/dev/null 2>&1; then
    install -d -o caddy -g caddy -m 0750 "$(dirname "$CADDY_ACCESS_LOG")"
    if [[ ! -e "$CADDY_ACCESS_LOG" ]]; then
      install -o caddy -g caddy -m 0640 /dev/null "$CADDY_ACCESS_LOG"
    else
      chown caddy:caddy "$CADDY_ACCESS_LOG"
      chmod 0640 "$CADDY_ACCESS_LOG"
    fi
  else
    # 官方软件包会创建 caddy 用户；这里只为兼容现有的 root 方式服务。
    install -d -o root -g root -m 0750 "$(dirname "$CADDY_ACCESS_LOG")"
    touch "$CADDY_ACCESS_LOG"
    chmod 0640 "$CADDY_ACCESS_LOG"
  fi
  [[ -f "$CADDYFILE" ]] || : >"$CADDYFILE"
  check_caddy_domain_conflict
  BACKUP_FILE="${CADDYFILE}.bak-${timestamp}"
  cp -a "$CADDYFILE" "$BACKUP_FILE"
  candidate="$(mktemp /etc/caddy/Caddyfile.candidate.XXXXXX)"
  trap 'rm -f "${candidate:-}"' RETURN
  build_candidate_config "$CADDYFILE" "$candidate"
  chmod 0644 "$candidate"

  info "验证候选 Caddy 配置……"
  if ! caddy validate --config "$candidate" --adapter caddyfile; then
    error "候选配置验证失败，原配置未被修改。候选文件：$candidate"
    trap - RETURN
    exit 1
  fi
  install -o root -g root -m 0644 "$candidate" "$CADDYFILE"

  systemctl enable caddy >/dev/null
  if systemctl is-active --quiet caddy; then
    if ! systemctl reload caddy; then
      cp -a "$BACKUP_FILE" "$CADDYFILE"
      systemctl reload caddy >/dev/null 2>&1 || true
      die "Caddy 重载失败，已自动恢复 ${BACKUP_FILE}。查看日志：journalctl -u caddy -n 100 --no-pager"
    fi
  else
    if ! systemctl start caddy; then
      cp -a "$BACKUP_FILE" "$CADDYFILE"
      systemctl restart caddy >/dev/null 2>&1 || true
      die "Caddy 启动失败，已恢复原配置。查看日志：journalctl -u caddy -n 100 --no-pager"
    fi
  fi
  trap - RETURN
  rm -f "$candidate"
  ok "配置已生效；备份：$BACKUP_FILE"
}

entry_status_code() {
  local request_path="$1"
  if [[ "$ACCESS_MODE" == "ip" ]]; then
    curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' \
      -H "Host: $PROXY_IP" --connect-timeout 5 --max-time 15 \
      "http://127.0.0.1:${LISTEN_PORT}${request_path}" 2>/dev/null || true
  else
    curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' \
      --resolve "$PROXY_DOMAIN:$HTTPS_PORT:127.0.0.1" \
      --connect-timeout 5 --max-time 15 "${PUBLIC_BASE_URL}${request_path}" 2>/dev/null || true
  fi
}

verify_result() {
  local attempt code="" health_code="" health_request_path="$HEALTH_PATH" max_attempts=18
  local service log_command access_log i request_path all_ok
  local -a route_codes=()
  service="$PROXY_ENGINE"
  if [[ "$ACCESS_MODE" == "ip" ]]; then
    info "验证 $PROXY_ENGINE IP HTTP 反代……"
    log_command="journalctl -u $PROXY_ENGINE -n 100 --no-pager"
    if [[ "$PROXY_ENGINE" == "caddy" ]]; then
      access_log="$CADDY_ACCESS_LOG"
    else
      access_log="$NGINX_ACCESS_LOG"
    fi
  elif [[ "$PROXY_ENGINE" == "caddy" ]]; then
    info "等待 Caddy 申请证书并验证 HTTPS（最多约 90 秒）……"
    log_command="journalctl -u caddy -n 100 --no-pager"
    if (( CADDY_ATTACH_EXISTING )); then
      health_request_path="${ROUTE_PATHS[0]}${HEALTH_PATH}"
      access_log=""
    else
      access_log="$CADDY_ACCESS_LOG"
    fi
  else
    info "验证 Nginx HTTPS 反代……"
    log_command="journalctl -u nginx -n 100 --no-pager"
    access_log="$NGINX_ACCESS_LOG"
  fi
  # Nginx reload 通过 HUP 异步切换 worker；立即探测可能仍命中旧配置。
  [[ "$PROXY_ENGINE" != "nginx" ]] || sleep 1
  for ((attempt=1; attempt<=max_attempts; attempt++)); do
    all_ok=1
    route_codes=()
    health_code="$(entry_status_code "$health_request_path")"
    [[ "$health_code" == "200" ]] || all_ok=0
    for ((i=0; i<${#ROUTE_PATHS[@]}; i++)); do
      request_path="${ROUTE_PATHS[$i]}"
      [[ "$request_path" == "/" ]] || request_path="${request_path}/"
      code="$(entry_status_code "$request_path")"
      route_codes+=("$code")
      [[ "$code" =~ ^[1-5][0-9][0-9]$ && "$code" != "000" ]] || all_ok=0
    done
    if (( all_ok )); then
      ok "代理存活检查通过：$PUBLIC_BASE_URL${health_request_path}（HTTP 200）。"
      for ((i=0; i<${#ROUTE_PATHS[@]}; i++)); do
        ok "路径 ${ROUTE_PATHS[$i]} 反代验证通过（HTTP ${route_codes[$i]}）。"
      done
      printf '\n%s部署完成！%s\n' "$GREEN$BOLD" "$RESET"
      printf '可用的 Emby 反代地址：\n'
      for ((i=0; i<${#ROUTE_PATHS[@]}; i++)); do
        if [[ "${ROUTE_PATHS[$i]}" == "/" ]]; then
          printf '  %s%s/%s\n' "$BOLD" "$PUBLIC_BASE_URL" "$RESET"
        else
          printf '  %s%s%s/%s\n' "$BOLD" "$PUBLIC_BASE_URL" "${ROUTE_PATHS[$i]}" "$RESET"
        fi
      done
      if [[ ${#ROUTE_PATHS[@]} -gt 1 || "${ROUTE_PATHS[0]}" != "/" ]]; then
        warn "路径模式会剥离 /a 等前缀再回源；请用完整路径测试 Web 与客户端。部分 Emby 客户端/Connect 可能不支持额外子路径。"
      fi
      printf '健康检查： %s%s%s%s\n' "$BOLD" "$PUBLIC_BASE_URL" "$health_request_path" "$RESET"
      if [[ "$ACCESS_MODE" == "ip" ]]; then
        warn "当前入口是明文 HTTP。请勿在不可信网络中直接传输管理员账号；长期公网使用建议完成备案后切换域名 HTTPS。"
      fi
      if [[ "$ACCESS_MODE" == "ip" ]]; then
        warn "再次确认：云安全组必须放行入站 TCP ${LISTEN_PORT}。"
      elif [[ "$HTTPS_PORT" == "443" ]]; then
        warn "再次确认：云安全组必须放行入站 TCP 80/443。"
      else
        warn "再次确认：云安全组必须放行入站 TCP 80/${HTTPS_PORT}，且客户端地址必须带 :${HTTPS_PORT}。"
      fi
      if [[ -n "$access_log" ]]; then
        printf '请求日志： %s%s%s（含响应字节数、总耗时及回源耗时，不记录 Nginx 查询参数；Caddy 会隐藏常见 Emby token）\n' \
          "$BOLD" "$access_log" "$RESET"
        printf '实时查看： sudo tail -F %q\n' "$access_log"
        printf '媒体过滤： sudo tail -F %q | grep -Ei '\''/Videos/|/Audio/|/stream|\\.m3u8'\''\n' "$access_log"
      else
        printf '请求日志： 沿用现有 Caddy 站点的日志设置；脚本不会擅自改变整站日志。\n'
      fi
      return 0
    fi
    sleep 5
  done

  error "$service 已运行，但健康检查或至少一个路径的端到端验证未通过。"
  printf '  健康检查 %-16s HTTP %s\n' "$health_request_path" "${health_code:-无响应}" >&2
  for ((i=0; i<${#ROUTE_PATHS[@]}; i++)); do
    printf '  路径 %-16s HTTP %s，源站 %s\n' "${ROUTE_PATHS[$i]}" "${route_codes[$i]:-无响应}" "${ROUTE_URLS[$i]}" >&2
  done
  if [[ "$ACCESS_MODE" == "ip" ]]; then
    cat >&2 <<EOF
请按顺序检查：
  1. 云厂商安全组是否放行入站 TCP ${LISTEN_PORT}；
  2. 查看代理日志：$log_command
  3. 查看端口监听：ss -lntp | grep -E ':${LISTEN_PORT}\\b'
  4. 本机入口测试：curl -v -H 'Host: $PROXY_IP' 'http://127.0.0.1:${LISTEN_PORT}/'
  5. 按上方列表逐个测试源站：curl -v --connect-timeout 10 '源站地址/'

配置验证及重载已经成功，因此没有自动回滚。原配置备份在：$BACKUP_FILE
EOF
  else
    cat >&2 <<EOF
请按顺序检查：
  1. 云厂商安全组/防火墙是否放行入站 TCP 80、443；
  2. DNS A/AAAA 是否仍指向本 VPS，Cloudflare 是否为“仅 DNS（灰云）”；
  3. 查看证书/代理日志：$log_command
  4. 查看端口监听：ss -lntp | grep -E ':(80|443)\\b'
  5. 按上方列表逐个测试源站：curl -v --connect-timeout 10 '源站地址/'

配置验证及重载已经成功，因此没有自动回滚。原配置备份在：$BACKUP_FILE
EOF
  fi
  return 1
}

main() {
  require_root
  acquire_operation_lock
  printf '%sEmby 一键反向代理配置器（域名 HTTPS / IP HTTP，Caddy / Nginx）%s\n\n' "$BOLD" "$RESET"
  check_platform
  if (( BOOTSTRAP_MENU )); then
    # 首次执行只部署管理层，不安装 Web 服务、不创建入口，也不碰现有配置。
    # 用户从管理菜单选择“新增反代入口”后，才进入完整的服务检查和配置向导。
    detect_existing_services
    apt_install_prerequisites
    install_manager_command current || die "无法安装当前管理菜单；没有修改 Caddy/Nginx 或创建反代入口。"
    [[ -x "$MANAGER_BIN" ]] || die "管理命令安装失败，请检查 GitHub 网络连接后重试。"
    release_operation_lock
    ok "管理菜单安装完成；本次没有安装或修改 Caddy/Nginx，也没有新增任何反代入口。"
    info "正在打开管理菜单，请选择“3. 新增反代入口”开始配置。"
    exec "$MANAGER_BIN"
  fi
  if (( MANAGER_ONLY )); then
    apt_install_prerequisites
    install_manager_command
    [[ -x "$MANAGER_BIN" ]] || die "管理命令安装失败，请检查 GitHub 网络连接后重试。"
    release_operation_lock
    "$MANAGER_BIN" import || warn "管理命令已安装，但旧配置自动导入未完成；稍后运行 sudo emby-proxy import 重试。"
    ok "管理命令准备完成。运行：sudo emby-proxy"
    return
  fi
  prompt_inputs
  apt_install_prerequisites
  install_manager_command
  prepare_access_target
  prepare_routes
  check_port_conflicts
  if [[ "$PROXY_ENGINE" == "caddy" ]]; then
    install_caddy
  else
    install_nginx
  fi
  show_plan
  configure_firewall
  if [[ "$PROXY_ENGINE" == "caddy" ]]; then
    apply_config
  else
    apply_nginx_config
  fi
  verify_result
  persist_site_state
}

if [[ "${EMBY_PROXY_LIB_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
