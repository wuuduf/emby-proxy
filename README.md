# emby-proxy

给 Emby 源站快速套一层域名 HTTPS 反代. 支持 Caddy / Nginx、多个入口、独立 HTTPS 端口和同域名多路径.

脚本只允许固定源站, 不提供任意目标转发, 避免 VPS 被当成通用代理.

本项目由 [wuuduf](https://github.com/wuuduf) 编写和维护.

项目短命令为 **ep**；仓库已改名为 `emby-proxy`，旧地址会自动跳转.

## 安装

Debian / Ubuntu VPS 执行:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wuuduf/emby-proxy/refs/heads/codex/multiline-lab/setup-emby-proxy.sh)
```

跑完直接出菜单. 脚本会安装管理器 `emby-proxy`, 同时创建短命令 `ep`, 以后敲:

```bash
ep
```

普通用户执行 `ep` 会自动调用 sudo. 首次安装只部署管理菜单, 不会立刻安装 Web 服务或修改现有站点.

如果不想使用进程替换, 也可以继续使用传统三步命令:

```bash
curl -fsSL https://raw.githubusercontent.com/wuuduf/emby-proxy/refs/heads/codex/multiline-lab/setup-emby-proxy.sh -o /tmp/setup-emby-proxy.sh
chmod +x /tmp/setup-emby-proxy.sh && sudo /tmp/setup-emby-proxy.sh
```

## 快速上手

开始前, 把反代域名的 A 记录指向 VPS 公网 IPv4:

```text
emby.example.com  ->  VPS公网IPv4
```

没有可用 IPv6 就不要添加 AAAA. Cloudflare 首次申请证书建议先用“仅 DNS（灰云）”.

运行 `ep`, 选择 `3 新增反代入口`, 然后只需要确认四项:

1. Caddy 或 Nginx;
2. 域名结构;
3. 对外访问域名;
4. Emby 源站地址.

源站可以带协议和端口:

```text
https://origin.example.com
https://origin.example.com:8443
http://10.0.0.8:8096
```

完成后访问 `https://emby.example.com/`.

## 三种入口

| 模式 | 示例 | 建议 |
| --- | --- | --- |
| 独立子域名 + 443 | `emby1.example.com`、`emby2.example.com` | **首选, 兼容性最好** |
| 同一域名 + 独立 HTTPS 端口 | `example.com:18443`、`:19443` | 没有多个子域名时使用 |
| 同一域名 + 不同路径 | `/`、`/a`、`/b` | 高级模式, 部分客户端不兼容 |

| 入口 | 云防火墙/安全组放行 |
| --- | --- |
| 443 或路径模式 | TCP `80/443` |
| 自定义 HTTPS 端口 | TCP `80/自定义端口` |

脚本能处理已启用的 UFW/firewalld, 但不能修改 VPS 厂商控制台里的安全组.

## 一个域名反代多个 Emby

```text
/   -> https://plus.example.com
/a  -> https://emby-two.example.com
/b  -> https://split.example.com:8473
```

对应地址:

```text
https://emby.example.com/
https://emby.example.com/a/
https://emby.example.com/b/
```

在菜单选择 `4 管理已有入口` → 选择入口 → `1 新增路径`.

也可以执行:

```bash
ep list
sudo emby-proxy route add domain-emby.example.com
```

按提示输入 `/b` 和 `https://split.example.com:8473`. 请求 `/b/movie` 时会去掉 `/b` 前缀, 再向源站请求 `/movie`.

路径模式支持 WebSocket、`Location` 和 `Content-Location` 改写, 但部分 Emby 原生客户端或 Emby Connect 仍可能不兼容. 能用独立子域名时优先用子域名.

## 菜单

```text
入口配置
 1  查看全部反代入口   域名、引擎、路径数
 2  查看入口详情       映射、健康检查
 3  新增反代入口       Caddy / Nginx 向导
 4  管理已有入口       路径、源站、删除

观察与维护
 5  运行完整诊断       环境、DNS、TLS、源站
 6  日志与流量统计     媒体、错误、慢请求
 7  备份、差异与恢复   带 SHA256 校验
 8  Web 服务管理       安全 Reload / Restart

工具
 9  导入旧版配置       只建立管理索引
10  检查/更新程序      校验 SHA256 后更新
11  多线路控制器       主控、节点注册与优先级配额（实验版）
12  完全卸载 emby-proxy 删除脚本托管内容，保留 Caddy/Nginx 和证书
 0  退出面板            也可以输入 q
```

输错选项只会返回刚才的菜单. 当前操作失败不会退出整个面板, 也不会破坏已有服务.

## 常用命令

```bash
ep                                      # 打开菜单
ep status                               # 服务与入口概况
ep list                                 # 列出入口
ep doctor                               # 完整诊断
ep update --check                       # 检查更新
ep update                               # 更新并自动重启面板
sudo ep uninstall                       # 安全确认后完全卸载（保留 Web 服务和证书）

sudo emby-proxy show <入口ID>
sudo emby-proxy route add <入口ID>
sudo emby-proxy route set <入口ID>
sudo emby-proxy route delete <入口ID>
sudo emby-proxy delete <入口ID>
sudo emby-proxy import
sudo emby-proxy config test

sudo emby-proxy logs <入口ID> --follow
sudo emby-proxy logs <入口ID> --media
sudo emby-proxy logs <入口ID> --errors
sudo emby-proxy logs <入口ID> --slow 2
sudo emby-proxy stats <入口ID> --since 24h

sudo emby-proxy backup list
sudo emby-proxy backup restore <备份ID>
sudo emby-proxy service reload caddy
```

### 完全卸载

```bash
sudo ep uninstall
```

卸载前会把脚本管理的索引、入口配置、日志、主控/边缘 systemd 单元和管理器文件打包到
`/var/backups/emby-proxy-uninstall-时间.tar.gz`，并生成同名 `.sha256` 校验文件；需要输入
`REMOVE EMBY-PROXY` 才会继续。卸载只删除带脚本标记的内容，不会卸载 Caddy/Nginx，不会删除其他站点配置，也不会删除 TLS 证书。
如需无交互执行，可使用 `sudo ep uninstall --yes`，但请先确认备份目录可写。

交互终端更新完成后会自动打开新版本面板. 不会重启 Caddy/Nginx, 不会中断正在播放的媒体.

## 多线路主控（实验版，单脚本）

多线路功能已经合并进 `emby-proxy` 本身. 控制器只负责节点注册、心跳、节点选择和 Cloudflare A 记录切换, **不经过它转发媒体流量**. 主控固定一个源站，边缘节点复用同一域名和源站配置。

主控端示例:

```bash
# 创建入口状态；Cloudflare token 只放在主控本地权限为 600 的文件中
sudo ep controller init --state /etc/emby-proxy/controller.json \
  --entry-id domain-emby.example.com \
  --domain emby.example.com --source https://origin.example.com \
  --zone-id <ZONE_ID> --record-id <RECORD_ID> --token-file /etc/emby-proxy/cf.token

# 为每台边缘 VPS 生成一次性注册命令；priority 数字越大越优先，quota 为字节数，0 表示不限额
sudo ep controller issue --state /etc/emby-proxy/controller.json \
  --controller-url https://control.example.com:19090 --node-id edge-a \
  --name 香港线路 --priority 100 --quota-bytes 1099511627776 --public-ip <EDGE_A_IP>

# 主控循环每 30 秒检查健康节点并同步 DNS（安装为 systemd 服务）
sudo ep controller master-install --state /etc/emby-proxy/controller.json \
  --listen 0.0.0.0:19090
```

也可以直接在 `ep` 菜单选择 `11 多线路控制器`，按向导完成：初始化主控入口、生成一次性边缘注册命令、安装/启动主控服务、查看节点状态、立即同步 DNS 和查看主控服务状态。输入错误或底层检查失败只会返回控制器菜单，不会退出整个面板。

菜单初始化时不需要手动查找 `zone_id`、`record_id` 或填写文件路径：脚本会隐藏读取 API Token，将它保存为主控本地 `600` 权限的 `cf.token`，然后按对外域名自动查找匹配的 Zone 和 A 记录。该域名必须先在 Cloudflare DNS 中存在一条 A 记录（建议使用 DNS only/灰云）。命令行 `controller init` 仍保留显式参数，适合自动化部署。

`0.0.0.0:19090` 只适合配合 HTTPS/WireGuard 使用；不要把未加密控制器端口直接暴露到公网。

把 `controller issue` 输出的**整行命令**复制到对应边缘 VPS 执行即可。命令会在检测不到 `ep` 或旧版不具备 `node-install` 时自动安装/更新管理器，再完成一次性注册；不需要预先手动安装脚本。边缘预配置会跳过“域名必须当前指向本机”的检查，但真正切换前必须放行 TCP 80/443，并让域名解析到该节点以完成 TLS。节点注册后会配置 30 秒心跳并按优先级参与选择；节点达到配额或连续失联后，主控会选择下一台健康线路并更新 A 记录。

复制命令时必须使用纯文本 URL，例如 `http://161.114.15.74:19090`，不要把 Markdown 链接的 `[]()` 一起复制。主控菜单会先请求 `/status`，连不通时会直接提示端口、防火墙和 TLS 问题。

这个功能目前仍是实验实现: 控制器 HTTP 接口没有内置 TLS/管理员认证, 注册令牌只使用一次, 流量计数需要边缘侧写入 `/var/lib/emby-proxy/used_bytes`. 正式使用应放在 WireGuard 或 HTTPS 访问控制后. 当前改动只在 `codex/multiline-lab` 实验分支，未修改 `main`.

## 主控与边缘节点：完整配置教程

下面是一套从零开始的实际流程。主控只做**注册、心跳、优先级/配额选择和 Cloudflare A 记录切换**，不经过主控转发视频流量。

```text
客户端 ── DNS ──> 当前边缘 VPS ──固定回源──> Emby 源站
                     ▲
                     │ 心跳/注册（仅控制面）
                     └──────── 主控 VPS
```

### 1. 准备条件

准备以下内容：

1. 一个由 Cloudflare 托管的反代域名，例如 `emby.example.com`；
2. 一条现有的 Cloudflare **A 记录**（内容可先填任意当前 IP，建议 DNS only/灰云）；
3. 一个 Cloudflare API Token，权限至少是当前 Zone 的 `DNS:Edit`；
4. 一台主控 VPS，以及一台或多台边缘 VPS；
5. 所有边缘节点使用同一种引擎：全部 Caddy 或全部 Nginx。已有引擎会复用，不会卸载或覆盖其他站点。

主控端口建议只允许边缘节点访问。实验时可以临时使用 `http://主控IP:19090`；正式环境请使用 WireGuard 内网地址，或在 HTTPS 反代和访问控制后提供该端口。控制器没有内置 TLS 和管理员登录，不能裸暴露在公网。

### 2. 在主控 VPS 安装管理器

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wuuduf/emby-proxy/refs/heads/codex/multiline-lab/setup-emby-proxy.sh)
ep
```

安装器只安装 `emby-proxy`/`ep` 管理命令，不会自动改动 Caddy/Nginx。以后所有主控操作都从 `ep` 菜单进入。

### 3. 初始化主控入口

在主控执行 `ep`，选择：

```text
11 多线路控制器
  1 初始化主控入口
```

按提示填写：

| 提示 | 示例 | 说明 |
| --- | --- | --- |
| 状态文件 | `/etc/emby-proxy/controller.json` | 直接回车使用默认值 |
| 入口 ID | `domain-emby.example.com` | 同一入口的唯一标识 |
| 对外域名 | `emby.example.com` | 必须与 Cloudflare A 记录名称一致 |
| 固定源站 | `https://origin.example.com` | 所有边缘使用同一个源站 |
| 引擎 | `caddy` | 所有边缘应保持一致 |
| Cloudflare | `y` | 需要自动切换 DNS 时启用 |
| API Token | 直接粘贴 | 输入时隐藏，不需要创建文件 |

脚本会根据域名自动查找 `zone_id` 和 `record_id`，并把 Token 保存为主控本地 `600` 权限文件。不要把 Token 写进 Git、工单或注册命令。

也可以使用命令行初始化（适合自动化）：

```bash
sudo ep controller init \
  --state /etc/emby-proxy/controller.json \
  --entry-id domain-emby.example.com \
  --domain emby.example.com \
  --source https://origin.example.com \
  --engine caddy \
  --zone-id <ZONE_ID> \
  --record-id <RECORD_ID> \
  --token-file /etc/emby-proxy/cf.token
```

### 4. 启动主控服务

进入：

```text
11 多线路控制器
  3 安装/启动主控服务
```

实验时可填写：

```text
主控监听：0.0.0.0:19090
检查间隔：30
```

启动后检查：

```bash
systemctl status emby-proxy-master.service
curl http://127.0.0.1:19090/status
ss -ltnp | grep 19090
```

如果使用 UFW，建议只允许边缘节点访问控制端口，并单独放行边缘的 Web 端口：

```bash
# 主控：只允许边缘 IP 访问控制面
sudo ufw allow from <EDGE_A_IP> to any port 19090 proto tcp
sudo ufw allow from <EDGE_B_IP> to any port 19090 proto tcp

# 每台边缘：证书和 HTTPS 访问需要
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

### 5. 生成边缘注册命令

在主控菜单进入：

```text
11 多线路控制器
  2 生成边缘注册命令
```

示例填写：

```text
主控访问地址：http://161.114.15.74:19090
节点 ID：edge-a
节点名称：香港线路
优先级：100
配额字节数：1099511627776
边缘公网 IPv4：64.49.28.81
```

参数含义：

- `priority` 越大越优先，例如 `100` 优先于 `50`；
- `quota-bytes` 为该节点允许使用的累计字节数，`0` 表示不限额；
- `node-id` 在同一个主控入口中必须唯一，一台 VPS 只注册一个节点；
- 注册码是一次性的，只能在对应边缘 VPS 使用一次。

复制菜单输出的**整行命令**，不要把 Markdown 的 `[]()` 或提示文字一起复制。

### 6. 在边缘 VPS 执行注册命令

把上一节复制的命令粘贴到边缘 VPS。命令会自动：

1. 检查当前是否已有 `ep` 和 `node-install`；
2. 缺少或版本过旧时安装/更新管理器；
3. 复用该 VPS 已运行的 Caddy/Nginx；
4. 写入固定源站的反代入口；
5. 创建 `/etc/emby-proxy/multiline-node.json`；
6. 创建并启动 `emby-proxy-node.timer`，周期性发送心跳。

边缘预配置会跳过“域名当前必须解析到本机”的检查，方便先把所有节点准备好。但真正切换前，必须保证：

- Cloudflare A 记录可以指向该节点；
- 云防火墙放行 TCP 80/443；
- Caddy/Nginx 配置测试通过；
- 证书能够正常签发。

每台边缘重复第 5、6 步即可。例如：

```text
edge-a：64.49.28.81，priority 100，quota 1 TB
edge-b：107.173.146.90，priority 50，quota 2 TB
edge-c：82.109.97.103，priority 40，quota 3 TB
edge-d：192.236.234.150，priority 30，quota 0（不限额）
```

如果控制器选择 Caddy，而边缘 VPS 只有正在运行的 Nginx，注册仍会保存节点信息，但该节点会被标记为不健康，不会被选中，也不会改装 Nginx。要使用 Nginx，应重新初始化一个 `engine=nginx` 的入口。

### 7. 检查节点和同步 DNS

主控菜单：

```text
11 多线路控制器
  4 查看主控状态
  5 立即同步 DNS
  6 查看主控服务
```

命令行查看：

```bash
sudo ep controller status --state /etc/emby-proxy/controller.json
sudo ep controller reconcile --state /etc/emby-proxy/controller.json
curl http://127.0.0.1:19090/status
```

主控选择规则是：

```text
健康=true
最近心跳不超过 90 秒
未达到 quota
在满足条件的节点中选择 priority 最大者
```

DNS 记录切换成功后，Cloudflare 的 A 记录内容会变成当前节点公网 IPv4。脚本默认将记录设为 DNS only，以便证书和源站链路更容易排查。

### 8. 建议的故障切换测试

先确认状态中 `edge-a` 为当前节点，然后在 edge-a 模拟达到配额：

```bash
printf '1099511627776\n' | sudo tee /var/lib/emby-proxy/used_bytes
sudo ep controller node --state /etc/emby-proxy/multiline-node.json
```

主控应切换到下一台健康节点。再观察：

```bash
sudo ep controller status --state /etc/emby-proxy/controller.json
sudo ep controller reconcile --state /etc/emby-proxy/controller.json
```

流量计数按安全设计只增不减。测试配额后若要恢复节点，需要在主控重新签发注册码，并在该边缘重新执行注册命令；不要直接把 `used_bytes` 改小。

测试心跳是否持续：

```bash
systemctl list-timers --all emby-proxy-node.timer
journalctl -u emby-proxy-node.service -n 20 --no-pager
```

### 9. 常见问题

**Cloudflare 返回 HTTP 403**

- Token 已过期、被撤销或没有当前 Zone 的 `DNS:Edit`；
- 域名不在当前 Token 可管理的账户中；
- 重新创建 Token 后，在主控菜单重新初始化入口。

**主控返回 `invalid_or_expired_enroll_token`**

注册码已使用过、复制不完整，或 `entry-id`/主控地址不匹配。回到主控重新生成一次。

**节点显示 unhealthy**

```bash
systemctl status caddy       # 或 nginx
systemctl status emby-proxy-node.timer
curl http://主控地址:19090/status
```

检查控制器端口、防火墙、节点引擎是否与入口一致。域名尚未切换时，边缘 HTTPS 证书可能还没签发；预配置阶段可以先跳过本机 HTTPS 验证。

**出现 `sudo: unable to resolve host`**

这是 VPS 自身 `/etc/hostname` 与 `/etc/hosts` 不一致的系统问题，不是反代脚本产生的。修复主机名映射后再执行 sudo 命令。

### 10. 删除测试环境

确认不再使用时，在每台 VPS 执行：

```bash
sudo ep uninstall
```

卸载会备份并删除脚本自己的入口、索引、主控/边缘 systemd 单元和管理器，但保留 Caddy/Nginx 程序、其他站点配置及证书。删除前会要求输入 `REMOVE EMBY-PROXY`；测试环境可使用 `sudo ep uninstall --yes`。

## 非交互创建

```bash
# Caddy 子域名 443
sudo emby-proxy add --engine caddy --domain emby.example.com --upstream https://origin.example.com

# Nginx 独立 HTTPS 端口
sudo emby-proxy add --engine nginx --domain emby.example.com --domain-mode port --https-port 18443 --upstream https://origin.example.com

# Caddy 同域名多路径
sudo emby-proxy add --engine caddy --domain emby.example.com --domain-mode path \
  --upstream https://origin-one.example.com \
  --route /a=https://origin-two.example.com \
  --route /b=https://origin-three.example.com:8473
```

## 它做了什么

- 检查系统、DNS、端口、公网地址和已有 Caddy/Nginx;
- 没有 Web 服务时才让用户选择安装哪一种;
- 已有服务时只新增带标记的独立配置, 不覆盖其他站点;
- 检测源站, 普通连接失败后分别重试 IPv4/IPv6;
- 任意有效 HTTP 响应, 包括 `403`、`404`、`503`, 都算链路可达;
- 修改前备份, 验证候选配置, reload 失败自动恢复;
- 固定回源地址和 Host, 不接受客户端指定任意公网目标;
- `X-Forwarded-For` 固定使用真实连接来源, 不继承客户端伪造链;
- 提供健康检查、日志、媒体流量、错误、慢请求和 SHA256 更新校验.

## 文件和回滚

```text
/usr/local/bin/ep
/usr/local/sbin/emby-proxy
/usr/local/lib/emby-proxy/setup-emby-proxy.sh
/etc/emby-proxy/sites.d/*.json
/etc/emby-proxy/backups/
/etc/caddy/Caddyfile
/etc/nginx/conf.d/emby-proxy-*.conf
```

删除、恢复和更新前都会保留备份. 管理索引只记录入口与路径, 不替代真实 Caddy/Nginx 配置.

## 已知限制

- 只支持 Debian/Ubuntu、systemd 和域名 HTTPS;
- 域名必须解析到当前 VPS, 证书签发时 TCP 80 必须可用;
- 路径模式是否可用取决于具体 Emby 客户端;
- 不会绕过源站 TLS 证书错误或关闭证书验证;
- 源站只能包含协议、主机和端口, 不能带路径、账号或查询参数;

## 测试

```bash
bash -n setup-emby-proxy.sh emby-proxy tests/*.sh
./tests/test-cli.sh
./tests/test-config-generation.sh
./tests/test-manager.sh
./tests/test-manager-stage2.sh
./tests/test-menu-flows.sh
sha256sum -c checksums.txt
```

## 许可证

[MIT](LICENSE)
