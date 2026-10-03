#!/usr/bin/env python3
"""Offline privacy and malformed-input regression for edge access telemetry."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'emby-proxy').read_text().split('controller_cli() {', 1)[1].split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
ns = {'__name__': 'access_metrics_under_test'}
exec(compile(source, 'emby-proxy:access-metrics', 'exec'), ns)
STAMP = 1893456000


class AccessMetricsTests(unittest.TestCase):
    def collect(self, rows, **kwargs):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'access.log'
            path.write_text('\n'.join(json.dumps(row) for row in rows) + '\n')
            with patch.dict(ns, {'now': lambda: STAMP, 'time': SimpleNamespace(time=lambda: STAMP)}):
                return ns['collect_access_metrics']({'access_log': str(path)}, **kwargs)

    def test_non_object_nan_and_future_logs_do_not_crash_or_count(self):
        metric = self.collect([None, [], 2, 'bad', {'ts': float('nan')}, {'ts': float('inf')},
                               {'ts': STAMP + 301}, {'ts': STAMP, 'size': 100, 'path': '/Videos/1'}])
        self.assertEqual(metric['requests'], 1)
        self.assertEqual(metric['bytes'], 100)

    def test_paths_strip_queries_fragments_and_controls_clients_validate(self):
        metric = self.collect([{'ts': STAMP, 'path': '/Videos/1?api_key=secret#fragment',
                                'client': '192.0.2.4\nInjected', 'size': 50},
                               {'ts': STAMP, 'path': 'https://origin.example.com/x?token=secret',
                                'request': {'remote_ip': '192.0.2.5', 'uri': '/safe'}}])
        encoded = json.dumps(metric)
        self.assertNotIn('secret', encoded)
        self.assertNotIn('Injected', encoded)
        self.assertNotIn('origin.example.com', encoded)

    def test_controller_metrics_allow_only_public_shape(self):
        with patch.dict(ns, {'now': lambda: STAMP}):
            metric = ns['sanitize_metrics']({'generated_at': STAMP + 99999, 'requests': 2,
                'clients': [{'name': 'Bearer secret', 'bytes': 1}, {'name': '192.0.2.1', 'bytes': 1}],
                'devices': [{'name': 'user agent token=secret', 'bytes': 3}, {'name': 'Android', 'bytes': 2}],
                'paths': [{'name': '/x?api_key=secret#fragment', 'bytes': 9}]})
        self.assertNotIn('secret', json.dumps(metric))
        self.assertLessEqual(metric['generated_at'], STAMP + 300)
        self.assertEqual(metric['clients'][0]['name'], '192.0.2.1')
        self.assertEqual(metric['paths'][0]['name'], '/x')

    def test_heartbeat_invalid_metrics_clears_previous_snapshot(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'controller.json'
            path.write_text(json.dumps({'entry_id': 'domain-test.example.com', 'domain': 'test.example.com',
                'source': 'https://origin.example.com', 'engine': 'caddy', 'enroll_tokens': {},
                'telegram': {'enabled': True}, 'active_node': None, 'nodes': {'edge-a': {
                    'token_hash': ns['digest']('fixture-token'), 'healthy': True, 'last_seen': ns['now'](),
                    'priority': 1, 'quota_bytes': 0, 'used_bytes': 0, 'metrics': {'requests': 999}}}}))
            controller = ns['Controller'](path)
            code, _ = controller.heartbeat({'node_id': 'edge-a', 'used_bytes': 2, 'healthy': True,
                                            'metrics': []}, 'fixture-token')
            self.assertEqual(code, 200)
            self.assertNotIn('metrics', json.loads(path.read_text())['nodes']['edge-a'])

    def test_controller_does_not_treat_string_false_as_telemetry_consent(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'controller.json'
            path.write_text(json.dumps({'entry_id': 'domain-test.example.com', 'domain': 'test.example.com',
                'source': 'https://origin.example.com', 'engine': 'caddy', 'enroll_tokens': {},
                'telegram': {'enabled': 'false'}, 'active_node': None, 'nodes': {'edge-a': {
                    'token_hash': ns['digest']('fixture-token'), 'healthy': True, 'last_seen': ns['now'](),
                    'priority': 1, 'quota_bytes': 0, 'used_bytes': 0,
                    'metrics': {'requests': 99}}}}))
            controller = ns['Controller'](path)
            code, result = controller.heartbeat({'node_id': 'edge-a', 'used_bytes': 2, 'healthy': True,
                'metrics': {'requests': 3, 'bytes': 4}, 'address_family': 'ipv4'}, 'fixture-token')
            self.assertEqual(code, 200)
            self.assertFalse(result['telemetry_enabled'])
            saved = json.loads(path.read_text())['nodes']['edge-a']
            self.assertNotIn('metrics', saved)

    def heartbeat(self, controller, enabled=True, response=None):
        calls = []
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'node.json'
            state = {'controller': controller, 'node_id': 'edge-a', 'node_token': 'fixture-token',
                     'engine': 'caddy', 'telemetry_enabled': enabled}
            path.write_text(json.dumps(state))
            def post(url, payload, token):
                calls.append(payload)
                # A concurrent unrelated state update must survive the consent update.
                changed = json.loads(path.read_text()); changed['concurrent_field'] = 'kept'
                path.write_text(json.dumps(changed))
                return response or {'telemetry_enabled': enabled}
            with patch.dict(ns, {'collect_usage': lambda st: 7, 'local_entry_health': lambda st: True,
                                 'collect_access_metrics': lambda st: calls.append('read') or {'requests': 1},
                                 'post_json': post}), patch.object(ns['subprocess'], 'run', return_value=SimpleNamespace(returncode=0)), contextlib.redirect_stdout(io.StringIO()):
                ns['node_once'](SimpleNamespace(state=str(path)))
            return calls, json.loads(path.read_text())

    def test_remote_plaintext_does_not_collect_or_transmit_access(self):
        calls, _ = self.heartbeat('http://control.example.com:19090')
        self.assertNotIn('read', calls)
        self.assertNotIn('metrics', calls[0])

    def test_disabled_consent_is_not_truthy_string(self):
        calls, state = self.heartbeat('https://control.example.com', enabled=False,
                                      response={'telemetry_enabled': 'false'})
        self.assertNotIn('read', calls)
        self.assertFalse(state['telemetry_enabled'])

    def test_consent_update_preserves_other_state(self):
        calls, state = self.heartbeat('https://control.example.com', response={'telemetry_enabled': False})
        self.assertIn('read', calls)
        self.assertFalse(state['telemetry_enabled'])
        self.assertEqual(state['concurrent_field'], 'kept')

    def test_secure_and_loopback_controllers_can_report(self):
        for url in ('https://control.example.com', 'http://127.0.0.1:19090', 'http://[::1]:19090'):
            calls, _ = self.heartbeat(url)
            self.assertIn('read', calls)
            self.assertIn('metrics', calls[-1])


if __name__ == '__main__':
    unittest.main()
