#!/usr/bin/env python3
"""Fault/recovery and DNS read-back tests; no live DNS or systemd changes."""
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'emby-proxy').read_text().split('controller_cli() {', 1)[1]
source = source.split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
ns = {'__name__': 'controller_test'}
exec(compile(source, 'embedded-controller', 'exec'), ns)


class FailoverTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'state.json'
        self.state = dict(entry_id='domain-test.example.com', domain='test.example.com',
                          source='https://origin.example.com', engine='caddy',
                          active_node='a', nodes={
                              'a': dict(priority=100, quota_bytes=1000, used_bytes=0, healthy=True,
                                        last_seen=1000, token_hash=ns['digest']('fixture'), public_ip='192.0.2.1'),
                              'b': dict(priority=50, quota_bytes=0, used_bytes=0, healthy=True,
                                        last_seen=1000, public_ip='192.0.2.2')}, enroll_tokens={})
        self.path.write_text(json.dumps(self.state))
        self.clock = 1000
        clock = patch.dict(ns, now=lambda: self.clock)
        clock.start()
        self.addCleanup(clock.stop)
        net = patch.object(ns['urllib'].request, 'urlopen', side_effect=AssertionError('unexpected network'))
        net.start()
        self.addCleanup(net.stop)
        self.c = ns['Controller'](self.path)

    def beat(self, healthy, used=0):
        return self.c.heartbeat(dict(node_id='a', healthy=healthy, used_bytes=used), 'fixture')

    def test_three_failures_and_recovery_survive_controller_restart(self):
        for i in range(2):
            self.beat(False)
            self.assertEqual(self.c.select(), 'a')
        self.beat(False)
        self.assertEqual(self.c.select(), 'b')
        with patch.object(self.c, 'update_dns', return_value={'ok': True}):
            self.c.reconcile()
        self.c = ns['Controller'](self.path)
        for t in (1030, 1060, 1090):
            self.clock = t
            self.beat(True)
        self.assertEqual(self.c.select(), 'b', 'recovered node must respect switch cooldown')
        self.clock = 1180
        self.beat(True)
        self.c.state['nodes']['b']['last_seen'] = self.clock
        self.c.save()
        self.assertEqual(self.c.select(), 'a')

    def test_quota_and_stale_current_bypass_cooldown(self):
        self.c.state['last_switch_at'] = self.clock
        self.c.save()
        self.beat(True, used=1000)
        self.assertEqual(self.c.select(), 'b')
        self.c.state['nodes']['a']['used_bytes'] = 0
        self.c.state['nodes']['a']['last_seen'] = 909
        self.assertEqual(self.c.select(), 'b')

    def test_stale_recovery_needs_new_successes(self):
        self.clock = 1100
        self.beat(True)
        self.assertFalse(self.c.state['nodes']['a']['healthy'])
        for t in (1130, 1160):
            self.clock = t
            self.beat(True)
        self.assertTrue(self.c.state['nodes']['a']['healthy'])

    def test_same_priority_keeps_current_node(self):
        self.c.state['nodes']['b']['priority'] = 100
        self.assertEqual(self.c.select(), 'a')

    def test_new_node_not_selected_after_one_success(self):
        self.c.state['nodes']['a']['healthy'] = False
        self.c.save()
        self.beat(True)
        self.assertEqual(self.c.select(), 'b')

    def test_engine_conflict_does_not_consume_token_or_replace_node(self):
        self.c.state['enroll_tokens']['a'] = {'token': 'enroll-fixture', 'issued_at': self.clock}
        self.c.save()
        before = self.path.read_bytes()
        code, result = self.c.enroll(dict(entry_id=self.state['entry_id'], node_id='a',
            enroll_token='enroll-fixture', detected_engine='nginx'))
        self.assertEqual(code, 409)
        self.assertIn('engine', result['error'])
        self.assertEqual(before, self.path.read_bytes())

    def configure_dns(self):
        token = self.path.parent / 'token'
        token.write_text('fixture')
        self.c.state['dns'] = dict(provider='cloudflare', zone_id='zone', record_id='record', token_file=str(token))
        self.c.save()

    def response(self, body):
        return io.BytesIO(json.dumps(body).encode())

    def test_dns_put_requires_matching_readback(self):
        self.configure_dns()
        for ip, expected in [('192.0.2.1', True), ('192.0.2.99', False)]:
            replies = [self.response({'success': True}), self.response({'success': True, 'result': {
                'type': 'A', 'name': 'test.example.com', 'content': ip, 'proxied': False}})]
            with patch.object(ns['urllib'].request, 'urlopen', side_effect=replies) as net:
                result = self.c.update_dns('a')
            self.assertEqual(result['ok'], expected)
            self.assertEqual([c.args[0].get_method() for c in net.call_args_list], ['PUT', 'GET'])

    def test_readback_failure_preserves_active_and_retries(self):
        self.configure_dns()
        self.c.state['active_node'] = 'b'
        self.c.save()
        with patch.object(ns['urllib'].request, 'urlopen', side_effect=[self.response({'success': True}), OSError('timeout')]):
            self.assertEqual(self.c.reconcile()['active_node'], 'b')
        with patch.object(self.c, 'update_dns', return_value={'ok': True}) as dns:
            self.assertEqual(self.c.reconcile()['active_node'], 'a')
            dns.assert_called_once_with('a')

    def test_unconfigured_dns_does_not_claim_switch(self):
        self.c.state['active_node'] = 'b'
        self.c.save()
        self.assertEqual(self.c.reconcile()['active_node'], 'b')

    def test_uncertain_dns_write_reconciles_even_if_candidate_returns_to_previous(self):
        self.configure_dns()
        self.c.state.update(active_node='b', confirmed_dns_ip='192.0.2.2')
        self.c.save()
        # PUT may have succeeded; a failed read-back cannot prove DNS still points to b.
        with patch.object(self.c, 'update_dns', return_value={'ok': False}):
            self.c.reconcile()
        self.c.state['nodes']['a']['healthy'] = False
        self.c.save()
        with patch.object(self.c, 'update_dns', return_value={'ok': True}) as dns:
            self.c.reconcile()
            dns.assert_called_once_with('b')

    def test_same_node_ip_change_is_reconciled(self):
        self.configure_dns()
        self.c.state['confirmed_dns_ip'] = '192.0.2.99'
        self.c.save()
        with patch.object(self.c, 'update_dns', return_value={'ok': True}) as dns:
            self.c.reconcile()
            dns.assert_called_once_with('a')
        with patch.object(self.c, 'update_dns') as dns:
            self.c.reconcile()
            dns.assert_not_called()

    def test_empty_pool_is_explicit(self):
        for node in self.c.state['nodes'].values():
            node['healthy'] = False
        self.c.save()
        self.assertEqual(self.c.reconcile()['reason'], 'no_eligible_nodes')

    def test_detect_engine_never_changes_services(self):
        def run(cmd, **kwargs):
            self.assertEqual(cmd[:3], ['systemctl', 'is-active', '--quiet'])
            return SimpleNamespace(returncode=0 if cmd[-1] == 'nginx' else 3)
        with patch.object(ns['shutil'], 'which', return_value='/fixture/bin'), \
             patch.object(ns['subprocess'], 'run', side_effect=run):
            self.assertEqual(ns['detect_edge_engine'](), 'nginx')
        with patch.object(ns['shutil'], 'which', return_value=None), \
             patch.object(ns['subprocess'], 'run') as run:
            self.assertEqual(ns['detect_edge_engine'](), '')
            run.assert_not_called()
        with patch.object(ns['shutil'], 'which', return_value='/fixture/bin'), \
             patch.object(ns['subprocess'], 'run', return_value=SimpleNamespace(returncode=0)):
            with self.assertRaises(RuntimeError):
                ns['detect_edge_engine']()

    def test_suspect_standby_cannot_be_promoted(self):
        self.c.state['active_node'] = 'b'
        self.c.state['nodes']['a']['status'] = 'suspect'
        self.assertEqual(self.c.select(), 'b')

    def test_dns_rejects_wrong_record_and_bad_response(self):
        self.configure_dns()
        record = dict(type='A', name='test.example.com', content='192.0.2.1', proxied=False)
        for key, value in [('type', 'AAAA'), ('name', 'other.example.com'), ('proxied', True)]:
            with self.subTest(key=key), patch.object(ns['urllib'].request, 'urlopen', side_effect=[
                self.response({'success': True}),
                self.response({'success': True, 'result': dict(record, **{key: value})})]):
                self.assertFalse(self.c.update_dns('a')['ok'])
        with patch.object(ns['urllib'].request, 'urlopen', return_value=io.BytesIO(b'not json')):
            self.assertFalse(self.c.update_dns('a')['ok'])

    def test_node_install_failure_preserves_existing_local_state(self):
        # Redirect ONLY the node state path; an unexpected install/write fails the test.
        node_file = self.path.parent / 'existing-node.json'
        node_file.write_text(json.dumps(dict(node_id='a', controller='https://control.example.com')))
        before = node_file.read_bytes()
        def local_path(value):
            self.assertEqual(value, '/etc/emby-proxy/multiline-node.json')
            return node_file
        args = SimpleNamespace(controller_url='https://control.example.com', public_ip='',
            node_id='a', entry_id='domain-test.example.com', name='fixture', priority=100,
            quota_bytes=0, enroll_token='fixture')
        for result in [RuntimeError('registration rejected'),
                       {'engine': 'caddy', 'domain': 'test.example.com', 'node_token': 'fixture'}]:
            with self.subTest(result=type(result).__name__), \
                 patch.object(ns['os'], 'geteuid', return_value=0), \
                 patch.dict(ns, Path=local_path, resolve_edge_ipv4=lambda value: '192.0.2.1',
                            detect_edge_engine=lambda: 'nginx'), \
                 patch.dict(ns, post_json=Mock(side_effect=[result, {}])), \
                 patch.object(ns['subprocess'], 'run', side_effect=AssertionError('unexpected system change')):
                with self.assertRaises(RuntimeError):
                    ns['node_install'](args)
                self.assertEqual(node_file.read_bytes(), before)

    def test_unstable_recovery_resets_success_window(self):
        self.c.state['nodes']['a']['healthy'] = False
        self.c.save()
        self.beat(True)
        self.clock = 1030
        self.beat(False)
        for t in (1060, 1090):
            self.clock = t
            self.beat(True)
            self.assertFalse(self.c.state['nodes']['a']['healthy'])
        self.clock = 1120
        self.beat(True)
        self.assertTrue(self.c.state['nodes']['a']['healthy'])

    def test_generated_bootstrap_stops_after_download_failure(self):
        args = SimpleNamespace(state=str(self.path), controller_url='https://control.example.com',
            node_id='new', public_ip='', name='fixture', priority=100, quota_bytes=0)
        output = io.StringIO()
        with redirect_stdout(output):
            ns['issue'](args)
        command = output.getvalue().splitlines()[0]
        bin_dir = self.path.parent / 'bin'
        bin_dir.mkdir()
        log = self.path.parent / 'commands.log'
        scripts = {
            'sudo': '#!/bin/sh\nprintf "%s\\n" "$*" >> "$COMMAND_LOG"\nexec "$@"\n',
            'ep': '#!/bin/sh\nexit 0\n',
            'curl': '#!/bin/sh\nprintf "exit 0\\n" > "$4"\nexit 22\n',
        }
        for name, content in scripts.items():
            path = bin_dir / name
            path.write_text(content)
            path.chmod(0o755)
        result = ns['subprocess'].run(['bash', '-c', command], capture_output=True, text=True,
            env=dict(os.environ, PATH=str(bin_dir)+os.pathsep+os.environ['PATH'], COMMAND_LOG=str(log)), timeout=5)
        self.assertNotEqual(result.returncode, 0)
        commands = log.read_text()
        self.assertNotIn('--enroll-token', commands)
        self.assertNotIn('--manager-only', commands)


if __name__ == '__main__':
    unittest.main()
