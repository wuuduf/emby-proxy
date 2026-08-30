# emby-proxy

给 Emby 源站快速套一层域名 HTTPS 反代. 支持 Caddy / Nginx、多个入口、独立 HTTPS 端口和同域名多路径.

脚本只允许固定源站, 不提供任意目标转发, 避免 VPS 被当成通用代理.

本项目由 [wuuduf](https://github.com/wuuduf) 编写和维护.

项目短命令为 **ep**；仓库改名后仍会保留现有更新地址兼容性.

## 安装

Debian / Ubuntu VPS 执行:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wuuduf/emby-proxy/main/setup-emby-proxy.sh)
```

跑完直接出菜单. 脚本会安装管理器 `emby-proxy`, 同时创建短命令 `ep`, 以后敲:

```bash
ep
```

普通用户执行 `ep` 会自动调用 sudo. 首次安装只部署管理菜单, 不会立刻安装 Web 服务或修改现有站点.

如果不想使用进程替换, 也可以继续使用传统三步命令:

```bash
curl -fsSL https://raw.githubusercontent.com/wuuduf/emby-proxy/main/setup-emby-proxy.sh -o /tmp/setup-emby-proxy.sh
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

交互终端更新完成后会自动打开新版本面板. 不会重启 Caddy/Nginx, 不会中断正在播放的媒体.

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
