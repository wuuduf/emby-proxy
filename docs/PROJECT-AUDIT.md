# 全项目审查与本轮修复

审查基线：当前工作树相对 `HEAD d6d3bc0` 的全部改动，覆盖安装器、菜单、内嵌控制器、Caddy/Nginx 配置、证书、多线路 DNS、节点心跳、卸载/更新和 Telegram 功能。审查遵循 `docs/REQUIREMENTS.md`。本轮后续在用户授权的测试 VPS 与 Cloudflare/DNSPod 测试域名上完成了受控验收；未配置 Telegram Bot。

## 结论

本轮没有发现会把客户端指定的任意公网目标变成通用代理的路径；源站仍由入口配置固定，边缘注册码一次性且有 TTL。高风险的输入、凭据日志和状态回滚问题已修复；稳定性回归已覆盖用量轮转、并发读取、部分 JSON 行、DNS 部分失败和 Telegram 服务重启。

## 已修复

### 安全

- 注册和心跳服务端校验节点 ID、优先级、配额、地址族和公网地址；拒绝环回、未指定、多播、保留地址和 IPv4/IPv6 混用。
- Caddy 主控站点只允许带脚本 owner marker 的块更新；非托管同名站点拒绝接管。卸载时同时清理主控 marker，保留其他站点。
- Caddy/Nginx 访问日志不再保存常见 Emby Authorization、Bearer、ApiKey 和 Token 头/查询参数。
- Caddy 访问日志删除完整 URI，只保留不含查询串的 `path` 字段；未知参数名和大小写变体不会落盘。
- `--tls-directory` 只允许脚本托管或 Certbot 证书树，并校验 PEM 解析路径，避免特权 `chown/chmod` 跟随外部符号链接。
- 主控和边缘心跳 systemd 单元启用最小权限隔离、地址族限制、文件描述符/任务上限和私有 umask。
- Telegram API 禁止重定向携带 Bot Token；响应体有大小上限，错误信息不回显远端详情或 Token。
- Telegram Token 必须为 `600` 文件；轮询只接受白名单 Chat ID 和命令，不回显普通聊天文本。
- 证书接口在直接 TLS 或本机反代标记为 HTTPS 时才允许取证书；伪造公网 `X-Forwarded-Proto` 不会被信任。

### 稳定性与数据一致性

- 边缘用量游标以单个 v2 检查点原子持久化累计值、inode/device、offset 和上下文指纹；兼容旧格式，并补偿 Nginx `.N/.N.gz` 与 Caddy 时间戳 `.log/.gz` 轮转。
- DNSPod 某条线路失败时保留全局待确认状态，下一轮继续重试，不把部分成功显示成全部成功。
- Telegram 配置先验证 Bot/测试消息，再原子发布 600 权限 Token 与状态；托管 unit 更新使用备份、真正 restart，失败恢复旧 unit 和状态，非托管同名 unit 不覆盖。
- 注册命令能力检测真实检查 `--address-family`，旧版 `ep` 不会被误判为兼容。
- IPv6 主控使用 `AF_INET6` 服务类，监听、健康检查和 DNS 记录类型与入口地址族一致。

### 性能与隐私

- 边缘只有在主控启用 Telegram 查询时才读取和上报访问摘要；停用后控制器删除已保存摘要。
- 访问指标读取固定尾部字节/行数，返回 `truncated` 和新鲜度信息，不再每 30 秒把整份历史日志读入内存。
- 指标数组、名称、数字和 Telegram 消息长度均有限制；无穷大、NaN、超大数和超长消息会被拒绝或截断。
- 告警先写本地有上限 outbox，再发送；Telegram 短时不可用不会丢失节点故障告警，也不会阻塞 DNS 主流程。
- Bot 轮询会把 offset 绑定到 Bot 指纹；轮换 Token/白名单时丢弃旧批次，回复的每个分片和告警的每个 Chat 都重新校验授权。
- 状态、游标和锁文件使用私有权限与 `O_NOFOLLOW`；主控、边缘、证书和 Telegram systemd 事务失败时会清理本次新建的孤儿单元。
- Telegram `/access`、`/devices` 只展示新鲜摘要；手工篡改的计数、优先级和时间字段不会让只读查询崩溃。
- 主控 Caddyfile 更新改为拒绝符号链接并使用文件/目录 `fsync` 后原子替换；卸载遇到 Caddy/Nginx 配置符号链接时只提醒、不跟随或删除目标。
- Caddy/Nginx 删除或附加路径变更同样拒绝符号链接配置，避免管理索引误指向原站文件。
- Bash 全局互斥锁不再用截断式重定向，首次创建使用私有权限与 `noclobber`，发现符号链接时失败关闭。

## 仍需明确的限制

- DNS 权重是 DNS 记录槽位的近似比例，受 TTL、递归缓存和已有播放连接影响，不是精确流量整形；实际切换应以控制器回读和节点用量为准。
- Cloudflare 普通 DNS API 不允许同名同类型的重复 IP 记录，无法用重复槽位表达任意 80/20；控制器会在 PUT 前拒绝这种权重以避免部分更新。精确权重需使用 Cloudflare Load Balancing 或支持权重的 DNS 服务。
- 若日志在两次心跳之间连续轮转并超过保留窗口，无法凭空恢复已删除的旧 inode；生产上应把心跳间隔和日志轮转保留数配套。
- Telegram 的“设备”是 User-Agent 粗粒度分类，不是 Emby 账号、播放器登录设备或用户身份；访问 IP 也只保留最近窗口的聚合 Top N。
- DNSPod 委派、Cloudflare DNS-01、Caddy/Nginx HTTPS、真实公网 IPv6 出口和一次故障切换已在测试环境验证；证书自动续期、递归 DNS 长缓存、运营商线路命中和客户端播放迁移仍需长期观测，不能由一次性验收保证。
- 控制器仍是单实例 JSON 状态机，适合单台主控；不应让多个独立主控同时写同一状态文件。
- 首次安装和更新仍使用 HTTPS 下载与同源 SHA256 清单；清单用于完整性校验，不等同于独立签名。生产环境应固定可信 release/tag，并在外部渠道核对发布摘要。
- 未启用 HTTPS/WireGuard 时的 HTTP 主控仅适合临时内网/实验；不要把注册码接口直接暴露到公网。
- 控制器管理的多线路边缘统一使用业务域名 443；独立 HTTPS 端口模式不自动纳入同一控制器池。

## 本轮验证

已通过：

```text
python3 tests/test-telegram.py                 8 tests
python3 tests/test-telegram-runtime.py        10 tests
python3 tests/test-access-metrics.py           9 tests
python3 tests/test-usage-consistency.py        8 tests
python3 tests/test-telegram-outbox.py           5 tests
python3 tests/test-telegram-poll.py            10 tests
python3 tests/test-state-unit-safety.py         13 tests
python3 tests/test-controller-model.py         39 tests
python3 tests/test-controller-failover.py     28 tests
python3 tests/test-controller-certificates.py   8 tests
python3 tests/test-menu-ux.py                  30 tests
bash tests/test-telegram-menu.sh
bash tests/test-config-generation.sh
bash tests/test-manager.sh
bash tests/test-uninstall-ownership.sh
bash tests/test-telegram-menu.sh
bash -n emby-proxy setup-emby-proxy.sh
git diff --check
```

最终发布前仍须运行 `python3 scripts/check.py`（包含 SHA256 校验），并在确认代码差异后重新生成 `checksums.txt`。

## 本轮真实验收摘要

- Cloudflare：测试主控域名使用 DNS-01 证书；两台 Caddy 边缘完成注册、证书同步和健康心跳。停止主节点后 A 记录切至备用，恢复满足防抖窗口后切回；80/20 权重因 API 重复记录限制被安全拒绝。
- DNSPod：测试区域完成 NS 委派检查和四线路（默认/电信/联通/移动）接管；Nginx 边缘成功申请 ACME 证书，记录逐条回读确认，业务路径回源得到源站 403，健康路径返回 200。
- IPv6：两台双栈节点从 VPS 侧验证 `curl -6` 出口；入口地址族仍按 IPv4/IPv6 分离配置，未把双栈地址混入同一入口。
