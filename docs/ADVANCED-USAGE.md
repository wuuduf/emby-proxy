# 高级单机使用

README 适合第一次完成一条域名反代。本页补充单机入口的命令行、路径管理、日志、备份恢复和故障排查。

多台 VPS 的节点注册、DNS 切换、权重、定时策略、IPv6 和集中证书请看[多线路主控与边缘节点](MULTILINE.md)。

## 入口模式和路径管理

同一域名可以为不同路径配置不同的固定源站：

```text
/   -> https://origin-one.example.com
/a  -> https://origin-two.example.com
/b  -> https://split.example.com:8473
```

菜单操作：

```text
4 管理已有入口
 选择入口
 1 新增路径
 2 修改路径源站
 3 删除路径
```

命令行操作：

```bash
sudo emby-proxy route add <入口ID>
sudo emby-proxy route set <入口ID>
sudo emby-proxy route delete <入口ID>
```

路径模式会重写 Emby 常见的 `Location` 和 `Content-Location` 响应头，但部分原生客户端、Emby Connect 和第三方播放器可能不兼容。能使用独立子域名时优先拆分为多个入口。

## 非交互创建

```bash
# Caddy：独立子域名 + 443
sudo emby-proxy add --engine caddy \
  --domain emby.example.com \
  --upstream https://origin.example.com

# Nginx：同一域名 + 独立 HTTPS 端口
sudo emby-proxy add --engine nginx \
  --domain emby.example.com \
  --domain-mode port --https-port 18443 \
  --upstream https://origin.example.com

# Caddy：同一域名多路径
sudo emby-proxy add --engine caddy \
  --domain emby.example.com --domain-mode path \
  --upstream https://origin-one.example.com \
  --route /a=https://origin-two.example.com \
  --route /b=https://origin-three.example.com:8473
```

源站地址只能包含协议、主机和端口。脚本会固定回源 Host，不继承客户端提交的伪造 `X-Forwarded-For` 链，也不会关闭上游 TLS 校验。

## 诊断、日志和流量

```bash
ep doctor
sudo emby-proxy logs <入口ID> --follow
sudo emby-proxy logs <入口ID> --media
sudo emby-proxy logs <入口ID> --errors
sudo emby-proxy logs <入口ID> --slow 2
sudo emby-proxy stats <入口ID> --since 24h
```

诊断会检查系统、DNS、监听端口、TLS、Caddy/Nginx 配置和源站连通性。源站返回任意 HTTP 状态码都表示链路可达，不能单独证明 Emby 登录或媒体播放正常。

访问日志会过滤常见认证头，并删除完整查询串；流量统计从脚本托管的 JSON 日志增量读取，健康检查请求不会计入媒体配额。

## 备份、恢复和更新

```bash
sudo emby-proxy backup list
sudo emby-proxy backup restore <备份ID>
sudo emby-proxy config test
sudo ep update --check
sudo ep update
```

配置写入前会创建带时间戳的备份，候选配置先验证再 reload。reload 失败时会恢复旧配置。更新会校验 `checksums.txt`，只替换脚本管理器和后端文件。

## 完全卸载

```bash
sudo ep uninstall
```

卸载会备份脚本管理的状态、入口配置、日志和 systemd 单元，然后删除脚本托管内容。Caddy/Nginx 程序、其他站点配置和 TLS 证书会保留。确认短语为：

```text
REMOVE EMBY-PROXY
```

## 常见问题

### 源站检查显示 403、404 或 503

这说明 VPS 已经收到源站响应，脚本会把它标记为链路可达。继续检查源站账号权限、Emby 路径和媒体 API；不要为了消除状态码而放宽代理安全限制。

### 域名证书申请失败

确认域名解析到当前 VPS，TCP 80/443 已放行，且没有其他站点占用相同的域名和端口。Cloudflare 使用 DNS-01 时，Token 需要当前 Zone 的 DNS 编辑权限。

### 已有 Caddy/Nginx 站点

脚本会先识别正在运行的服务，只写入带脚本标记的站点或路径。发现同域名的非托管配置时会停止并提示人工确认，避免覆盖原站点。

### `sudo: unable to resolve host`

这是 VPS 的 `/etc/hostname` 与 `/etc/hosts` 不一致。先修复主机名映射，再重新执行 sudo 命令。

### 如何清理测试环境

在每台测试 VPS 执行 `sudo ep uninstall`，保存卸载备份和 SHA256 文件后再确认删除。

## 相关文档

- [README 快速上手](../README.md)
- [多线路主控与边缘节点](MULTILINE.md)
- [证书自动化](CERTIFICATES.md)
- [测试与验收](TESTING.md)
- [菜单设计](MENU-DESIGN.md)
