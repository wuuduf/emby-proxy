# emby-proxy

给 Emby 源站快速套一层域名 HTTPS 反代，支持 Caddy、Nginx、多个入口和同域名多路径。

脚本只允许固定源站，不接受客户端临时指定公网目标，避免 VPS 变成通用代理。

本项目由 [wuuduf](https://github.com/wuuduf) 编写和维护。安装后可使用短命令 `ep`。

## 快速开始

一次普通的域名反代只需要四步：准备 DNS → 安装管理器 → 添加入口 → 访问验证。

### 1. 准备域名和源站

把反代域名的 A 记录指向 VPS 公网 IPv4：

```text
emby.example.com  ->  VPS 公网 IPv4
```

同时确认：

- VPS 系统是 Debian 或 Ubuntu，并使用 systemd；
- 云防火墙/安全组放行 TCP 80 和 443；
- 源站地址可从 VPS 访问；
- 没有可用 IPv6 时不要添加 AAAA 记录。

源站只填写协议、主机和端口，例如：

```text
https://origin.example.com
https://origin.example.com:8443
http://10.0.0.8:8096
```

### 2. 安装并打开菜单

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wuuduf/emby-proxy/main/setup-emby-proxy.sh)
```

安装器第一次运行只部署管理器，不会自动改动现有 Caddy/Nginx 站点。完成后打开菜单：

```bash
ep
```

### 3. 新增反代入口

在菜单选择：

```text
3  新增反代入口
```

按向导填写：

1. 反代引擎：回车使用 Caddy；已有 Nginx 时选择 Nginx；
2. 域名结构：默认使用独立子域名 + 443；
3. 对外访问域名：例如 `emby.example.com`；
4. Emby 源站：例如 `https://origin.example.com`。

脚本会自动检查系统、DNS、端口、源站和已有服务。发现已有 Caddy/Nginx 时，只追加脚本托管的独立配置，保留原有站点。

### 4. 验证访问

浏览器或 Emby 客户端访问：

```text
https://emby.example.com/
```

服务器上可以检查：

```bash
ep doctor
ep status
```

`/_emby_proxy_health` 返回 200 只表示反代入口正常；源站返回 403、404 或 503 时，脚本会显示“链路可达”，不能据此判断 Emby 账号登录或媒体播放一定正常。

## 入口模式

| 模式 | 示例 | 适用场景 |
| --- | --- | --- |
| 独立子域名 + 443 | `emby1.example.com` | 首选，兼容性最好 |
| 同一域名 + 独立 HTTPS 端口 | `example.com:18443` | 子域名数量有限 |
| 同一域名 + 不同路径 | `/`、`/a`、`/b` | 高级兼容模式，部分客户端可能不兼容 |

自定义 HTTPS 端口还需要在云防火墙和安全组放行对应端口。路径模式支持 WebSocket、`Location` 和 `Content-Location` 重写，能使用独立子域名时优先选择独立子域名。

## 同一域名反代多个 Emby

```text
/   -> https://origin-one.example.com
/a  -> https://origin-two.example.com
/b  -> https://split.example.com:8473
```

访问地址：

```text
https://emby.example.com/
https://emby.example.com/a/
https://emby.example.com/b/
```

在菜单选择 `4 管理已有入口` → 选择入口 → `1 新增路径`。请求 `/b/movie` 时，脚本会去掉 `/b` 前缀，再向源站请求 `/movie`。

## 菜单和常用命令

```text
 1  查看全部反代入口
 2  查看入口详情
 3  新增反代入口
 4  管理已有入口
 5  运行完整诊断
 6  日志与流量统计
 7  备份、差异与恢复
 8  Web 服务管理
 9  导入旧版配置
10  检查/更新程序
11  多线路控制器（实验版）
12  完全卸载 emby-proxy
 0  退出
```

```bash
ep                                      # 打开菜单
ep list                                 # 列出入口
ep doctor                               # 完整诊断
ep status                               # 服务与入口概况
ep update --check                       # 检查更新
ep update                               # 更新并自动重启面板
sudo emby-proxy logs <入口ID> --follow
sudo emby-proxy stats <入口ID> --since 24h
```

更新成功后，交互终端会自动打开新版本菜单；不会重启 Caddy/Nginx，也不会中断正在播放的媒体。

## 安全卸载

```bash
sudo ep uninstall
```

卸载前会把脚本管理的状态、入口配置、日志、systemd 单元和管理器文件打包并生成 SHA256 校验，然后要求输入 `REMOVE EMBY-PROXY`。卸载只清理脚本托管内容，保留 Caddy/Nginx、其他站点配置和 TLS 证书。

## 进阶文档

第一次使用先完成上面的单机反代。需要更多功能时按下面的文档继续：

- [高级单机使用](docs/ADVANCED-USAGE.md)：非交互创建、备份恢复、日志统计、路径/端口管理和常见故障；
- [多线路主控与边缘节点](docs/MULTILINE.md)：Cloudflare、DNSPod、优先级、配额、权重、定时切换、IPv6 和集中证书；
- [证书自动化](docs/CERTIFICATES.md)：主控与备用节点证书流程；
- [测试与验收](docs/TESTING.md)：本地回归、VPS 验收和故障切换测试；
- [菜单设计](docs/MENU-DESIGN.md)：菜单结构与交互约定；
- [架构与开发](docs/ARCHITECTURE.md) / [开发与验证](docs/DEVELOPMENT.md)：代码阅读和开发流程。

## 已知边界

- 源站只能包含协议、主机和端口，不能带路径、账号或查询参数；
- 证书校验不会被关闭，源站 TLS 错误不会被脚本绕过；
- DNS 切换受 TTL、递归缓存和已有播放连接影响，不是逐请求负载均衡；
- 多线路控制器是实验功能，控制器只负责注册、心跳、节点选择和 DNS，不转发媒体流量；
- 控制器托管的多线路边缘统一使用业务域名 443，独立 HTTPS 端口模式用于单机入口；
- 控制面启用 HTTPS 或 WireGuard 后再开放给边缘节点，不要把未加密的 19090 端口直接暴露到公网。

## 测试

```bash
python3 scripts/check.py --quick  # 语法和发布校验
python3 scripts/check.py          # 完整回归
```

需要 Python 3.9+、Bash、jq、curl 和常规 Unix 工具。完整测试结果写入 `.test-results/`。

## 许可证

[MIT](LICENSE)
