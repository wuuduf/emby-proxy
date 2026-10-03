# 架构与代码阅读顺序

## 分发与安装

```text
setup-emby-proxy.sh（无参数）
  → 检查平台/安装管理命令
  → emby-proxy 主菜单（ep 是短链接）
  → 新增入口向导
  → 安装后端生成固定回源配置
  → 备份/校验/reload
  → sites.d 管理索引
```

安装后的 manager 位于 `/usr/local/sbin/emby-proxy`，后端位于
`/usr/local/lib/emby-proxy/setup-emby-proxy.sh`。线上不依赖仓库的 `scripts/` 或 `docs/`。

## 两条数据流

**媒体流量**：客户端 → 域名 HTTPS → Caddy/Nginx → 固定 Emby 源站。

**多线路实验控制面**：
```text
controller init → 业务入口域名 + 可选独立主控域名 → controller.json
controller issue → 一次性注册命令（默认不携带边缘 IP）
node-install → 边缘按入口地址族自动检测公网 IPv4/IPv6 / 本机引擎预检 → POST /enroll → 节点配置/服务/定时器
node → POST /heartbeat → 健康、用量、last_seen
serve 的周期 reconcile → 带防抖/冷却的 select → DNS Provider 写入 + API 回读确认
```
控制器不承载媒体流量。这是按优先级选择单个活动节点的 DNS 切换，不是逐请求负载均衡。
DNS 缓存与已有播放连接不会随 A 记录立即迁移。

Telegram Bot 是主控侧的只读运维面：主控通过 HTTPS 长轮询 Telegram API，不开放入站 Bot 端口；只有主控启用 Bot 后，边缘心跳才附带有界的最近 5 分钟聚合指标（流量、请求、访问 IP、设备类别和路径），主控只保存白名单查询所需的摘要。访问日志读取有字节/行上限，采样截断会在结果中标记。停用 Bot 会清理已保存摘要。Bot Token 以 `600` 权限保存在主控，Chat ID 白名单在处理命令前校验。

DNS Provider 目前有两种：Cloudflare 单 A/AAAA 记录主备/多记录权重池，以及 DNSPod 四种线路记录（默认/电信/联通/移动）。入口初始化时固定地址族：IPv4 映射 A，IPv6 映射 AAAA；节点注册码、心跳和 DNS 回读都必须匹配该类型。Cloudflare 多记录模式把同名记录 ID 作为槽位，按节点权重展开后逐条修改并回读；节点不健康或超额时从池中摘除。DNSPod 模式先只读校验托管区域、子域委派和记录身份，再逐条修改并回读；每条线路可以是一条或多条记录，单条线路可指定节点或配置记录槽位权重，指定节点不健康或超额时回退到健康候选。发现冲突地址类型或 CNAME 时停止，避免双栈绕过控制器。父域 NS 委派由用户完成，控制器不提供未认证的父域写操作。
两种 Provider 都支持按主控服务器本地时间选择策略档位：Cloudflare 档位保存权重集合，DNSPod 档位保存运营商线路到节点的映射。计划只改变候选策略，健康、心跳和配额检查仍在其后执行。

## 关键模块

| 文件/函数 | 职责 | 优先阅读的测试 |
|---|---|---|
| `setup-emby-proxy.sh`: `main`, `prompt_inputs` | 首装菜单、部署向导 | `test-cli.sh`, `test-menu-flows.sh` |
| 安装器配置生成/写入函数 | Caddy/Nginx、路径兼容、托管标记 | `test-config-generation.sh` |
| `emby-proxy`: `main`, `main_menu`, `menu_run` | CLI/菜单分发、操作失败隔离 | `test-menu-flows.sh` |
| `self_update`, `menu_update`, `restart_updated_manager` | 下载、校验、安装、自动重新进入菜单 | `test-manager-stage2.sh`, `test-menu-update.sh` |
| `route_upsert`, `delete_site`, 备份函数 | 索引重放、安全增删和恢复 | `test-manager.sh`, `test-manager-stage2.sh` |
| `controller_cli` 内嵌 Python | 注册、心跳、选路、DNS 和 systemd | `test-controller.sh`, `test-controller-model.py`, `test-controller-failover.py` |

## 状态与信任边界

- `/etc/emby-proxy/sites.d/*.json`：入口 ID、域名、端口、引擎、路径映射及托管配置位置。
  索引不是运行中的 Web 配置；诊断时必须比较实际配置/服务。
- `/etc/emby-proxy/backups/`：修改/更新前备份及校验信息。
- `controller.json`：入口、待使用注册码、节点及 DNS 状态；进程锁+文件锁协调读写。
- `multiline-node.json`：边缘节点与主控关系、节点令牌、用量文件路径。
- `/var/lib/emby-proxy/used_bytes`：边缘从托管 Caddy/Nginx JSON 访问日志累计的响应字节；`usage.offset` 使用 v2 原子检查点记录累计值、日志 inode/device、偏移和上下文指纹，兼容旧格式并补偿保留的轮转归档。
- `/status` 只用于添加节点时核对入口 ID，只返回入口 ID 和域名；完整节点状态仅由本机 CLI 读取。仍应放在 HTTPS、WireGuard 或 IP 白名单之后。
- `/reconcile` 不再提供公网 POST 路由；主控服务直接调用本地状态机，避免未认证请求触发 DNS 变更。
- `/revoke` 只接受已注册节点令牌，用于边缘安装事务失败时撤销刚建立的节点；主控不会提供未认证的节点删除接口。
- 同源 SHA256 清单用于检测文件一致性，不等同于独立签名或可信发布认证。

## 实验功能的实际边界

`node_once` 当前同时检查 Web 服务进程和本机 `https://域名/_emby_proxy_health`（使用 `--resolve` 指向 127.0.0.1，保持 TLS 校验），**仍尚未证明源站或媒体播放正常**。
边缘已形成基于 JSON 访问日志的累计读取和轮转处理，支持保留窗口内的多归档补偿；**仍没有账期重置或“只统计媒体响应”的精细口径**。
控制器状态文件使用 0600；已有状态的 `init` 必须显式 `--force`，并先保存带时间戳的备份。注册码使用后删除，且 15 分钟后失效。
这些需要独立设计与回归，不应因为几个模拟切换测试通过就宣布生产可用。

## 可选集中证书

菜单 8 会按 DNS Provider 选择控制面 HTTPS：DNSPod/其他 DNS 使用 `https-proxy-setup`，Caddy 只监听 443 并反代到控制器本机 `127.0.0.1:19090`，由 Caddy 通过 HTTP-01 自动申请/续期证书；Cloudflare Token 仍使用 `cert-setup` 的 DNS-01，在控制器自己的端口启用原生 TLS。两种方式都不把未加密 19090 暴露公网。配置前备份 Caddyfile，遇到冲突、校验或 reload 失败恢复原文件；`/certificate` 只接受真实 TLS，或仅接受来自本机反代的 HTTPS 标记，并且始终要求本入口节点令牌；不允许 HTTP 重定向携带凭据。
边缘注册后从主控下载所属入口证书，经校验再使用版本目录 + current 原子切换；两种引擎通过 tls_directory 加载同一接口。独立 cert-renew 和 cert-sync 定时器管理续期；普通单机入口不改变原证书管理方式。详见 CERTIFICATES.md。
