# 多线路主控与边缘节点

这份文档说明如何用一台主控 VPS 管理多台边缘 VPS，让同一个反代域名在节点故障、配额用完或线路变化时切换到可用节点。

第一次只做一台 VPS 的反代，请先看 [README 快速上手](../README.md)。多线路是实验功能，建议先用测试域名验证，再承载真实播放。

## 先理解架构

主控只处理注册、心跳、节点选择和 DNS 更新，不转发媒体流量。媒体请求始终从客户端直接进入当前边缘 VPS，再由边缘 VPS 回源到固定的 Emby 源站。

```text
                         控制面：注册 / 心跳 / DNS
                    ┌──────────────────────────────┐
                    │        主控 VPS               │
                    │  controller.json + DNS API    │
                    └──────────────┬───────────────┘
                                   │
客户端 ── DNS ──> 当前边缘 VPS ──固定回源──> Emby 源站
                  edge-a / edge-b / edge-c
                    数据面：HTTPS 反代和媒体流量
```

三个概念先记住：

- **主控**：保存入口、节点和 DNS 状态，周期性检查节点；
- **边缘节点**：运行 Caddy 或 Nginx，真正承载播放请求；
- **DNS 提供商**：根据主控决定的结果回答域名解析，不承载媒体流量。

## 先选择 DNS 策略

一个入口选择一种 DNS 策略。两种策略都由主控决定节点，但解析行为不同：

| 策略 | 适合场景 | 主要能力 | 需要知道的限制 |
| --- | --- | --- | --- |
| Cloudflare | 先完成稳定的主备切换 | 单条 A/AAAA 故障切换、多记录权重池、定时权重 | 普通 DNS 不是实时负载均衡，精确权重需要 Load Balancing |
| DNSPod | 按默认/电信/联通/移动分线路 | 运营商线路、同线路多节点、线路定时切换 | 依赖子域名 NS 委派，解析缓存仍然存在 |

只有一台边缘节点时也可以使用主控，但没有故障切换意义。需要 IPv4 和 IPv6 同时对外服务时，分别创建两个入口；同一个入口不能混用 A 和 AAAA。

## 推荐的首次流程

按这个顺序操作即可。Cloudflare 和 DNSPod 只在第 2、3 步有一个分支：

```text
准备 DNS 和 VPS
  → 主控菜单 11 → 1 配置入口
  → Cloudflare：11 → 8 配置主控 HTTPS
  → DNSPod：11 → 10 接入 DNSPod，再 11 → 8 配置主控 HTTPS
  → 主控菜单 11 → 3 生成边缘命令
  → 在每台边缘 VPS 执行命令
  → 主控菜单 11 → 4 查看状态
  → 主控菜单 11 → 5 立即同步 DNS
```

每一步都有明确的继续条件：入口配置成功后生成 `controller.json`；主控 HTTPS 成功后 `/status` 能返回入口身份；边缘成功后菜单 4 显示心跳；DNS 同步成功后记录回读结果与当前节点一致。

主控和边缘使用同一入口配置，因此同一个入口中的节点必须满足：

- 使用同一种引擎：全部 Caddy 或全部 Nginx；
- 使用同一种地址族：全部 IPv4 或全部 IPv6；
- 使用同一个对外域名和固定源站；
- 控制器管理的边缘统一监听业务 HTTPS 443。

## 开始前准备

### 主控 VPS

主控需要：

- Debian/Ubuntu、systemd、`curl`、`jq`；
- 一个独立的主控域名，例如 `control.example.com`；
- 主控域名的 A 或 AAAA 记录指向主控 VPS；
- Cloudflare 或 DNSPod 凭据，取决于你选择的 DNS 策略。

### 边缘 VPS

每台边缘需要：

- Debian/Ubuntu、systemd；
- 云防火墙放行 TCP 80/443；
- 只能有一个明确的 Caddy 或 Nginx 服务；
- 对外域名最终能够解析到该节点，以便 HTTPS 健康检查通过。

### 业务入口

准备一个对外域名，例如 `emby.example.com`，以及固定源站：

```text
https://origin.example.com
https://origin.example.com:8443
http://192.0.2.20:8096
```

源站只能包含协议、主机和端口，不能填写路径、账号或查询参数。脚本会固定回源 Host，不会接受客户端临时指定任意公网目标。

## 第一步：安装管理器

主控和每台边缘都可以使用同一个安装命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wuuduf/emby-proxy/main/setup-emby-proxy.sh)
ep
```

首次运行只安装 `emby-proxy` 和 `ep` 菜单，不会自动创建反代入口。边缘注册命令也会自动检查并更新旧版管理器，所以边缘可以是全新 VPS。

## 第二步：配置主控入口

在主控打开：

```text
ep
  11 多线路控制器
    1 配置主控入口
```

向导会依次询问：

| 提示 | 填写内容 |
| --- | --- |
| 对外域名 | `emby.example.com` |
| 固定源站 | `https://origin.example.com` |
| 独立主控域名 | `control.example.com`，也可以先留空 |
| 边缘地址类型 | `ipv4` 或 `ipv6`，一个入口只能选一种 |
| Cloudflare | 使用 Cloudflare 自动切换时选择 `y` |

入口 ID 会自动生成，例如 `domain-emby.example.com`。不需要手工填写入口 ID、Zone ID 或 Record ID。

### 使用 Cloudflare

选择启用 Cloudflare 后直接粘贴 API Token。Token 至少需要当前 Zone 的 `Zone:Read` 和 `DNS:Edit` 权限。脚本会按域名自动查找 Zone 和全部同类型记录：

- IPv4 入口只查找 A 记录；
- IPv6 入口只查找 AAAA 记录；
- Token 只保存于主控本地 600 权限文件；
- 边缘节点不会收到 Cloudflare Token。

Cloudflare 模式适合先做单记录主备切换，也是最容易完成的多线路方案。

### 使用 DNSPod

配置入口时 Cloudflare 选择 `n`，之后打开：

```text
ep
  11 多线路控制器
    10 DNSPod 运营商线路
      1 接入/检查 DNSPod
```

DNSPod 需要先在控制台完成子域名托管和 NS 委派，再准备对应的 A/AAAA 记录。脚本只接管以下四种线路：

```text
默认 / 电信 / 联通 / 移动
```

输入格式为 `ID,Token`，脚本会先发现并预览区域、记录和线路，确认后才接管，不会替你修改父域 NS，也不会删除其他记录。

## 第三步：配置主控 HTTPS

边缘节点必须通过 HTTPS 访问主控。主控域名的 DNS 记录要先指向主控 VPS，然后在主控选择：

```text
ep
  11 多线路控制器
    8 配置自动证书
```

脚本会根据 DNS 提供商选择证书方案：

| DNS 情况 | 主控 HTTPS 方式 | 需要放行 |
| --- | --- | --- |
| Cloudflare Token | Certbot DNS-01，主控原生 TLS | TCP 19090 |
| DNSPod 或其他 DNS | Caddy 443 反代到 `127.0.0.1:19090` | TCP 80/443 |

主控域名不能与业务入口域名相同。未启用 HTTPS 时只能在安全内网或 WireGuard 中临时使用 HTTP；不要把未加密的 19090 直接暴露在公网。

配置完成后先确认主控状态。Cloudflare 原生 TLS 使用 19090，DNSPod/Caddy 模式使用 443：

```bash
systemctl status emby-proxy-master.service

# Cloudflare
curl -fsS https://control.example.com:19090/status

# DNSPod 或其他 DNS
curl -fsS https://control.example.com/status
```

`/status` 只返回入口身份和公开状态，不接受 DNS 变更操作。菜单 8 配置完成后通常会自动启动主控；已有手动服务时可以用菜单 2 启动，菜单 7 只用于修改监听地址和检查间隔。

## 第四步：添加边缘节点

在主控选择：

```text
ep
  11 多线路控制器
    3 添加边缘节点
```

普通节点只需要：

1. 确认主控 URL；
2. 地址族使用入口默认值；
3. 高级设置选择 `n`。

脚本会自动使用：

```text
节点名称：自动生成
节点 ID：自动生成并保证唯一
优先级：100
配额：不限额
公网 IP：在边缘 VPS 自动检测
```

需要流量上限或线路标识时才选择高级设置：

- 优先级数字越大越优先，例如 100 高于 50；
- 配额先选单位，再输入数量，支持 B、KB、MB、GB、TB 和小数；
- 配额 `0` 表示不限额；
- IPv4 节点使用 `curl -4` 检测地址，IPv6 节点使用 `curl -6`。

向导输出一条带一次性注册码的完整命令。复制整行命令到对应边缘 VPS 执行，不要复制终端提示文字、Markdown 链接或换行后的说明。

边缘命令会：

1. 检查本机 Caddy/Nginx，避免安装第二套冲突服务；
2. 向主控注册节点；
3. 写入固定源站的反代配置；
4. 按主控证书模式准备或同步 HTTPS 证书；
5. 创建 `emby-proxy-node.timer`，每 30 秒发送心跳。

注册码只能使用一次，签发 15 分钟后失效。每台边缘重复生成并执行一条命令即可。

## 第五步：查看状态并同步 DNS

回到主控：

```text
ep
  11 多线路控制器
    4 节点状态与用量
    5 立即同步 DNS
    6 服务状态与日志
```

命令行查看：

```bash
sudo ep controller status --state /etc/emby-proxy/controller.json
sudo ep controller reconcile --state /etc/emby-proxy/controller.json
```

节点状态需要同时满足：

- Caddy/Nginx 进程运行；
- 本机 `/_emby_proxy_health` 返回 200；
- 最近心跳不超过 90 秒；
- 没有达到配额；
- 入口地址族和引擎匹配。

满足条件的节点中，主控按优先级选择当前节点。DNS 写入后必须回读确认，失败时保留上一条已确认记录，并在下一轮重试。

## 节点选择和故障切换

| 状态 | 处理方式 |
| --- | --- |
| 连续 3 次心跳失败 | 节点退出候选，前两次显示故障观察 |
| 心跳超过 90 秒未更新 | 立即退出候选 |
| 用量达到配额 | 立即退出候选 |
| 节点恢复 | 连续成功 3 次且持续 60 秒后重新进入候选 |
| 高优先级节点恢复 | 当前节点仍可用时，等待 180 秒冷却后再抢占 |
| 没有健康节点 | 保留已确认 DNS，并显示告警 |

DNS 切换只影响新解析和新连接。递归 DNS 缓存和已经建立的 Emby 播放连接不会立即迁移。

## Cloudflare：默认主备和权重池

### 默认主备

只有一条 A/AAAA 记录时，主控使用优先级、健康状态和配额选择一台活动节点，更新这一条记录。这是最简单、最稳定的模式。

### 多节点权重

菜单：

```text
ep
  11 多线路控制器
    11 Cloudflare 多节点权重
```

启用前需要至少两条同名同类型记录。脚本会把权重展开到 DNS 记录槽位，并逐条更新、逐条回读。

普通 Cloudflare DNS 不允许同名同类型的重复 IP 记录。因此两条记录配置 `edge-a=80,edge-b=20` 时，脚本可能判定该比例无法安全表示并拒绝写入，避免部分更新。需要精确权重时使用 Cloudflare Load Balancing，或使用支持权重记录的 DNS 服务。

DNS 权重只是近似分配，受 TTL、递归 DNS 和客户端缓存影响，不能当作精确流量计量。

### 定时权重

菜单：

```text
ep
  11 多线路控制器
    12 定时调度策略
```

格式：

```text
00:00|edge-a=80,edge-b=20;08:00|edge-a=20,edge-b=80
```

调度按主控服务器本地时间运行，每 30 秒检查一次。清除调度后会恢复基础权重。

## DNSPod：运营商线路

DNSPod 是按运营商和地域回答 DNS 的分流方案，不是逐请求负载均衡。菜单：

```text
ep
  11 多线路控制器
    10 DNSPod 运营商线路
```

接入后可以在 **2 设置线路节点** 中配置：

```text
默认 → edge-a
电信 → edge-b
联通 → edge-c
移动 → edge-a
```

指定节点不健康或配额用完时，主控会回退到当前健康候选。每条线路独立记录成功和失败状态，不会因为一条线路失败而报告全部成功。

如果某条线路有多条同线路 A/AAAA 记录，可以使用 **5 同线路多节点权重**：

```text
edge-a=80,edge-b=20
```

线路定时切换格式：

```text
00:00|电信=edge-a,联通=edge-b;12:00|电信=edge-b,联通=edge-a
```

## IPv6 入口

IPv6 不是在同一个入口里额外添加一台节点，而是初始化入口时选择 `ipv6`：

- 业务域名使用 AAAA 记录；
- 所有边缘节点都必须是公网 IPv6；
- 主控、边缘检测、健康检查和 DNS 更新全部使用 IPv6；
- 同一个入口不能混用 IPv4 和 IPv6；
- 如果要同时支持两种地址族，请分别创建两个入口并分别管理。

## 集中证书

启用菜单 8 后，备用节点可以从主控通过 HTTPS 领取入口证书：

- Cloudflare 模式使用 DNS-01 签发入口和主控证书；
- DNSPod/其他 DNS 模式由 Caddy 在 443 处理 HTTP-01；
- 边缘每小时检查证书更新；
- 证书验证、配置测试或 reload 失败时保留旧证书；
- Cloudflare Token 只留在主控，边缘只收到本入口的证书和私钥。

证书详细说明见 [证书自动化](CERTIFICATES.md)。

## Telegram 通知与查询

Telegram Bot 只运行在主控，通过出站长轮询工作，不新增公网监听端口。配置位置：

```text
ep
  11 多线路控制器
    13 Telegram 通知与查询
```

支持查询：

```text
/status     主控、DNS 和当前节点
/nodes      节点地址族、心跳、配额和累计流量
/traffic    最近 5 分钟流量和请求数
/access     最近 5 分钟访问 IP
/devices    粗粒度设备类型
/origins    固定源站和入口
/help       命令说明
```

只有白名单 Chat ID 可以查询。Token 保存为主控本地 600 权限文件；摘要只保留有限窗口，不上传完整 URL、查询串或原始日志。

## 建议的验收测试

### 1. 正常链路

```bash
curl -fsS https://emby.example.com/_emby_proxy_health
curl -I https://emby.example.com/
sudo ep controller status --state /etc/emby-proxy/controller.json
```

健康路径应返回 200。源站返回 403、404 或 503 时，只能说明链路已到达源站，不能说明 Emby 业务可用。

### 2. 故障切换

先确认当前节点和备用节点都处于健康状态，再在当前节点停止 Web 服务或阻断心跳，等待主控完成故障观察：

```bash
sudo systemctl stop caddy       # 或 nginx；只在测试节点执行
sudo ep controller status --state /etc/emby-proxy/controller.json
```

恢复服务后等待恢复观察窗口，再确认节点重新进入候选。测试完成后重新启动 Web 服务：

```bash
sudo systemctl start caddy      # 或 nginx
```

### 3. 配额切换

仅在测试节点执行配额测试。不要手工把生产用量文件改小；用量按设计只增不减。

详细验收矩阵见 [测试与验收](TESTING.md)。

## 常用排错

### 节点显示 unhealthy

在边缘检查：

```bash
systemctl status caddy       # 或 nginx
systemctl status emby-proxy-node.timer
journalctl -u emby-proxy-node.service -n 50 --no-pager
```

再确认边缘域名的 A/AAAA 已指向该节点，TCP 80/443 已放行，证书有效，且主控 URL 从边缘可访问。

### 注册码无效或过期

回主控菜单 3 重新生成命令。注册码不能重复使用，也不能把一个入口的注册码用于另一个入口。

### DNS 没有切换

先看菜单 4 的 `dns_needs_confirmation`、最近错误和当前记录，再用菜单 5 手动同步。Cloudflare 权重池需要至少两条同名记录；DNSPod 需要先完成 NS 委派和四种线路记录。

### 主控访问不了

确认主控域名解析正确、证书流程已完成、防火墙端口已放行，并从边缘执行：

```bash
# DNSPod/Caddy 模式
curl -fsS https://control.example.com/status
# Cloudflare 原生 TLS
curl -fsS https://control.example.com:19090/status
```

不要把播放域名当作主控 URL。主控 URL 必须是独立的控制域名。

### 出现 `sudo: unable to resolve host`

这是 VPS 自身 `/etc/hostname` 与 `/etc/hosts` 不一致。先修复主机名映射，再执行注册命令。

## CLI 和相关文档

菜单适合日常操作；CLI 适合自动化和排障。常用命令：

```bash
sudo ep controller status --state /etc/emby-proxy/controller.json
sudo ep controller reconcile --state /etc/emby-proxy/controller.json
sudo journalctl -u emby-proxy-master.service -n 100 --no-pager
sudo ep controller cert-renew --state /etc/emby-proxy/controller.json
sudo ep controller node-cert-sync
```

非交互单机反代、备份恢复和入口路径管理见 [高级单机使用](ADVANCED-USAGE.md)。

相关文档：

- [README 快速上手](../README.md)
- [证书自动化](CERTIFICATES.md)
- [测试与验收](TESTING.md)
- [菜单设计](MENU-DESIGN.md)
- [架构与代码阅读顺序](ARCHITECTURE.md)
- [开发与验证](DEVELOPMENT.md)
