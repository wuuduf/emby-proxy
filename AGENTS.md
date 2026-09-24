# emby-proxy 开发地图

## 开始之前
- 确认 `git status --short` 和当前分支；不要覆盖未提交改动。
- 先读 [架构](docs/ARCHITECTURE.md) 和 [行为约束](docs/REQUIREMENTS.md)，再找本次改动的入口与测试。
- 本仓库是 Bash 安装器/菜单管理器，控制器 Python 内嵌在 `emby-proxy`。不要套用 Web 框架目录模板。
- 实验多线路功能不等于稳定版；不要把其他工作树、临时文件或聊天记录当作当前部署证据。

## 开发循环
1. 用两三句话写清问题、改动边界和验收条件。
2. 先复现；修 bug 应先补失败回归，再改最少代码。
3. 同一改动同时检查 CLI、菜单、错误返回路径；不能只验证函数返回成功。
4. 执行下面的检查，复审 diff，报告实际运行结果与未验证项。
5. 提交、推送、改 DNS、操作 VPS 均须用户本次明确授权；本地测试不需要真实密码或 API Token。

## 命令（在仓库根目录，以普通用户执行）
```bash
python3 scripts/check.py --quick                # 逐文件语法 + 内嵌 Python + SHA256
python3 scripts/check.py --suite menu-update    # 定向回归
python3 scripts/check.py                        # 全部测试 + 日志/JSON 报告
```
依赖、覆盖边界和真实环境验收见 [验证指南](docs/DEVELOPMENT.md)。检查失败不能当作通过；不要为通过测试删除断言。

## 不变量
- 保持 `bash <(curl ...)`、`emby-proxy`、`ep` 入口与单脚本分发兼容。
- 不新增明文 IP 播放入口，不接受客户端控制任意回源目标。
- 不覆盖或卸载用户的非托管 Caddy/Nginx 站点、证书及软件包。
- 配置变更需备份、校验、热重载和失败恢复；菜单错误只返回上一层。
- 不关闭源站 TLS 验证；任意有效 HTTP 状态只代表链路可达，不等于可播放。
- 不在代码、测试、日志、示例中放真实服务器地址、注册码和凭据；示例用 `.example.com` / `192.0.2.0/24`。
- 修改两个发布脚本后显式更新 `checksums.txt`，验证工具不得自动“修复”校验值。
- 不为工程化大规模拆分内嵌控制器；先有覆盖，再单独设计迁移和分发兼容。

## 导航
- `setup-emby-proxy.sh`：环境检查、配置生成、安装、回滚。
- `emby-proxy`：菜单、索引、更新/卸载、多线路控制器/边缘命令。
- `tests/`：本地 fixtures、mock 回归及回环 HTTP 测试，不是 VPS 验收。
- [本轮记录与下一步](docs/WORKLOG.md)：完成证据及剩余缺口。
