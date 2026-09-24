# 开发与验证

## 一次只解决一个有证据的问题

开始先看 `git status --short`、`git branch --show-current`，确定改的是当前工作树。
用下面五行描述任务即可，不必复制长篇提示词：

```text
目标：菜单同版本更新后自动重启失效。
范围：menu_update 和对应测试，不重写更新器。
约束：die 仍只结束本次操作；不影响其他菜单。
验收：内容变化才重启；失败、取消、未变化均可回到菜单。
验证：先补失败回归，再定向测试，再全量检查；不改 VPS。
```

复审重点：真实调用路径是否覆盖、失败是否回滚、变量是否跨子进程传递、输出是否泄密、文档是否夸大验证结论。

## 依赖与命令

普通用户运行，需要 Bash、Python 3.9+、jq、curl、tar、diff 和常规 Unix 工具。
本地 macOS 也能测逻辑，但正式部署目标仍是 Debian/Ubuntu + systemd。
不自动安装依赖，不用 sudo 跑测试；部分测试专门验证非 root 的 sudo 重执行路径。

```bash
python3 scripts/check.py --quick
python3 scripts/check.py --suite menu-update --suite controller-model
python3 scripts/check.py
```

- `--quick` 检查每一个 Shell 文件、Python 文件、内嵌 Python 和发布清单。
  `bash -n a b` 只检查 a，不能拿它当多文件语法检查。
- 完整检查发现 `tests/test-*.sh` 与 `tests/test-*.py` 自动运行，单套默认超时 120 秒。
- `--timeout 180` 可以调整超时；失败后仍执行其他套件，最后以非零状态退出。
- `.test-results/` 保存每套日志和 `summary.json`，不提交版本库。
- 检查器自身有失败退出、超时、第二文件语法及错误校验值回归。
- SHA256 不匹配时，先 review 两个发布文件的 diff，再**显式**重生成：

```bash
python3 - <<'PY'
import hashlib
from pathlib import Path
names = ('emby-proxy', 'setup-emby-proxy.sh')
Path('checksums.txt').write_text(''.join(
    hashlib.sha256(Path(n).read_bytes()).hexdigest() + '  ' + n + '\n'
    for n in names))
PY
```

## 测试分层与边界

| 层级 | 本仓库入口 | 能证明什么 |
|---|---|---|
| 静态 | `--quick` | Bash/Python 可解析，发布脚本与清单一致 |
| 配置/菜单 | CLI、manager、menu、config-generation 测试 | 临时目录和 mock 中的分发、文本生成及失败处理 |
| 状态机 | `test-controller-model.py` | 固定时钟下注册、配额、优先级、DNS 失败重试；禁止出网 |
| 回环服务 | `test-controller.sh` | 真实 Python 服务与 CLI 并发写状态，监听 127.0.0.1 |
| 实机验收 | 用户单独授权后执行 | 真正的 systemd、Caddy/Nginx、DNS、TLS 和媒体播放 |

`.github/workflows/check.yml` 配置 Ubuntu 22.04/24.04 与 macOS 验证。同一 `scripts/check.py` 本地与 CI 共用。
新增工作流只有推送后才会在 GitHub 运行；本地通过不意味着远端 CI 已通过。
目前不把 ShellCheck、实际 Caddy/Nginx 配置加载或公网播放称为本地自动门禁。

## 实机操作前后

1. 先确认服务器、端口、运行版本、真实 Web 配置路径、非托管站点及原健康状态。
2. 备份配置和状态，确定可恢复命令；不要直接重写整个共享 Caddyfile。
3. 用唯一测试入口/端口，先验证配置再 reload，避免 restart 中断现有连接。
4. 分别验证外部 DNS、证书、客户端实际请求到达的域名/路径、源站响应和媒体 Range/播放。
5. 多线路应分别演练失联、超额、恢复、全部不可用、DNS API 失败；验证 TTL 延迟，不能只手改状态文件证明真实流量耗尽。
6. 对比原服务仍健康，清理本次临时配置。只在这套证据齐备时报告“实机通过”。
