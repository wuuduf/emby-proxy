# Emby HTTPS 一键反向代理脚本（Caddy / Nginx）

`setup-emby-proxy.sh` 用于在 Debian/Ubuntu VPS 上选择 Caddy 或 Nginx，为一个或多个 Emby 源站配置 HTTPS 反向代理。

除基础反代外，脚本还会配置固定的健康检查、可轮转的请求/流媒体日志，并安全改写源站返回的 `Location` 与 `Content-Location`。

## 一键启动命令

在 Debian/Ubuntu VPS 上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/wuuduf/emby-reverse-proxy-installer/main/setup-emby-proxy.sh \
  -o /tmp/setup-emby-proxy.sh && \
chmod +x /tmp/setup-emby-proxy.sh && \
sudo /tmp/setup-emby-proxy.sh
```

脚本会先检查系统、已有 Caddy/Nginx、DNS、端口及源站；确认配置并通过语法验证后才会重载服务。

## 交互式使用

把脚本上传到 VPS，然后执行：

```bash
chmod +x setup-emby-proxy.sh
sudo ./setup-emby-proxy.sh
```

根据菜单先输入：

1. 选择 `Caddy` 或 `Nginx`；
2. 对外访问域名，例如 `emby.example.com`；
3. Emby 源站，例如 `origin.example.com`、`https://origin.example.com` 或 `http://1.2.3.4:8096`。

如果输入的域名已经是一个手工配置的 Caddy 站点，脚本会先要求输入 `/a`、`/emby2` 等非根路径，检查与现有路径没有重叠后，再询问 Emby 源站。原站点的 `/`、证书、其他指令和日志设置保持不变。

输入根路径源站后，可以继续添加任意数量的路径源站，例如：

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
  --engine caddy \
  --domain emby.example.com \
  --upstream origin.example.com
```

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
  --upstream https://origin.example.com \
  --route /a=https://emby-two.example.com \
  --route /b=http://10.0.0.3:8096
```

如果源站只填写域名，脚本会先尝试 HTTPS，再尝试 HTTP。源站地址不能带 `/emby/`、`/web/index.html`、查询参数或账号密码。

> **子路径兼容性提醒：** Caddy 官方将此类配置称为可能存在“subfolder problem”的模式。脚本会正确完成前缀剥离、WebSocket 和路径级回源，但 Emby 的部分原生客户端、Emby Connect 或源站返回的绝对路径可能不识别 `/a` 这类额外前缀。请逐个使用完整地址进行实际登录和播放测试；兼容性要求最高时，仍建议每个 Emby 使用独立子域名。

## 两种模式的区别

### Caddy

- 使用 Caddy 官方 stable apt 软件源；
- Caddy 自动申请、安装及续期 HTTPS 证书；
- Caddy 原生处理 WebSocket；
- 配置写入 `/etc/caddy/Caddyfile` 中带域名的独立脚本托管块；可连续管理多个反代域名。

### Nginx

- 使用 Debian/Ubuntu 软件源安装 `nginx` 与 `certbot`；
- Certbot 使用 webroot 方式申请及续期 Let's Encrypt 证书；
- 自动安装证书续期后的 Nginx reload hook；
- 显式配置 Emby WebSocket、流式传输、长连接超时、客户端 IP 头；
- HTTPS 回源会发送正确 SNI，并使用系统 CA 校验源站证书；
- 每个域名使用独立配置，例如 `/etc/nginx/conf.d/emby-proxy-emby.example.com.conf`；内部变量、日志格式和 TLS session cache 也按域名隔离；
- 首次申请证书期间只开放 ACME challenge，其他 HTTP 请求返回 503，不会临时提供明文 Emby 反代；
- 发送给源站的 `X-Forwarded-For` 固定来自 Nginx 的 `$remote_addr`，不继承客户端伪造的来源链。

## 健康检查与流量日志

部署完成后，可用以下地址检查 **Caddy/Nginx 入口是否存活**：

```bash
curl -fsS https://emby.example.com/_emby_proxy_health
```

正常返回 `ok` 和 HTTP 200。这个地址不会连接任意外部目标，也不会暴露源站信息；它表示代理入口与证书可用，不等同于每个 Emby 源站的持续健康状态。安装时脚本仍会逐个探测源站，并逐路径完成一次端到端验证。

追加到已有 Caddy 域名时，健康地址跟随新增路径，例如 `/emby2/_emby_proxy_health`，避免占用原站点的根级健康路径。

详细访问日志位置：

- Caddy：`/var/log/caddy/emby-proxy-域名-access.log`，JSON 格式，100 MiB 轮转，最多保留 5 个历史文件/30 天；
- Nginx：`/var/log/nginx/emby-proxy-域名-access.log`，JSON 格式，由系统 Nginx logrotate 规则轮转。

每条请求都包含响应字节数、总耗时、回源耗时、状态码和上游地址，可直接定位慢播放、断流或异常流量：

```bash
sudo tail -F /var/log/nginx/emby-proxy-emby.example.com-access.log
# 或
sudo tail -F /var/log/caddy/emby-proxy-emby.example.com-access.log

# 只关注常见媒体请求
sudo tail -F /var/log/nginx/emby-proxy-emby.example.com-access.log \
  | grep -Ei '/Videos/|/Audio/|/stream|\.m3u8'
```

Nginx 日志只记录 `$uri`，不记录查询参数；Caddy 会隐藏常见 `api_key`、`token`、`X-Emby-Token` 和 `X-MediaBrowser-Token`。日志仍可能包含客户端 IP、媒体 ID 等运维信息，文件权限默认为 `0640`，不要公开分享原始日志。

向手工配置的现有 Caddy 域名追加路径时，脚本沿用该站点原来的日志设置，不会为了单个路径擅自改变整站日志。

## URL 改写范围

脚本会按每条固定路由改写响应头：

- 源站 `Location` / `Content-Location` 中指向**当前固定源站**的绝对 URL，会改成对外 HTTPS 域名；
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
- 安装 `ca-certificates`、`curl`、`gnupg`、`dnsutils` 等依赖；
- 检查反代域名的公网 A/AAAA 是否指向当前 VPS；
- 检查源站 HTTP/HTTPS 连通性和 TLS 证书；
- 检查 80/443 端口冲突，避免覆盖另一种 Web 服务；
- 运行前识别已有 Caddy/Nginx，并优先安全复用已有服务；
- 支持连续管理多个反代域名，更新一个域名时保留其他脚本托管站点，并兼容迁移旧版单域名配置；
- 已有手工 Caddy 域名可追加独立非根路径；自动定位唯一站点块、检查路径重叠，并按“域名 + 路径”幂等更新；
- 无法安全定位、根路径接管、路径重叠或重复站点会被拒绝；
- 自动为启用中的 UFW/firewalld 放行 TCP 80/443；
- 修改前备份配置；
- 使用 `caddy validate` 或 `nginx -t` 验证后才 reload；
- 启动或重载失败时自动恢复原配置；
- 验证完整 HTTPS 反代链路，成功后输出最终 Emby 地址；
- 提供 `/_emby_proxy_health` 存活检查，并在部署后验证 HTTP 200；
- 记录每条请求的响应字节数、总耗时与回源耗时，日志自动轮转或交给系统 logrotate；
- 安全改写固定源站的 `Location` / `Content-Location`，为子路径补回外部前缀；
- 支持同一域名按 `/`、`/a`、`/b` 等路径映射多个 Emby，并逐路径验证；
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

脚本能配置 VPS 本机防火墙，但无法修改云厂商控制台中的安全组。

## 本地配置生成测试

修改脚本后可以在不接触系统服务的情况下运行：

```bash
bash tests/test-config-generation.sh
```

测试会检查已有 Caddy 站点路径插入及更新、路径冲突拒绝、多域名互不覆盖、旧 Caddy 标记迁移、Nginx 每域名变量隔离、ACME 阶段没有明文 `proxy_pass`、`X-Forwarded-For` 防伪造，以及子路径响应头改写幂等性。如果本机已安装 Caddy，还会额外执行完整 Caddy 配置验证；正式部署仍会在 reload 前运行 VPS 上的 `caddy validate` 或 `nginx -t`。

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
- [Nginx：WebSocket proxying](https://nginx.org/en/docs/http/websocket.html)
