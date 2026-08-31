#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
MANAGER="$ROOT_DIR/emby-proxy"
INSTALLER="$ROOT_DIR/setup-emby-proxy.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_trace() { grep -Fx -- "$2" "$1" >/dev/null || fail "$1 缺少流程：$2"; }

# 真实入口选择器必须只把 ID 返回给命令替换，不能把表格和提示混入 ID。
mkdir -p "$TMP_DIR/selector/sites.d" "$TMP_DIR/selector/backups"
cat >"$TMP_DIR/selector/sites.d/domain-select.example.com.json" <<'JSON'
{"id":"domain-select.example.com","engine":"caddy","domain":"select.example.com","listen_port":443,"public_url":"https://select.example.com","managed_kind":"standalone","routes":[{"path":"/","upstream":"https://origin.example.com"}]}
JSON
EMBY_PROXY_STATE_HOME="$TMP_DIR/selector" EMBY_PROXY_NO_CLEAR=1 EMBY_PROXY_NO_PAUSE=1 \
EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" bash -c '
  set --; source "$MANAGER_UNDER_TEST"
  selected="$(select_site_id)"
  [[ "$selected" == domain-select.example.com ]]
' <<<'1' 2>"$TMP_DIR/selector-menu.out" || fail "入口选择器返回值混入了菜单文本"
grep -F 'https://select.example.com' "$TMP_DIR/selector-menu.out" >/dev/null || fail "入口选择器没有显示候选列表"
if EMBY_PROXY_STATE_HOME="$TMP_DIR/selector" EMBY_PROXY_NO_CLEAR=1 EMBY_PROXY_NO_PAUSE=1 \
EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" bash -c '
  set --; source "$MANAGER_UNDER_TEST"; select_site_id
' <<<'99' >"$TMP_DIR/selector-invalid.id" 2>"$TMP_DIR/selector-invalid.out"; then
  fail "无效入口序号仍返回成功"
fi
[[ ! -s "$TMP_DIR/selector-invalid.id" ]] || fail "无效入口序号输出了伪造入口 ID"
grep -F '已返回上一级菜单' "$TMP_DIR/selector-invalid.out" >/dev/null || fail "无效入口序号没有返回提示"

# 复现真实交互：主菜单选 2 后输入错误入口序号，必须回到主菜单而不是退出脚本。
EMBY_PROXY_STATE_HOME="$TMP_DIR/selector" EMBY_PROXY_NO_CLEAR=1 EMBY_PROXY_NO_PAUSE=1 \
EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" bash -c '
  set --; source "$MANAGER_UNDER_TEST"
  print_status() { printf "status\n"; }
  main_menu
' <<'INPUT' >"$TMP_DIR/selector-return.out" 2>"$TMP_DIR/selector-return.err"
2
99
q
INPUT
[[ "$(grep -c 'Emby 反向代理管理面板' "$TMP_DIR/selector-return.out")" -ge 2 ]] || fail "无效入口序号后没有回到主菜单"
grep -F '已返回上一级菜单' "$TMP_DIR/selector-return.err" >/dev/null || fail "主菜单没有显示返回提示"

# 主面板：无效输入应留在菜单；1-12 与 q 都必须正确分发。
TRACE="$TMP_DIR/main.trace"
TRACE="$TRACE" EMBY_PROXY_NO_CLEAR=1 EMBY_PROXY_NO_PAUSE=1 \
EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" bash -c '
  set --; source "$MANAGER_UNDER_TEST"
  require_jq() { :; }; ensure_state_dirs() { :; }; site_count() { printf 1; }
  print_status() { printf "status\n"; }; select_site_id() { printf domain-test.example.com; }
  list_sites() { printf "list\n" >>"$TRACE"; }
  show_site() { printf "show %s\n" "$1" >>"$TRACE"; }
  run_add_wizard() { printf "add\n" >>"$TRACE"; }
  manage_site_menu() { printf "manage %s\n" "$1" >>"$TRACE"; }
  run_doctor() { printf "doctor %s\n" "${1:-all}" >>"$TRACE"; }
  logs_stats_menu() { printf "logs\n" >>"$TRACE"; }
  backup_menu() { printf "backup\n" >>"$TRACE"; }
  service_menu() { printf "service\n" >>"$TRACE"; }
  import_existing() { printf "import\n" >>"$TRACE"; }
  self_update() { printf "update\n" >>"$TRACE"; }
  restart_updated_manager() { printf "restart_manager\n" >>"$TRACE"; }
  controller_menu() { printf "controller\n" >>"$TRACE"; }
  uninstall_manager() { UNINSTALL_COMPLETED=0; printf "uninstall\n" >>"$TRACE"; }
  main_menu
' <<'INPUT' >"$TMP_DIR/main.out" 2>"$TMP_DIR/main.err"
x
1
2
3
4
5
6
7
8
9
10
11
12
q
INPUT
for expected in list 'show domain-test.example.com' add 'manage domain-test.example.com' 'doctor all' logs backup service import update restart_manager controller uninstall; do
  assert_trace "$TRACE" "$expected"
done
grep -F '请输入有效序号' "$TMP_DIR/main.err" >/dev/null || fail "主菜单无效输入没有提示"
grep -F '入口配置' "$TMP_DIR/main.out" >/dev/null || fail "主菜单缺少美化分组"

# 多线路控制器子菜单：状态、DNS 同步和服务查看都必须能从菜单进入并返回。
mkdir -p "$TMP_DIR/controller/sites.d" "$TMP_DIR/controller/backups"
cat >"$TMP_DIR/controller/controller.json" <<'JSON'
{"schema_version":1,"entry_id":"domain-test.example.com","domain":"test.example.com","source":"https://origin.example.com","engine":"caddy","nodes":{},"enroll_tokens":{},"active_node":null}
JSON
TRACE="$TMP_DIR/controller.trace" EMBY_PROXY_CONTROLLER_STATE="$TMP_DIR/controller/controller.json" \
EMBY_PROXY_NO_CLEAR=1 EMBY_PROXY_NO_PAUSE=1 EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" \
bash -c '
  set --; source "$MANAGER_UNDER_TEST"
  controller_cli() { printf "controller %s\n" "$*" >>"$TRACE"; }
  systemctl() { printf "systemctl %s\n" "$*" >>"$TRACE"; return 0; }
  controller_menu
' <<'INPUT' >/dev/null
x
4
5
6
0
INPUT
grep -Fx 'controller status' "$TMP_DIR/controller.trace" >/dev/null || fail "控制器菜单未进入状态查看"
grep -Fx 'controller reconcile' "$TMP_DIR/controller.trace" >/dev/null || fail "控制器菜单未进入 DNS 同步"
grep -Fx 'systemctl --no-pager' "$TMP_DIR/controller.trace" >/dev/null || fail "控制器菜单未进入服务查看"

# 控制器初始化向导必须把用户输入完整传给底层 CLI。
TRACE="$TMP_DIR/controller-wizard.trace" EMBY_PROXY_CONTROLLER_STATE="$TMP_DIR/controller/new.json" \
EMBY_PROXY_NO_CLEAR=1 EMBY_PROXY_NO_PAUSE=1 EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" \
bash -c '
  set --; source "$MANAGER_UNDER_TEST"
  controller_cli() { printf "controller %s\n" "$*" >>"$TRACE"; }
  controller_init_menu
' <<'INPUT' >/dev/null

domain-test.example.com
test.example.com
https://origin.example.com
caddy
n
INPUT
grep -Fx 'controller init' "$TMP_DIR/controller-wizard.trace" >/dev/null || fail "控制器初始化向导未调用 init"

# 入口管理子菜单：覆盖 1-6、返回、以及独立的删除入口分支。
TRACE="$TMP_DIR/site.trace"
TRACE="$TRACE" EMBY_PROXY_NO_CLEAR=1 EMBY_PROXY_NO_PAUSE=1 \
EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" bash -c '
  set --; source "$MANAGER_UNDER_TEST"
  show_site() { :; }
  route_upsert() { printf "route_%s %s\n" "$1" "$2" >>"$TRACE"; }
  route_delete() { printf "route_delete %s\n" "$1" >>"$TRACE"; }
  run_doctor() { printf "doctor %s\n" "$1" >>"$TRACE"; }
  view_logs() { printf "logs %s %s\n" "$1" "$2" >>"$TRACE"; }
  show_stats() { printf "stats %s %s\n" "$1" "$2" >>"$TRACE"; }
  delete_site() { printf "delete %s\n" "$1" >>"$TRACE"; }
  manage_site_menu domain-test.example.com
' <<'INPUT' >/dev/null
1
2
3
4
5
6
0
INPUT
for expected in 'route_add domain-test.example.com' 'route_set domain-test.example.com' 'route_delete domain-test.example.com' 'doctor domain-test.example.com' 'logs domain-test.example.com --recent' 'stats domain-test.example.com 24h'; do
  assert_trace "$TRACE" "$expected"
done
TRACE="$TMP_DIR/site-delete.trace"
TRACE="$TRACE" EMBY_PROXY_NO_CLEAR=1 EMBY_PROXY_NO_PAUSE=1 \
EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" bash -c '
  set --; source "$MANAGER_UNDER_TEST"; show_site() { :; }; delete_site() { printf "delete %s\n" "$1" >>"$TRACE"; }; manage_site_menu domain-test.example.com
' <<<'7' >/dev/null
assert_trace "$TMP_DIR/site-delete.trace" 'delete domain-test.example.com'

# 子菜单操作内部即使调用 die，也只能结束本次操作，不能带着整个管理面板退出。
SURVIVED="$TMP_DIR/action-survived" EMBY_PROXY_NO_CLEAR=1 EMBY_PROXY_NO_PAUSE=1 \
EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" bash -c '
  set --; source "$MANAGER_UNDER_TEST"; show_site() { :; }
  route_upsert() { die "模拟输入错误"; }
  manage_site_menu domain-test.example.com
  printf survived >"$SURVIVED"
' <<'INPUT' >/dev/null 2>"$TMP_DIR/action-error.out"
1
0
INPUT
grep -Fx survived "$TMP_DIR/action-survived" >/dev/null || fail "子菜单操作错误导致整个面板退出"
grep -F '操作未完成，已返回当前菜单' "$TMP_DIR/action-error.out" >/dev/null || fail "子菜单错误没有返回提示"

# 日志、备份、服务三个子菜单覆盖全部选项并能返回上一级。
TRACE="$TMP_DIR/logs.trace"
TRACE="$TRACE" EMBY_PROXY_NO_CLEAR=1 EMBY_PROXY_NO_PAUSE=1 \
EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" bash -c '
  set --; source "$MANAGER_UNDER_TEST"; select_site_id() { printf domain-test.example.com; }
  view_logs() { printf "logs %s %s %s\n" "$1" "$2" "${3:-}" >>"$TRACE"; }
  show_stats() { printf "stats %s %s\n" "$1" "$2" >>"$TRACE"; }
  logs_stats_menu
' <<'INPUT' >/dev/null
1
2
3
4
5
3.5
6
7
0
INPUT
for expected in 'logs domain-test.example.com --recent ' 'logs domain-test.example.com --follow ' 'logs domain-test.example.com --media ' 'logs domain-test.example.com --errors ' 'logs domain-test.example.com --slow 3.5' 'stats domain-test.example.com 24h' 'stats domain-test.example.com 7d'; do assert_trace "$TRACE" "$expected"; done

TRACE="$TMP_DIR/backup.trace"
TRACE="$TRACE" EMBY_PROXY_NO_CLEAR=1 EMBY_PROXY_NO_PAUSE=1 \
EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" bash -c '
  set --; source "$MANAGER_UNDER_TEST"
  backup_list() { printf "list\n" >>"$TRACE"; }; backup_show() { printf "show %s\n" "$1" >>"$TRACE"; }
  restore_backup() { printf "restore %s\n" "$1" >>"$TRACE"; }; backup_clean() { printf "clean %s\n" "$1" >>"$TRACE"; }
  backup_menu
' <<'INPUT' >/dev/null
1
2
backup-a
3
backup-b
4
15
0
INPUT
for expected in list 'show backup-a' 'restore backup-b' 'clean 15'; do assert_trace "$TRACE" "$expected"; done

TRACE="$TMP_DIR/service.trace"
TRACE="$TRACE" EMBY_PROXY_NO_CLEAR=1 EMBY_PROXY_NO_PAUSE=1 \
EMBY_PROXY_MANAGER_LIB_ONLY=1 MANAGER_UNDER_TEST="$MANAGER" bash -c '
  set --; source "$MANAGER_UNDER_TEST"
  service_control() { printf "service %s %s\n" "$1" "${2:-}" >>"$TRACE"; }; config_test() { printf "config_test\n" >>"$TRACE"; }
  service_menu
' <<'INPUT' >/dev/null
1
2
caddy
3
nginx
4
caddy
5
0
INPUT
for expected in 'service status ' 'service reload caddy' 'service restart nginx' 'service logs caddy' config_test; do assert_trace "$TRACE" "$expected"; done

# 安装向导引擎选项：无现有服务时 Caddy/Nginx 两条选择都可达。
for pair in '1 caddy' '2 nginx'; do
  choice="${pair%% *}"; expected="${pair##* }"
  OUT="$TMP_DIR/engine-$choice" EMBY_PROXY_FORCE_INTERACTIVE=1 EMBY_PROXY_LIB_ONLY=1 INSTALLER_UNDER_TEST="$INSTALLER" bash -c '
    set --; source "$INSTALLER_UNDER_TEST"
    detect_existing_services() { HAS_CADDY=0; HAS_NGINX=0; CADDY_ACTIVE=0; NGINX_ACTIVE=0; }
    select_proxy_engine
    printf "%s\n" "$PROXY_ENGINE" >"$OUT"
  ' <<<"$choice" >/dev/null
  grep -Fx "$expected" "$TMP_DIR/engine-$choice" >/dev/null || fail "引擎选项 $choice 未进入 $expected"
done

# 域名入口三种结构：子域名、独立 HTTPS 端口、路径高级模式都完成到最终状态。
run_domain_flow() {
  local mode="$1" input="$2" expected_type="$3" expected_port="$4"
  OUT="$TMP_DIR/domain-$mode" EMBY_PROXY_FORCE_INTERACTIVE=1 EMBY_PROXY_LIB_ONLY=1 INSTALLER_UNDER_TEST="$INSTALLER" bash -c '
    set --; source "$INSTALLER_UNDER_TEST"
    select_proxy_engine() { PROXY_ENGINE=caddy; }
    detect_existing_caddy_domain_mode() { :; }
    prompt_inputs
    printf "%s|%s|%s|%s|%s\n" "$DOMAIN_ENTRY_TYPE" "$HTTPS_PORT" "$PROXY_DOMAIN" "${ROUTE_PATHS[0]}" "${ROUTE_INPUTS[0]}" >"$OUT"
  ' <<<"$input" >/dev/null 2>"$TMP_DIR/domain-$mode.err"
  grep -Fx "$expected_type|$expected_port|emby-$mode.example.com|/|https://origin-$mode.example.com" "$TMP_DIR/domain-$mode" >/dev/null || fail "域名入口模式 $mode 流程错误"
}
run_domain_flow subdomain $'1\nemby-subdomain.example.com\nhttps://origin-subdomain.example.com' subdomain 443
run_domain_flow port $'2\n18443\nemby-port.example.com\nhttps://origin-port.example.com' port 18443
run_domain_flow path $'3\nemby-path.example.com\nhttps://origin-path.example.com\nn' path 443

printf 'PASS: polished main/sub menus, invalid input recovery, all manager choices, both engines, all domain entry modes\n'
