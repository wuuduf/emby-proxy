# 多机真实验收记录（2026-10-03）

本记录使用用户授权的测试 VPS、Cloudflare 和 DNSPod 测试区域。真实域名、地址和凭据不写入仓库。

## 测试拓扑

| 角色 | 地址 | 结果 |
| --- | --- | --- |
| Cloudflare 主控 | 测试主控 VPS | Caddy、DNS-01、19090 HTTPS 主控正常 |
| Cloudflare 边缘 | edge-a | Caddy、IPv4、证书同步、心跳正常 |
| Cloudflare 边缘 | edge-b | Caddy、IPv4/IPv6 出口、证书同步、心跳正常 |
| DNSPod Nginx 边缘 | edge-c | Nginx、HTTP-01、证书、四线路记录回读正常 |
| 其他测试机 | 其他授权 VPS | 仅安装/升级管理器并执行只读菜单检查，原入口未覆盖 |

## 已执行场景

1. 所有机器安装/升级 `emby-proxy` 管理器，验证 `ep version`、`ep list`。
2. Cloudflare：入口初始化、Zone/记录发现、Certbot DNS-01、主控 HTTPS、边缘注册、Caddy 配置、证书同步和心跳。
3. Cloudflare 故障切换：停止高优先级边缘，确认 A 记录切到备用；恢复心跳并等待恢复防抖窗口，确认记录切回。
4. Cloudflare 定时/权重：提交 `80/20` 后发现普通 DNS API 返回 `81058`；修复为 PUT 前预检拒绝，确认没有部分写入。
5. DNSPod：Token 校验、NS 委派检查、默认/电信/联通/移动四条 A 记录接管、Nginx ACME 证书、逐条修改和 `Record.Info` 回读。
6. 回源验证：`/_emby_proxy_health` 返回 `200`；源站首页返回 `403` 时仍按回源可达记录，不把源站业务状态误报为反代失败。
7. IPv6：在双栈边缘从 VPS 内用 `curl -6` 验证出站；代码和本地回归验证 A/AAAA 地址族隔离、Caddy/Nginx 单栈监听和地址校验。
8. 本地完整回归：`scripts/check.py` 22/22 套件通过，SHA256 和 `git diff --check` 通过。

## 发现并修复

- Cloudflare 普通 DNS 不允许同名同类型的重复 IP 记录，不能用重复槽位精确表达任意权重。现在控制器会先拒绝不可表示的权重并给出替代方案，避免 API 部分成功后状态失真。
- 状态索引规范化此前会丢弃 `address_family`/`tls_directory`，已补齐迁移字段。
- Nginx Certbot 续期钩子现在有 owner marker、原子替换和卸载归属检查，不覆盖用户自己的钩子。

## 仍需注意

- DNS 权重受 TTL、递归缓存和已有长连接影响，不是精确的媒体流量整形；需要精确 80/20 时使用 Cloudflare Load Balancing 或支持权重的 DNS 服务。
- IPv4 和 IPv6 必须分别建入口、记录和节点，不能在同一入口混用；IPv6 还需确认客户端和 VPS 防火墙均支持。
- 本次留下了带日期后缀的临时测试 DNS 记录，正式使用前应在对应 DNS 控制台删除或改名。
- 主控机现有 `sudo` 有一条与脚本无关的 hostname 解析提醒（`/etc/hostname` 未在 `/etc/hosts` 对应），不影响服务；生产部署建议修正主机名解析。
