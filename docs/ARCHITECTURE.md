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
controller init → controller.json
controller issue → 一次性注册命令（默认不携带边缘 IP）
node-install → 边缘自动检测公网 IPv4 → POST /enroll → 节点配置/服务/定时器
node → POST /heartbeat → 健康、用量、last_seen
serve 的周期 reconcile → select → Cloudflare A 记录更新
```
控制器不承载媒体流量。这是按优先级选择单个活动节点的 DNS 切换，不是逐请求负载均衡。
DNS 缓存与已有播放连接不会随 A 记录立即迁移。

## 关键模块

| 文件/函数 | 职责 | 优先阅读的测试 |
|---|---|---|
| `setup-emby-proxy.sh`: `main`, `prompt_inputs` | 首装菜单、部署向导 | `test-cli.sh`, `test-menu-flows.sh` |
| 安装器配置生成/写入函数 | Caddy/Nginx、路径兼容、托管标记 | `test-config-generation.sh` |
| `emby-proxy`: `main`, `main_menu`, `menu_run` | CLI/菜单分发、操作失败隔离 | `test-menu-flows.sh` |
| `self_update`, `menu_update`, `restart_updated_manager` | 下载、校验、安装、自动重新进入菜单 | `test-manager-stage2.sh`, `test-menu-update.sh` |
| `route_upsert`, `delete_site`, 备份函数 | 索引重放、安全增删和恢复 | `test-manager.sh`, `test-manager-stage2.sh` |
| `controller_cli` 内嵌 Python | 注册、心跳、选路、DNS 和 systemd | `test-controller.sh`, `test-controller-model.py` |

## 状态与信任边界

- `/etc/emby-proxy/sites.d/*.json`：入口 ID、域名、端口、引擎、路径映射及托管配置位置。
  索引不是运行中的 Web 配置；诊断时必须比较实际配置/服务。
- `/etc/emby-proxy/backups/`：修改/更新前备份及校验信息。
- `controller.json`：入口、待使用注册码、节点及 DNS 状态；进程锁+文件锁协调读写。
- `multiline-node.json`：边缘节点与主控关系、节点令牌、用量文件路径。
- `/var/lib/emby-proxy/used_bytes`：边缘从托管 Caddy/Nginx JSON 访问日志累计的响应字节；`usage.offset` 记录日志 inode/偏移，轮转或截断后自动从头读取新文件。
- `/status` 只用于添加节点时核对入口 ID，只返回入口 ID 和域名；完整节点状态仅由本机 CLI 读取。仍应放在 HTTPS、WireGuard 或 IP 白名单之后。
- `/reconcile` 不再提供公网 POST 路由；主控服务直接调用本地状态机，避免未认证请求触发 DNS 变更。
- `/revoke` 只接受已注册节点令牌，用于边缘安装事务失败时撤销刚建立的节点；主控不会提供未认证的节点删除接口。
- 同源 SHA256 清单用于检测文件一致性，不等同于独立签名或可信发布认证。

## 实验功能的实际边界

`node_once` 当前同时检查 Web 服务进程和本机 `https://域名/_emby_proxy_health`（使用 `--resolve` 指向 127.0.0.1，保持 TLS 校验），**仍尚未证明源站或媒体播放正常**。
边缘已形成基于 JSON 访问日志的累计读取和轮转处理，**仍没有账期重置、跨多日志文件补偿或“只统计媒体响应”的精细口径**。
控制器状态文件使用 0600；已有状态的 `init` 必须显式 `--force`，并先保存带时间戳的备份。注册码使用后删除，且 15 分钟后失效。
这些需要独立设计与回归，不应因为几个模拟切换测试通过就宣布生产可用。
