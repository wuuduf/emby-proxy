#!/usr/bin/env python3
"""真实 Bash 菜单输入回归；替身仅隔离网络、systemd 和配置写入。"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MenuUX(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.state = self.home / 'controller.json'
        self.data = {'entry_id': 'domain-test.example.com', 'domain': 'test.example.com',
                     'source': 'https://origin.example.com', 'engine': 'caddy',
                     'nodes': {}, 'enroll_tokens': {}, 'active_node': None}
        self.state.write_text(json.dumps(self.data))

    def run_menu(self, code, inputs=''):
        env = dict(os.environ, EMBY_PROXY_MANAGER_LIB_ONLY='1',
                   EMBY_PROXY_STATE_HOME=str(self.home), EMBY_PROXY_NO_PAUSE='1',
                   EMBY_PROXY_NO_CLEAR='1')
        return subprocess.run(['bash', '-c', 'source "$1"; ' + code, 'test', str(ROOT / 'emby-proxy')],
                              input=inputs, text=True, capture_output=True, env=env, timeout=8)

    def test_init_minimal_defaults_and_retry(self):
        self.state.unlink()
        r = self.run_menu('controller_cli() { printf "ARG:%s\\n" "$@"; }; controller_init_menu',
                          'bad domain\nTEST.EXAMPLE.COM\norigin.example.com:8443\nn\n\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        for arg in ['domain-test.example.com', 'test.example.com', 'https://origin.example.com:8443', 'caddy']:
            self.assertIn('ARG:' + arg + '\n', r.stdout)
        self.assertNotIn('主控状态文件（', r.stdout)

    def test_init_cancel_preserves_state(self):
        before = self.state.read_bytes()
        r = self.run_menu('controller_init_menu', 'q\n')
        self.assertEqual(before, self.state.read_bytes())
        self.assertNotIn('Traceback', r.stderr)

    def test_init_reuses_cloudflare_token_without_reprompt(self):
        self.state.unlink()
        (self.home / 'cf.token').write_text('fixture-token\n')
        r = self.run_menu('controller_cf_discover_ids() { printf "zone-id\\trecord-id"; }; '
                          'controller_cli() { printf "ARG:%s\\n" "$@"; }; controller_init_menu',
                          'test.example.com\norigin.example.com\n\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('自动沿用本地 600 权限文件', r.stdout)
        self.assertNotIn('API Token（输入隐藏', r.stdout)
        self.assertIn('ARG:--token-file', r.stdout)
        self.assertEqual((self.home / 'cf.token').stat().st_mode & 0o777, 0o600)

    def test_issue_minimal_defaults_never_detects_controller_ip(self):
        self.data['controller_url'] = 'https://control.example.com'
        self.state.write_text(json.dumps(self.data))
        r = self.run_menu('curl() { [[ "$*" == *"/status" ]] || return 99; '
                          "printf '{\"entry_id\":\"domain-test.example.com\"}'; }; "
                          'controller_cli() { printf "ARG:%s\\n" "$@"; }; controller_issue_menu', '\n\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        for arg in ['https://control.example.com', '100', '0']:
            self.assertIn('ARG:' + arg + '\n', r.stdout)
        self.assertNotIn('ARG:--public-ip', r.stdout)
        self.assertNotIn('ARG:--node-id', r.stdout)
        self.assertIn('边缘 VPS', r.stdout)

    def test_issue_advanced_quota_and_ip_retry(self):
        r = self.run_menu("curl() { printf '{\"entry_id\":\"domain-test.example.com\"}'; }; "
                          'controller_cli() { printf "ARG:%s\\n" "$@"; }; controller_issue_menu',
                          'https://control.example.com\ny\n香港线路\n50\nnope\n1.5TB\n999.2.3.4\n192.0.2.10\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        for arg in ['香港线路', '50', '1649267441664', '192.0.2.10']:
            self.assertIn('ARG:' + arg + '\n', r.stdout)

    def test_issue_cancel_creates_no_token(self):
        r = self.run_menu("curl() { printf '{\"entry_id\":\"domain-test.example.com\"}'; }; "
                          'controller_cli() { echo SHOULD_NOT_ISSUE; }; controller_issue_menu',
                          'https://control.example.com\nq\n')
        self.assertNotIn('SHOULD_NOT_ISSUE', r.stdout)

    def test_wrong_controller_does_not_issue(self):
        r = self.run_menu('curl() { printf \'{"entry_id":"domain-other.example.com"}\'; }; '
                          'controller_cli() { echo SHOULD_NOT_ISSUE; }; controller_issue_menu',
                          'https://control.example.com\n192.0.2.10\n\n\n\n')
        self.assertNotIn('SHOULD_NOT_ISSUE', r.stdout)
        self.assertIn('入口不匹配', r.stderr)

    def test_unreachable_controller_does_not_issue(self):
        r = self.run_menu('curl() { return 7; }; controller_cli() { echo SHOULD_NOT_ISSUE; }; controller_issue_menu',
                          'https://control.example.com\n192.0.2.10\n\n\n\n')
        self.assertNotIn('SHOULD_NOT_ISSUE', r.stdout)
        self.assertIn('选择 2', r.stderr)

    def test_eof_returns_from_main_and_controller(self):
        for menu in ['main_menu', 'controller_menu']:
            r = self.run_menu('systemctl() { return 3; }; ' + menu + '; echo RETURNED')
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('RETURNED', r.stdout)

    def test_compact_status_no_versions_or_socket_dump(self):
        r = self.run_menu('service_line() { echo UNEXPECTED_VERSION; }; '
                          'ss() { echo UNEXPECTED_SOCKET; }; print_status compact')
        self.assertNotIn('UNEXPECTED', r.stdout)
        self.assertIn('3', r.stdout)
        self.assertIn('新增', r.stdout)

    def test_controller_order(self):
        r = self.run_menu('controller_init_menu() { echo STEP_INIT; }; '
                          'controller_master_menu() { echo STEP_START; }; '
                          'controller_issue_menu() { echo STEP_ENROLL; }; '
                          'systemctl() { return 3; }; controller_menu', '1\n2\n3\nq\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertLess(r.stdout.index('STEP_INIT'), r.stdout.index('STEP_START'))
        self.assertLess(r.stdout.index('STEP_START'), r.stdout.index('STEP_ENROLL'))

    def test_master_defaults_no_status_question(self):
        r = self.run_menu('controller_cli() { printf "ARG:%s\\n" "$@"; }; '
                          'systemctl() { echo SERVICE_STATUS; }; controller_master_menu', '\n\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('ARG:127.0.0.1:19090', r.stdout)
        self.assertIn('ARG:30', r.stdout)
        self.assertIn('SERVICE_STATUS', r.stdout)
        self.assertNotIn('是否立即查看', r.stdout)

    def test_readable_status_hides_tokens(self):
        self.data['enroll_tokens'] = {'edge-pending': 'SECRET_ENROLL'}
        self.data['nodes'] = {'edge-a': {'name': '测试线路', 'healthy': True,
            'last_seen': 1, 'priority': 100, 'quota_bytes': 1073741824, 'used_bytes': 1048576,
            'token_hash': 'SECRET_HASH'}}
        self.state.write_text(json.dumps(self.data))
        r = self.run_menu('controller_status_menu')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('测试线路', r.stdout)
        self.assertIn('心跳过期', r.stdout)
        self.assertNotIn('SECRET', r.stdout)
        self.assertIn('GiB', r.stdout)

    def test_quota_shorthand(self):
        r = self.run_menu('for q in 500 1.5TB 0 "2 gb"; do controller_parse_quota "$q"; done')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.splitlines(), ['536870912000', '1649267441664', '0', '2147483648'])
        for value in ['NaN', 'Infinity', '-1GB', '1XB', '1e999999TB']:
            r = self.run_menu('controller_parse_quota "' + value + '"')
            self.assertNotEqual(r.returncode, 0)
            self.assertNotIn('Traceback', r.stderr)


if __name__ == '__main__':
    unittest.main()
