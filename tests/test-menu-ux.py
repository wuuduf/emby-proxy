#!/usr/bin/env python3
"""真实 Bash 菜单输入回归；替身仅隔离网络、systemd 和配置写入。"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
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
                          'bad domain\nTEST.EXAMPLE.COM\norigin.example.com:8443\n\nn\n\n')
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
                          'test.example.com\norigin.example.com\n\n\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('自动沿用本地 600 权限文件', r.stdout)
        self.assertNotIn('API Token（输入隐藏', r.stdout)
        self.assertIn('ARG:--token-file', r.stdout)
        self.assertEqual((self.home / 'cf.token').stat().st_mode & 0o777, 0o600)

    def test_init_persists_dedicated_controller_domain(self):
        self.state.unlink()
        r = self.run_menu('controller_cli() { printf "ARG:%s\\n" "$@"; }; controller_init_menu',
                          'test.example.com\norigin.example.com\ncontrol.example.com\nn\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('ARG:--control-domain\nARG:control.example.com\n', r.stdout)
        self.assertIn('主控域名：control.example.com', r.stdout)

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

    def test_issue_uses_saved_controller_domain_when_url_missing(self):
        self.data['control_domain'] = 'control.example.com'
        self.state.write_text(json.dumps(self.data))
        r = self.run_menu('curl() { [[ "$*" == *"http://control.example.com:19090/status"* ]] || return 99; '
                          "printf '{\"entry_id\":\"domain-test.example.com\"}'; }; "
                          'controller_cli() { printf "ARG:%s\\n" "$@"; }; controller_issue_menu', '\n\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('ARG:http://control.example.com:19090\n', r.stdout)

    def test_issue_advanced_quota_and_ip_retry(self):
        r = self.run_menu("curl() { printf '{\"entry_id\":\"domain-test.example.com\"}'; }; "
                          'controller_cli() { printf "ARG:%s\\n" "$@"; }; controller_issue_menu',
                          'https://control.example.com\ny\n香港线路\n50\nnope\n5\ninvalid\n1.5\n999.2.3.4\n192.0.2.10\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        for arg in ['香港线路', '50', '1649267441664', '192.0.2.10']:
            self.assertIn('ARG:' + arg + '\n', r.stdout)

    def test_quota_unit_then_number(self):
        for choice, unit, amount, expected in [
            ('1', 'B', '500', 500), ('2', 'KB', '2', 2048),
            ('3', 'MB', '2', 2097152), ('4', 'GB', '500', 536870912000),
            ('5', 'TB', '1.5', 1649267441664),
        ]:
            with self.subTest(unit=unit):
                r = self.run_menu('controller_read_quota result; controller_parse_quota "$result"',
                                  f'{choice}\n{amount}\n')
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn(f'{amount} {unit}', r.stdout)
                self.assertTrue(r.stdout.rstrip().endswith(str(expected)), r.stdout)

    def test_quota_unlimited_skips_quantity(self):
        for inputs in ['0\n', '\n']:
            r = self.run_menu('controller_read_quota result; echo "RESULT:$result"', inputs)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('RESULT:0', r.stdout)
            self.assertNotIn('请输入配额数量', r.stdout)

    def test_quota_zero_quantity_is_unlimited(self):
        r = self.run_menu('controller_read_quota result; echo "RESULT:$result"', '4\n0.0\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('RESULT:0', r.stdout)
        self.assertIn('最终配额：不限额', r.stdout)

    def test_issue_advanced_unlimited_still_reads_ip(self):
        r = self.run_menu("curl() { printf '{\"entry_id\":\"domain-test.example.com\"}'; }; "
                          'controller_cli() { printf "ARG:%s\\n" "$@"; }; controller_issue_menu',
                          'https://control.example.com\ny\n线路\n100\n0\n192.0.2.10\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('ARG:--quota-bytes\nARG:0\n', r.stdout)
        self.assertIn('ARG:--public-ip\nARG:192.0.2.10\n', r.stdout)

    def test_quota_invalid_quantity_retries(self):
        r = self.run_menu('controller_read_quota result; echo "RESULT:$result"',
                          '1\n\n-1\nNaN\n1GB\n0.1\n9223372036854775808\n2\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('RESULT:2B', r.stdout)

    def test_quota_cancel_does_not_issue_token(self):
        for quota_input in ['q\n', '4\nq\n', '4\n', '']:
            r = self.run_menu("curl() { printf '{\"entry_id\":\"domain-test.example.com\"}'; }; "
                              'controller_cli() { echo SHOULD_NOT_ISSUE; }; controller_issue_menu',
                              'https://control.example.com\ny\n线路\n100\n' + quota_input)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertNotIn('SHOULD_NOT_ISSUE', r.stdout)

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

    def test_controller_status_explains_recovery_and_unconfirmed_dns(self):
        self.data.update(last_reconcile_reason='dns_unconfirmed', active_node='edge-old')
        self.data['nodes'] = {
            'edge-new': dict(healthy=False, status='recovering', success_streak=2, last_seen=int(time.time())),
            'edge-old': dict(healthy=True, status='suspect', failure_streak=1, last_seen=int(time.time()))}
        self.state.write_text(json.dumps(self.data))
        r = self.run_menu('controller_status_menu')
        self.assertEqual(r.returncode, 0, r.stderr)
        for text in ('恢复观察中', '故障观察中', '尚未回读确认', 'DNS 未确认', '180 秒', '90 秒'):
            self.assertIn(text, r.stdout)

    def test_reconcile_error_returns_to_controller_menu(self):
        r = self.run_menu('systemctl() { return 3; }; controller_cli() { return 1; }; '
                          'controller_menu; echo RETURNED', '5\n0\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertGreaterEqual(r.stdout.count('多线路控制器'), 2)
        self.assertIn('RETURNED', r.stdout)

    def test_quota_shorthand(self):
        r = self.run_menu('for q in 500 1.5TB 0 "2 gb"; do controller_parse_quota "$q"; done')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.splitlines(), ['536870912000', '1649267441664', '0', '2147483648'])
        for value in ['NaN', 'Infinity', '-1GB', '1XB', '1e999999TB']:
            r = self.run_menu('controller_parse_quota "' + value + '"')
            self.assertNotEqual(r.returncode, 0)
            self.assertNotIn('Traceback', r.stderr)

    def test_certificate_setup_cancel_does_not_touch_system(self):
        r = self.run_menu('controller_cli() { echo SHOULD_NOT_RUN; }; controller_cert_menu', 'control.example.com\nn\n')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertNotIn('SHOULD_NOT_RUN',r.stdout)

    def test_certificate_setup_menu_calls_atomic_setup(self):
        self.data['dns'] = {'provider': 'cloudflare'}
        self.state.write_text(json.dumps(self.data))
        r = self.run_menu('controller_cli() { printf "ARG:%s\\n" "$@"; }; controller_cert_menu', 'control.example.com\ny\n')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn('ARG:cert-setup',r.stdout)
        self.assertIn('ARG:--install-deps',r.stdout)
        self.assertIn('19090',r.stderr)

    def test_dns_provider_uses_caddy_https_proxy_setup(self):
        self.data['dns'] = {'provider': 'dnspod'}
        self.state.write_text(json.dumps(self.data))
        r = self.run_menu('controller_cli() { printf "ARG:%s\\n" "$@"; }; controller_cert_menu', 'control.example.com\ny\n')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn('ARG:https-proxy-setup',r.stdout)
        self.assertNotIn('ARG:cert-setup',r.stdout)
        self.assertIn('80/443',r.stdout)


if __name__ == '__main__':
    unittest.main()
