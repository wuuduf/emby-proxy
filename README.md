# Emby 一键反向代理脚本（域名 HTTPS / IP HTTP，Caddy / Nginx）

`setup-emby-proxy.sh` 用于在 Debian/Ubuntu VPS 上选择 Caddy 或 Nginx，为一个或多个 Emby 源站配置反向代理。入口可以使用域名 HTTPS，也可以在没有域名时使用公网 IPv4 + 独立 HTTP 端口。

默认交互菜单只提供以下安全的域名 HTTPS 入口结构：

1. **独立子域名 + HTTPS 443**（首选，客户端兼容性最好）；
2. **同一域名 + 独立 HTTPS 端口**（每个 Emby 一个端口）；
3. **同一域名 + 不同路径**（高级兼容模式，会显示明显警告）；

**IP + 独立 HTTP 端口默认隐藏并禁用**，因为登录凭据、Token 和媒体流都是明文。只有明确接受风险并使用 `--show-unsafe-ip-mode` 时才会显示或允许该兼容模式。

> **端口必须放行：** 脚本会尝试修改已启用的 UFW/firewalld，但无法修改 VPS 厂商的云防火墙/安全组。域名 443 模式需放行入站 TCP `80/443`；自定义 HTTPS 端口模式需放行 `80/自定义端口`；IP 模式需放行所选 HTTP 端口。未放行时，本机检查可能正常，但公网仍无法访问。

除基础反代外，脚本还会配置固定的健康检查、可轮转的请求/流媒体日志，并安全改写源站返回的 `Location` 与 `Content-Location`。

## 一键启动命令

在 Debian/Ubuntu VPS 上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/wuuduf/emby-reverse-proxy-installer/main/setup-emby-proxy.sh \
  -o /tmp/setup-emby-proxy.sh && \
chmod +x /tmp/setup-emby-proxy.sh && \
sudo /tmp/setup-emby-proxy.sh
```

首次执行这条命令时，脚本只会检查系统和已有 Caddy/Nginx、安装长期管理命令，然后直接打开管理菜单；**不会立刻安装 Web 服务或创建反代入口**。请在菜单中选择 `3. 新增反代入口`，再按向导选择 Caddy/Nginx、域名模式、端口和源站。

进入新增入口向导后，脚本才会检查或安装 Caddy/Nginx，并检查 DNS（仅域名模式）、端口及源站；确认配置并通过语法验证后才会重载服务。以后再次运行同一条一键命令，也只会确保管理命令可用并进入菜单，不会重复新增入口。

安装脚本同时会安装长期管理命令：

```bash
sudo emby-proxy
```

不带参数会打开交互菜单，可以查看服务与入口概况、列出反代、查看路径详情、新增入口、添加或修改路径、删除脚本托管路径/入口、导入旧版配置，以及验证完整 Caddy/Nginx 配置。

如果 VPS 已经由旧版脚本配置完成，只想安装管理命令、不新增反代，可以执行：

```bash
curl -fsSL https://raw.githubusercontent.com/wuuduf/emby-reverse-proxy-installer/main/setup-emby-proxy.sh \
  -o /tmp/setup-emby-proxy.sh && \
chmod +x /tmp/setup-emby-proxy.sh && \
sudo /tmp/setup-emby-proxy.sh --manager-only
```

该模式会安装命令并尝试导入旧版脚本配置，然后直接进入长期管理流程。

## `emby-proxy` 管理命令（第二阶段）

常用命令：

```bash
sudo emby-proxy status
sudo emby-proxy list
sudo emby-proxy show domain-emby.example.com
sudo emby-proxy add
# 仅在明确接受明文 HTTP 风险时显示 IP 模式
sudo emby-proxy add --show-unsafe-ip-mode

sudo emby-proxy route add domain-emby.example.com
sudo emby-proxy route set domain-emby.example.com
sudo emby-proxy route delete domain-emby.example.com

sudo emby-proxy delete domain-emby.example.com
sudo emby-proxy import
sudo emby-proxy config test

# 环境、DNS、证书、服务、入口和每个源站的联合诊断
sudo emby-proxy doctor
sudo emby-proxy doctor domain-emby.example.com

# 日志过滤与流量统计
sudo emby-proxy logs domain-emby.example.com
sudo emby-proxy logs domain-emby.example.com --follow
sudo emby-proxy logs domain-emby.example.com --media
sudo emby-proxy logs domain-emby.example.com --errors
sudo emby-proxy logs domain-emby.example.com --slow 2
sudo emby-proxy stats domain-emby.example.com --since 24h

# 备份、差异、恢复和清理
sudo emby-proxy backup list
sudo emby-proxy backup show 备份ID
sudo emby-proxy backup restore 备份ID
sudo emby-proxy backup clean 20

# 安全管理服务（reload/restart 前先验证完整配置）
sudo emby-proxy service status
sudo emby-proxy service reload caddy
sudo emby-proxy service restart nginx
sudo emby-proxy service logs caddy

# 校验远端 SHA256 后检查或安装更新
sudo emby-proxy update --check
sudo emby-proxy update
```

管理数据保存在：

```text
/etc/emby-proxy/sites.d/*.json
/etc/emby-proxy/backups/
```

这些 JSON 文件是管理索引，不会替代 Caddy/Nginx 的实际配置。每次安装后端成功并通过端到端健康检查后才会更新索引。旧版本已经生成的 Caddy/Nginx 配置可通过 `sudo emby-proxy import` 导入；导入只建立索引，不会 reload 或改写当前运行配置。

新增或修改路径时，管理器把完整入口状态重新交给经过验证的安装后端：先检查环境和源站，再生成候选配置、备份、运行 `caddy validate`/`nginx -t`、reload 和端到端检查。删除操作只识别脚本的精确托管标记或独立 Nginx 文件；标记缺失、重复或不完整时会拒绝自动删除。

管理器与安装后端共同使用 `/run/lock/emby-proxy.lock`，避免两个 SSH 窗口同时修改配置。第二阶段已经包含按需诊断、日志过滤、流量统计、备份恢复、服务管理和带 SHA256 校验的自更新；尚未加入 systemd 定时巡检、消息告警和 Web 管理页面。

`doctor` 会检查管理索引、实际配置文件、完整配置语法、systemd 服务、DNS、证书剩余时间、监听端口、本机防火墙、入口健康地址和每个固定源站。它只做读取与探测，不会自动修改配置；末尾会汇总“正常/提醒/错误”，便于按提示修复。

配置删除和恢复前生成的管理器备份位于 `/etc/emby-proxy/backups/`，新备份带有 `metadata.json`、目标路径和 SHA256。`backup restore` 会先校验备份、再次备份当前配置、执行完整语法验证并 reload；失败时回滚到恢复前状态。自更新会同时校验 `emby-proxy` 与安装后端，执行 `bash -n`，并把旧版本保存在同一备份目录中。

## 交互式使用

把脚本上传到 VPS，然后执行：

```bash
chmod +x setup-emby-proxy.sh
sudo ./setup-emby-proxy.sh
```

根据菜单先输入：

1. 选择 `Caddy` 或 `Nginx`；
2. 默认直接选择“独立子域名 443”“同一域名独立 HTTPS 端口”或“同一域名不同路径”；
3. 输入域名/端口；
4. 输入 Emby 源站，例如 `origin.example.com`、`https://origin.example.com` 或 `http://1.2.3.4:8096`。

如确需临时显示 IP 模式，使用 `sudo ./setup-emby-proxy.sh --show-unsafe-ip-mode`。该模式不需要域名、DNS 或证书，示例入口为 `http://203.0.113.10:8080/`。它使用 1024-65535 范围内的独立端口；端口被占用时会停止并要求更换，不会抢占已有服务。

> **安全提醒：** IP 模式是明文 HTTP，客户端登录凭据和媒体流在客户端到本 VPS 之间没有 TLS 加密，不建议在不可信网络中传输管理员账号。IP 直连也不代表当然免除中国大陆服务器的备案或接入商要求，请以服务器接入商和主管部门的实际要求为准。

只有明确选择“同一域名 + 不同路径”时，脚本才会询问 `/a`、`/emby2` 等路径。若该域名已经是手工配置的 Caddy 站点，脚本会检查路径不重叠后，只插入精确托管片段；原站点的 `/`、证书、其他指令和日志设置保持不变。

高级路径模式可以继续添加多个路径源站，例如：

```text
/    -> https://emby-one.example.com
/a   -> https://emby-two.example.com
/b   -> http://10.0.0.3:8096
```

对应访问地址为 `https://emby.example.com/`、`https://emby.example.com/a/` 和 `https://emby.example.com/b/`。脚本会自动把 `/a` 重定向到 `/a/`，并在回源前剥离 `/a` 前缀。

### 已安装 Web 服务时

脚本启动后会先检查 Caddy 与 Nginx：

- 如果检测到其中一种，会询问是否在该服务的原配置基础上新增独立 Emby 站点；
- 如果某一种正在运行，不会自动安装另一种与它争用 80/443 端口；
- 如果两种服务均不存在，才会显示 Caddy/Nginx 全新安装选择；
- 如果两种服务同时运行，为避免误伤现有站点，脚本会停止并要求先人工确认入口关系；
- 非交互运行时，`--engine` 表示明确同意复用对应的现有服务。

复用现有服务时，脚本不会覆盖其他站点：Caddy 为每个新域名维护独立托管块；如果域名已经有且只能定位到一个明确的顶层 Caddy 站点块，则按“域名 + 路径”维护独立片段。Nginx 为每个域名维护独立的 `emby-proxy-域名.conf`。完整配置验证失败时不会 reload；reload 失败则自动恢复备份。

旧版本生成的 Caddy 单一托管块会在该域名下次更新时自动转换成带域名的托管块；旧版 Nginx `emby-proxy-managed.conf` 会先原样备份并迁移为每域名文件，再进行更新。

旧文件名 `setup-emby-caddy.sh` 是兼容入口，也会打开相同的 Caddy/Nginx 选择菜单。

## 非交互式使用

Caddy：

```bash
sudo ./setup-emby-proxy.sh \
  --show-unsafe-ip-mode \
  --engine caddy \
  --domain emby.example.com \
  --upstream origin.example.com
```

同一域名的独立 HTTPS 端口（Caddy/Nginx 均支持；每个 Emby 重复执行一次并换端口）：

```bash
sudo ./setup-emby-proxy.sh \
  --engine nginx \
  --domain emby.example.com \
  --domain-mode port \
  --https-port 18443 \
  --upstream https://origin-one.example.com

sudo ./setup-emby-proxy.sh \
  --engine nginx \
  --domain emby.example.com \
  --domain-mode port \
  --https-port 19443 \
  --upstream https://origin-two.example.com
```

对应地址是 `https://emby.example.com:18443/` 和 `https://emby.example.com:19443/`。必须在云安全组放行 TCP `80`、`18443`、`19443`；TCP 80 用于证书申请和续期。

向一个已经存在的 Caddy 域名追加 `/emby2`，不会接管原来的根路径：

```bash
sudo ./setup-emby-proxy.sh \
  --engine caddy \
  --domain existing.example.com \
  --path /emby2 \
  --upstream https://origin.example.com
```

只有在域名能唯一定位到 `/etc/caddy` 下的一个显式顶层站点块、路径不是 `/` 且没有与已有路径重叠时，脚本才会自动插入。目标文件会先备份，随后对主 `/etc/caddy/Caddyfile` 做完整验证；验证或 reload 失败都会恢复。复杂、重复或无法唯一定位的配置会安全停止。

Nginx：

```bash
sudo ./setup-emby-proxy.sh \
  --engine nginx \
  --domain emby.example.com \
  --domain-mode path \
  --upstream https://origin.example.com \
  --route /a=https://emby-two.example.com \
  --route /b=http://10.0.0.3:8096
```

无域名 IP HTTP 模式（Caddy）：

```bash
sudo ./setup-emby-proxy.sh \
  --engine caddy \
  --mode ip \
  --ip-address 203.0.113.10 \
  --listen-port 8080 \
  --upstream http://127.0.0.1:8096
```

`--ip-address` 可以省略，脚本会通过公网服务自动检测 IPv4。非交互运行建议显式填写，以避免多出口或 NAT 环境识别到错误地址。部署后访问 `http://203.0.113.10:8080/`。新增另一个 Emby 时重新运行脚本并选择另一个端口（例如 `18081`），不要在 IP 模式继续堆叠 `/a`、`/b`。

如果源站只填写域名，脚本会先尝试 HTTPS，再尝试 HTTP。源站地址不能带 `/emby/`、`/web/index.html`、查询参数或账号密码。

> **子路径兼容性提醒：** Caddy 官方将此类配置称为可能存在“subfolder problem”的模式。脚本会正确完成前缀剥离、WebSocket 和路径级回源，但 Emby 的部分原生客户端、Emby Connect 或源站返回的绝对路径可能不识别 `/a` 这类额外前缀。请逐个使用完整地址进行实际登录和播放测试；兼容性要求最高时，仍建议每个 Emby 使用独立子域名。

## 两种模式的区别

### Caddy

- 使用 Caddy 官方 stable apt 软件源；
- Caddy 自动申请、安装及续期 HTTPS 证书；
- Caddy 原生处理 WebSocket；
- 配置写入 `/etc/caddy/Caddyfile` 中带域名的独立脚本托管块；可连续管理多个反代域名。
- IP 模式使用显式 `http://IPv4:端口` 站点地址，不触发自动 HTTPS，也不会占用已有 80/443。

### Nginx

- 使用 Debian/Ubuntu 软件源安装 `nginx` 与 `certbot`；
- Certbot 使用 webroot 方式申请及续期 Let's Encrypt 证书；
- 自动安装证书续期后的 Nginx reload hook；
- 显式配置 Emby WebSocket、流式传输、长连接超时、客户端 IP 头；
- HTTPS 回源会发送正确 SNI，并使用系统 CA 校验源站证书；
- 每个“域名 + HTTPS 端口”使用独立配置，例如 `/etc/nginx/conf.d/emby-proxy-emby.example.com-https-18443.conf`；内部变量、日志格式和 TLS session cache 也按入口隔离；
- 多入口/多路径时自动写入独立的 `00-emby-proxy-hash.conf` 提高 Nginx 变量哈希容量，避免入口增多后出现 `could not build optimal variables_hash`；若系统已有手工容量设置则保持不覆盖；
- 同一域名的多个 HTTPS 端口共享一个仅用于 ACME/HTTPS 跳转的 TCP 80 配置和同一张证书；TCP 80 永远不会提供明文 Emby 反代；
- 发送给源站的 `X-Forwarded-For` 固定来自 Nginx 的 `$remote_addr`，不继承客户端伪造的来源链。
- IP 模式只安装 Nginx，不安装或调用 Certbot，并生成独立的纯 HTTP 配置文件。

## 健康检查与流量日志

部署完成后，可用以下地址检查 **Caddy/Nginx 入口是否存活**：

```bash
curl -fsS https://emby.example.com/_emby_proxy_health
# 自定义 HTTPS 端口：
curl -fsS https://emby.example.com:18443/_emby_proxy_health
# IP 模式：
curl -fsS http://203.0.113.10:8080/_emby_proxy_health
```

正常返回 `ok` 和 HTTP 200。这个地址不会连接任意外部目标，也不会暴露源站信息；它表示代理入口与证书可用，不等同于每个 Emby 源站的持续健康状态。安装时脚本仍会逐个探测源站，并逐路径完成一次端到端验证。

追加到已有 Caddy 域名时，健康地址跟随新增路径，例如 `/emby2/_emby_proxy_health`，避免占用原站点的根级健康路径。

详细访问日志位置：

- Caddy：`/var/log/caddy/emby-proxy-域名-access.log`，JSON 格式，100 MiB 轮转，最多保留 5 个历史文件/30 天；
- Nginx：`/var/log/nginx/emby-proxy-域名-access.log`，JSON 格式，由系统 Nginx logrotate 规则轮转。

IP 模式的日志名包含 IP 和端口，例如 `emby-proxy-ip-203.0.113.10-8080-access.log`。

每条请求都包含响应字节数、总耗时、回源耗时、状态码和上游地址，可直接定位慢播放、断流或异常流量：

```bash
sudo tail -F /var/log/nginx/emby-proxy-emby.example.com-access.log
# 或
sudo tail -F /var/log/caddy/emby-proxy-emby.example.com-access.log

# 只关注常见媒体请求
sudo tail -F /var/log/nginx/emby-proxy-emby.example.com-access.log \
  | grep -Ei '/Videos/|/Audio/|/stream|\.m3u8'
```

第二阶段管理命令可直接完成常见过滤和汇总，不需要手写 `jq`/`grep`。`stats` 支持 `30m`、`24h`、`7d` 等时间范围，显示请求数、输出流量、4xx/5xx、慢请求、平均耗时、流量最高客户端和请求最多路径：

```bash
sudo emby-proxy logs domain-emby.example.com --media
sudo emby-proxy logs domain-emby.example.com --slow 2
sudo emby-proxy stats domain-emby.example.com --since 7d
```

为保证统计时间准确，新生成的 Nginx JSON 日志同时写入 Unix 时间戳 `ts` 和可读时间 `time`。管理器仍兼容没有 `ts` 的旧日志。Caddy 附加路径沿用手工站点的日志配置，因此没有独立日志文件时，管理器只能显示 Caddy 服务日志，不能自动做入口级流量统计。

Nginx 日志只记录 `$uri`，不记录查询参数；Caddy 会隐藏常见 `api_key`、`token`、`X-Emby-Token` 和 `X-MediaBrowser-Token`。日志仍可能包含客户端 IP、媒体 ID 等运维信息，文件权限默认为 `0640`，不要公开分享原始日志。

向手工配置的现有 Caddy 域名追加路径时，脚本沿用该站点原来的日志设置，不会为了单个路径擅自改变整站日志。

## URL 改写范围

脚本会按每条固定路由改写响应头：

- 源站 `Location` / `Content-Location` 中指向**当前固定源站**的绝对 URL，会改成当前对外入口；域名模式使用 HTTPS，IP 模式使用 `http://IPv4:端口`；
- `/a` 等子路径路由会自动补回 `/a` 前缀；
- 根相对 URL（如 `/web/index.html`）也会补上对应前缀；
- 已经带有当前路径前缀的 URL 会保持不变，例如 `/a/web` 不会被重复改成 `/a/a/web`；
- 指向 CDN、下载站等第三方主机的绝对 URL 保持不变。

这不是动态代理：客户端不能通过 URL、SNI、Host 或响应头指定新的回源目标。

### 为什么不默认改写 Emby JSON 响应体

当前脚本没有照搬 Go 项目的响应体字符串替换。标准 Caddy 没有通用响应体替换指令，发行版 Nginx 的 `sub_filter` 也不是 JSON 感知的；强行启用会遇到 gzip、分块响应、Range 流媒体、误替换和两种引擎行为不一致等问题。脚本优先使用 `X-Forwarded-Prefix` 与响应头改写，不在数据面增加一个可动态选目标的代理进程。

若某个特定 Emby 版本仍在 `PlaybackInfo` 等 JSON 中返回错误的绝对源站 URL，建议优先给该 Emby 使用独立子域名；不要为了修复响应体 URL 开启“客户端在路径里指定目标主机”的通用转发设计。

## 自动检查及保护

- 检查 Debian/Ubuntu、systemd、CPU 架构和 root 权限；
- 安装 `ca-certificates`、`curl`、`gnupg`、`dnsutils`、`jq`、`util-linux` 等依赖；
- 检查反代域名的公网 A/AAAA 是否指向当前 VPS；
- IP 模式跳过 DNS/证书申请，自动检测或校验 IPv4，并检查独立高位端口是否被占用；
- 检查源站 HTTP/HTTPS 连通性和 TLS 证书；
- 检查 TCP 80 和所选 HTTPS/HTTP 端口冲突，避免覆盖另一种 Web 服务；
- 运行前识别已有 Caddy/Nginx，并优先安全复用已有服务；
- 支持连续管理多个反代域名，更新一个域名时保留其他脚本托管站点，并兼容迁移旧版单域名配置；
- 已有手工 Caddy 域名可追加独立非根路径；自动定位唯一站点块、检查路径重叠，并按“域名 + 路径”幂等更新；
- 无法安全定位、根路径接管、路径重叠或重复站点会被拒绝；
- 自动为启用中的 UFW/firewalld 放行域名模式的 TCP 80 + 所选 HTTPS 端口，或 IP 模式选定的独立 TCP 端口，并始终提醒用户另行放行云安全组；
- 修改前备份配置；
- 使用 `caddy validate` 或 `nginx -t` 验证后才 reload；
- 启动或重载失败时自动恢复原配置；
- 验证完整反代链路，成功后输出最终 Emby 地址；
- 提供 `/_emby_proxy_health` 存活检查，并在部署后验证 HTTP 200；
- 记录每条请求的响应字节数、总耗时与回源耗时，日志自动轮转或交给系统 logrotate；
- 安全改写固定源站的 `Location` / `Content-Location`，为子路径补回外部前缀；
- 首选独立子域名或独立端口；仍支持同一域名按 `/`、`/a`、`/b` 映射多个 Emby，但会标记为高级兼容模式并逐路径验证；
- 失败时给出 DNS、安全组、端口、证书和源站排查命令。

## 防止被当作通用 SNI/Host 代理

脚本生成的配置不是通用代理：

- 所有 Caddy `reverse_proxy` 和 Nginx `proxy_pass` 目标都在生成配置时固定，客户端不能通过 SNI、Host、URL 或请求头改变目标源站；
- Caddy 对 HTTP、HTTPS 回源都会把 `Host` 固定为对应的上游地址，不透传客户端提供的任意 Host；
- Nginx 把 `Host` 固定为 `$proxy_host`，HTTPS 回源的 SNI 固定为该路径配置的源站域名；
- Nginx 不把客户端提供的 `X-Forwarded-For` 继续传给 Emby，避免伪造来源链；
- Nginx 入口同时校验 TLS SNI 和 HTTP Host，不符合反代域名的请求返回 421/444；
- 脚本拒绝在源站地址中使用变量、路径、查询参数或其他可由请求者控制的动态目标。
- 响应头改写只匹配脚本已固定的源站；第三方绝对 URL 不会变成新的 `proxy_pass` / `reverse_proxy` 目标。

这些限制防止脚本生成的站点成为“客户端指定任意 SNI/Host，再由 VPS 代为连接”的开放代理。但脚本不会自动改写或担保 VPS 上原先由用户手工创建的其他 Caddy、Nginx、HAProxy、Xray 或 `stream` 配置；已有配置仍需单独审计。

脚本不会自动停止占用 80/443 的其他 Web 服务，因为它可能承载其他站点。确认无用后按错误提示停止，再重新运行脚本。

## 运行前准备

- 域名 A 记录已指向 VPS 的公网 IPv4；
- 只有在 VPS 确实配置了公网 IPv6 时才保留 AAAA 记录；
- 云厂商安全组允许入站 TCP 80、443；
- 如果使用 Cloudflare，安装和排障阶段使用“仅 DNS（灰云）”；
- 源站允许这台 VPS 访问。

若使用 IP 模式，不需要前三项域名/DNS准备；只需确认公网 IPv4 可从客户端访问，并在云安全组放行所选独立 TCP 端口（默认 `8080`）。

脚本能配置 VPS 本机防火墙，但无法修改云厂商控制台中的安全组。

## 本地配置生成测试

修改脚本后可以在不接触系统服务的情况下运行：

```bash
bash tests/test-config-generation.sh
bash tests/test-manager.sh
bash tests/test-manager-stage2.sh
```

测试会检查域名 HTTPS 与 IP HTTP 配置生成、独立端口、已有 Caddy 站点路径插入及更新、路径冲突拒绝、多域名互不覆盖、旧 Caddy 标记迁移、Nginx 每域名变量隔离、管理索引持久化、旧配置导入、状态到安装参数的无损回放、ACME 阶段没有明文 `proxy_pass`、`X-Forwarded-For` 防伪造、子路径响应头改写幂等性，以及第二阶段的诊断、日志过滤、流量统计、备份校验/恢复和校验式自更新。如果本机已安装 Caddy，还会额外执行完整 Caddy 配置验证；正式部署仍会在 reload 前运行 VPS 上的 `caddy validate` 或 `nginx -t`。

## 手动恢复

Caddy 备份位于 `/etc/caddy/Caddyfile.bak-日期时间`：

```bash
sudo cp /etc/caddy/Caddyfile.bak-日期时间 /etc/caddy/Caddyfile
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo systemctl reload caddy
```

如果路径被加入某个导入的 `.caddy`/`.conf` 文件，备份会保存在该文件旁边，脚本完成时会输出准确路径；恢复该文件后仍使用主 `/etc/caddy/Caddyfile` 执行验证和 reload。

Nginx 备份按域名保存，例如 `/etc/nginx/conf.d/emby-proxy-emby.example.com.conf.bak-日期时间`：

```bash
sudo cp /etc/nginx/conf.d/emby-proxy-emby.example.com.conf.bak-日期时间 \
  /etc/nginx/conf.d/emby-proxy-emby.example.com.conf
sudo nginx -t
sudo systemctl reload nginx
```

## 官方依据

- [Caddy：Debian/Ubuntu/Raspbian 安装](https://caddyserver.com/docs/install)
- [Caddy：Automatic HTTPS](https://caddyserver.com/docs/automatic-https)
- [Caddy：reverse_proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
- [Caddy：访问日志与轮转](https://caddyserver.com/docs/caddyfile/directives/log)
- [Caddy：handle_path 与子路径前缀剥离](https://caddyserver.com/docs/caddyfile/directives/handle_path)
- [Nginx：Linux packages](https://nginx.org/en/linux_packages.html)
- [Nginx：HTTP proxy module](https://nginx.org/en/docs/http/ngx_http_proxy_module.html)
- [Nginx：HTTP access log module](https://nginx.org/en/docs/http/ngx_http_log_module.html)
- [工信部门：互联网网站备案办事指南（包含仅通过 IP 地址访问的情形）](https://gzca.miit.gov.cn/zwgk/hlwgl/zcfg/art/2017/art_45159685c81c4b6d8df29845abf3fed8.html)
- [Nginx：WebSocket proxying](https://nginx.org/en/docs/http/websocket.html)
