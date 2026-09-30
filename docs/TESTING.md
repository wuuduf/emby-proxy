# Emby Proxy 测试与验收文档

本文件用于验证 `emby-proxy` 的单机反代、多线路控制器、集中证书和菜单流程。

> 测试分为“本地自动测试”和“真实环境验收”。本地通过不代表公网 DNS、ACME、Caddy/Nginx 或 Emby 播放已经通过。真实测试必须使用专用测试域名、测试源站和可回滚的 VPS。

## 1. 测试原则

- 先备份，再改配置；优先使用独立域名、独立端口和独立状态目录。
- 一次只验证一个故障变量：源站、证书、DNS、节点心跳不要同时改变。
- 不在测试文件、日志、命令历史或截图中保存 Cloudflare Token、节点注册码、私钥和真实密码。
- 不用 `curl -k`、关闭源站 TLS 校验或手工改状态文件来制造“成功”。
- 反代返回任意有效 HTTP 状态，只能证明链路可达；不能证明登录、API 或媒体播放正常。
- 测试结束清理临时 DNS、systemd 单元、证书目录和测试入口，确认原有站点仍正常。

## 2. 本地自动测试

### 2.1 环境

使用普通用户，不要 `sudo` 运行测试：

```bash
cd /path/to/emby-reverse-proxy-installer
command -v bash python3 jq curl tar diff
```

项目支持 Bash、Python 3.9+；正式部署目标为 Debian/Ubuntu + systemd。macOS 可运行逻辑回归，但不能代替 Linux 服务验收。

### 2.2 快速检查

```bash
python3 scripts/check.py --quick
```

应看到：

```text
PASS syntax
PASS release checksums
```

它检查 Shell/Python 语法、内嵌 Python 和 `checksums.txt`。校验失败时先审查发布脚本，再显式更新校验值，不要自动忽略。

### 2.3 定向测试

```bash
# 菜单、配置生成和控制器
python3 scripts/check.py --suite menu-ux
python3 scripts/check.py --suite config-generation
python3 scripts/check.py --suite controller-model
python3 scripts/check.py --suite controller-failover
python3 scripts/check.py --suite controller-certificates

# 真实本地回环控制器
python3 scripts/check.py --suite controller
```

证书测试使用临时自签证书和本地 HTTPS，不连接真实 Cloudflare/Let's Encrypt。主要验收：

- HTTP 或错误节点令牌不能领取证书；
- 入口 ID 不匹配时拒绝；
- HTTPS 请求不跟随重定向泄漏令牌；
- 证书域名、私钥、有效期和信任链校验失败时不替换；
- 新证书 Reload 失败恢复旧版本；
- DNS-01/Certbot 命令不把 Token 放入命令行；
- 续期定时器或主控安装失败时恢复旧状态；
- 节点证书同步失败不破坏现有有效证书。

### 2.4 全量门禁

```bash
python3 scripts/check.py
```

通过条件：所有测试套件退出码为 0，最后显示 `N/N suites passed`。日志和汇总在 `.test-results/`，该目录不提交仓库。

## 3. 单机反代验收

在测试 VPS 上执行安装器，建议使用独立测试域名：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wuuduf/emby-proxy/main/setup-emby-proxy.sh)
ep
```

选择“新增反代入口”，完成后依次检查：

```bash
sudo ep status
sudo ep diagnose
systemctl is-active caddy   # 或 nginx
ss -lntp | grep -E ':(80|443)\\b'
curl -fsS -o /dev/null -w '%{http_code}\\n' https://test.example.com/_emby_proxy_health
```

验收项：

- 只修改脚本托管配置，不覆盖其他站点；
- `caddy validate` 或 `nginx -t` 通过；
- Reload 失败能恢复旧配置；
- `X-Forwarded-For` 使用真实 `$remote_addr`，不继承客户端伪造链；
- 源站 Host/SNI 固定为配置的源站；
- 源站返回 403/404/5xx 时报告“链路可达”，不误称业务可播放；
- Emby 播放器实际请求的 API、Range、音视频流分别验证。

## 4. 多线路控制器验收

### 4.1 拓扑

```text
客户端 → Cloudflare A 记录 → 当前边缘节点 → 固定源站
                                      ↑
                         主控只负责注册/心跳/DNS
```

主控不转发媒体流量。使用 Cloudflare DNS only（灰云）进行首次切换，降低代理缓存和证书排障复杂度。

### 4.2 初始化主控

准备：

- 业务测试域名及 Cloudflare A 记录；
- 固定源站 URL；
- Cloudflare Token（仅主控保存，最小 DNS 权限）；
- 主控 VPS、至少两台边缘 VPS；
- 所有边缘统一使用 Caddy 或统一使用 Nginx。

菜单路径：

```text
多线路控制器 → 1 配置入口
```

确认状态文件为 `0600`，Token 文件为 `0600`，且不出现在生成的边缘命令中。

### 4.3 集中证书模式

推荐顺序：

```text
1 配置入口
→ 8 配置自动证书
→ 3 添加边缘节点
```

额外准备一个独立主控域名，例如 `control.example.com`：

1. A 记录提前指向主控 VPS；
2. 放行 TCP 19090；
3. 不与业务入口域名相同；
4. 不要求业务 A 记录临时切换到主控。

证书验收：

```bash
sudo ep controller status --state /etc/emby-proxy/controller.json
sudo systemctl status emby-proxy-cert-renew.timer
sudo systemctl status emby-proxy-cert-sync.timer
```

备用节点应在业务 DNS 仍指向节点 A 时完成：

```text
注册 → HTTPS 领取 → 证书校验 → Caddy/Nginx 配置 → Reload → 本机健康检查
```

节点证书状态为 `ready` 后，才允许进入候选池。

### 4.4 故障切换矩阵

| 场景 | 操作 | 预期 |
|---|---|---|
| A 正常 | 两节点持续心跳 | DNS 指向最高优先级 A |
| A 单次失败 | 发送 1 次不健康心跳 | A 显示故障观察，不切换 |
| A 连续 3 次失败 | 连续发送 3 次不健康心跳 | A 下线，候选 B |
| B 恢复一次 | B 发送 1 次健康心跳 | B 显示恢复观察，不切换 |
| B 连续成功且持续 60 秒 | 按 30 秒周期发送心跳 | B 恢复候选 |
| 当前节点配额用完 | 用量达到配额 | 立即排除当前节点 |
| 节点超过 90 秒无心跳 | 停止节点 timer | 节点失联，不等冷却 |
| 高优先级节点恢复 | 恢复节点优先级更高 | 遵守 180 秒抢占冷却 |
| 同优先级 | 两节点优先级相同 | 保留当前节点，避免抖动 |
| Cloudflare PUT 成功但回读失败 | mock 或临时阻断 API | 不标记切换成功，下轮重试 |
| 所有节点不可用 | 停止所有心跳 | 保留最近已确认 DNS，明确告警 |

每次切换都记录：时间、旧节点、新节点、选路原因、DNS API 返回、回读 IP。DNS 切换成功不等于客户端缓存和已有播放连接立即迁移。

## 5. 真实环境验收清单

### 开始前

- [ ] 确认 VPS、SSH 端口、当前 Caddy/Nginx 配置和监听端口；
- [ ] 备份 `/etc/emby-proxy`、Caddy/Nginx 托管配置和 systemd 单元；
- [ ] 使用测试域名，不覆盖生产 A 记录；
- [ ] 确认防火墙：边缘放行 80/443，主控仅允许边缘访问 19090；
- [ ] 确认没有其他程序占用脚本需要的端口；
- [ ] 确认源站允许来自所有边缘节点的访问。

### 证书

- [ ] 主控独立域名已解析到主控；
- [ ] Cloudflare Token 仅存主控，权限最小；
- [ ] DNS-01 签发成功，业务 A 记录未被改写；
- [ ] 两台边缘均获得正确域名证书；
- [ ] 证书私钥权限正确，非托管证书未被覆盖；
- [ ] 续期 timer、同步 timer 均运行；
- [ ] 模拟下载失败、证书不匹配和 Reload 失败，旧证书仍可用。

### 服务与播放

- [ ] Caddy/Nginx 配置验证通过；
- [ ] `/_emby_proxy_health` 返回 200；
- [ ] Emby 登录/API 请求成功；
- [ ] 视频 Range、音频转码、字幕、图片请求分别成功；
- [ ] 观察日志中的状态码、响应字节和耗时；
- [ ] 源站 403/404/5xx 时面板提示链路状态，而不是伪造成功。

### 结束后

- [ ] 恢复/清理测试 DNS、测试证书和临时 systemd 单元；
- [ ] 运行原站健康检查，确认已有服务未中断；
- [ ] 删除包含 Token、注册码、私钥的测试日志和 shell history；
- [ ] 保留测试报告、配置 diff、时间线和未验证项。

## 6. 报告模板

```markdown
# Emby Proxy 测试报告

日期：
版本/提交：
测试范围：本地 / 单机 / 多线路 / 集中证书
环境：Debian/Ubuntu、Caddy/Nginx、节点数量

## 结果
- 自动测试：__/__
- 配置验证：通过 / 失败
- TLS/证书：通过 / 失败 / 未测试
- DNS 切换：通过 / 失败 / 未测试
- Emby 播放：通过 / 失败 / 未测试

## 关键证据
- 命令与退出码：
- 配置备份路径和 SHA256：
- systemd 状态：
- DNS 旧 IP → 新 IP：
- 证书版本与到期时间：
- 代表性请求状态：

## 问题与回滚
- 问题：
- 复现步骤：
- 影响范围：
- 回滚命令：

## 限制
明确列出没有验证的真实 CA、DNS TTL、VPS、播放器和源站行为。
```
