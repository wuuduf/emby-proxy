#!/usr/bin/env python3
"""Registration CLI/HTTP contract; isolated state and no live VPS/DNS changes."""
import io
import json
import tempfile
import threading
import urllib.request
import urllib.error
import unittest
from contextlib import redirect_stdout
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'emby-proxy').read_text().split('controller_cli() {', 1)[1]
source = source.split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
ns = {'__name__': 'registration_test'}
exec(compile(source, 'emby-proxy:registration', 'exec'), ns)


class RegistrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        manager = Path(self.tmp.name) / 'emby-proxy'
        manager.write_text('#!/bin/sh\nexit 0\n')
        manager.chmod(0o700)
        manager_env = patch.dict(ns['os'].environ, {'EMBY_PROXY_MANAGER_BIN': str(manager)})
        manager_env.start(); self.addCleanup(manager_env.stop)
        self.path = Path(self.tmp.name) / 'controller.json'
        self.clock = 1000
        clock = patch.dict(ns, now=lambda: self.clock)
        clock.start(); self.addCleanup(clock.stop)
        self.state = dict(entry_id='domain-test.example.com', domain='test.example.com',
                          source='https://origin.example.com', engine='caddy',
                          address_family='ipv4', nodes={}, enroll_tokens={})
        ns['atomic_write'](self.path, self.state)

    def issue(self, node_id='edge-a'):
        args = SimpleNamespace(state=str(self.path), controller_url='https://control.example.com',
                               node_id=node_id, name='线路 A', priority=100,
                               quota_bytes=1024, public_ip='', address_family='ipv4')
        output = io.StringIO()
        with redirect_stdout(output): ns['issue'](args)
        return json.loads(self.path.read_text())['enroll_tokens'][node_id], output.getvalue()

    def test_ticket_lifecycle_is_visible_without_disclosing_credentials(self):
        ticket, command = self.issue()
        self.assertEqual(ticket['status'], 'pending')
        self.assertEqual(ticket['expires_at'], 1900)
        self.assertEqual(ticket['priority'], 100)
        self.assertEqual(ticket['quota_bytes'], 1024)
        self.assertIn('--ticket', command)
        status = ns['Controller'](self.path).private_status()
        self.assertEqual(status['registration_tasks']['edge-a']['status'], 'pending')
        self.assertNotIn(ticket['token'], json.dumps(status))
        with self.assertRaisesRegex(RuntimeError, '票据'):
            self.issue()
        self.assertEqual(json.loads(self.path.read_text())['enroll_tokens']['edge-a']['token'], ticket['token'])

    def test_new_tickets_require_https_and_auto_ids_skip_historical_tasks(self):
        args = SimpleNamespace(state=str(self.path), controller_url='http://control.example.com',
            node_id='', name='线路 A', priority=100, quota_bytes=1024, public_ip='', address_family='ipv4')
        before = self.path.read_bytes()
        with self.assertRaisesRegex(RuntimeError, 'HTTPS'): ns['issue'](args)
        self.assertEqual(self.path.read_bytes(), before)
        self.issue('edge-node')
        with redirect_stdout(io.StringIO()): ns['ticket_revoke'](SimpleNamespace(state=str(self.path),node_id='edge-node'))
        args.controller_url='https://control.example.com'
        with redirect_stdout(io.StringIO()): ns['issue'](args)
        self.assertIn('edge-node-2', json.loads(self.path.read_text())['enroll_tokens'])

    def test_prepare_is_read_only_and_commit_uses_bound_policy(self):
        ticket, _ = self.issue()
        controller = ns['Controller'](self.path)
        body = {'ticket': ticket['token']}
        before = self.path.read_bytes()
        code, plan = controller.prepare(body, secure=True)
        self.assertEqual(code, 200)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(plan['priority'], 100)
        self.assertNotIn('node_token', plan)
        self.assertEqual(controller.prepare(body, secure=False)[0], 403)
        commit = dict(body, revision=plan['revision'], public_ip='2606:4700:4700::1111',
                      address_family='ipv4', detected_engine='caddy', priority=999999,
                      quota_bytes=0, node_token='installation-fixture-token-with-32-characters')
        self.assertEqual(controller.commit(commit, secure=True)[0], 400)
        self.assertIn('edge-a', json.loads(self.path.read_text())['enroll_tokens'])
        # Public TEST-NET is intentionally allowed at this isolated validation seam.
        with patch.object(ns['ipaddress'].IPv4Address, 'is_global', new_callable=lambda: property(lambda _: True)):
            commit['public_ip'] = '192.0.2.10'
            code, result = controller.commit(commit, secure=True)
        self.assertEqual(code, 200, result)
        self.assertEqual(result['node_token'], commit['node_token'])
        node = controller.private_status()['nodes']['edge-a']
        self.assertEqual((node['priority'], node['quota_bytes']), (100, 1024))
        self.assertEqual(node['registration_status'], 'provisioning')
        self.assertEqual(controller.commit(commit, secure=True)[0], 403)
        self.assertEqual(controller.prepare(body, secure=True)[0], 403)

    def test_prepare_and_commit_reject_expiry_contract_change_and_engine_conflict(self):
        ticket, _ = self.issue()
        controller = ns['Controller'](self.path)
        body = {'ticket': ticket['token']}
        _, plan = controller.prepare(body, secure=True)
        commit = dict(body, revision=plan['revision'], address_family='ipv4',
                      public_ip='', detected_engine='nginx', node_token='a'*43)
        self.assertEqual(controller.commit(commit, secure=True)[0], 409)
        self.assertIn('edge-a', json.loads(self.path.read_text())['enroll_tokens'])
        state = json.loads(self.path.read_text()); state['source'] = 'https://other.example.com'
        ns['atomic_write'](self.path, state)
        self.assertEqual(controller.prepare(body, secure=True)[0], 409)
        commit['detected_engine'] = 'caddy'
        self.assertEqual(controller.commit(commit, secure=True)[0], 409)
        self.clock = 1900
        self.assertEqual(controller.prepare(body, secure=True)[0], 403)
        self.assertEqual(controller.private_status()['registration_tasks']['edge-a']['status'], 'expired')

    def test_show_revoke_and_reissue_are_explicit_and_rotate_old_credential(self):
        ticket, _ = self.issue()
        args = SimpleNamespace(state=str(self.path), node_id='edge-a')
        output = io.StringIO()
        with redirect_stdout(output): ns['ticket_show'](args)
        self.assertIn(ticket['token'], output.getvalue())
        before = self.path.read_bytes()
        self.clock = 1900
        with self.assertRaisesRegex(RuntimeError, '过期'): ns['ticket_show'](args)
        self.assertEqual(self.path.read_bytes(), before)
        with redirect_stdout(io.StringIO()): ns['ticket_reissue'](args)
        current = json.loads(self.path.read_text())['enroll_tokens']['edge-a']
        self.assertNotEqual(current['token'], ticket['token'])
        self.assertEqual(current['generation'], 2)
        self.assertEqual(current['quota_bytes'], 1024)
        controller = ns['Controller'](self.path)
        self.assertEqual(controller.prepare({'ticket':ticket['token']}, secure=True)[0], 403)
        with redirect_stdout(io.StringIO()): ns['ticket_revoke'](args)
        self.assertEqual(controller.prepare({'ticket':current['token']}, secure=True)[0], 403)
        self.assertEqual(controller.private_status()['registration_tasks']['edge-a']['status'], 'revoked')
        with redirect_stdout(io.StringIO()): ns['ticket_reissue'](args)
        self.assertEqual(json.loads(self.path.read_text())['enroll_tokens']['edge-a']['generation'], 3)

    def test_reissue_uses_current_https_controller_and_does_not_copy_cleanup_secrets(self):
        self.issue()
        args=SimpleNamespace(state=str(self.path),node_id='edge-a')
        with redirect_stdout(io.StringIO()): ns['ticket_revoke'](args)
        state=json.loads(self.path.read_text())
        state['controller_url']='https://new-control.example.com'
        state['registration_tasks']['edge-a']['cleanup_token_hash']='PRIVATE_HASH'
        ns['atomic_write'](self.path,state)
        output=io.StringIO()
        with redirect_stdout(output): ns['ticket_reissue'](args)
        ticket=json.loads(self.path.read_text())['enroll_tokens']['edge-a']
        self.assertIn('--controller-url https://new-control.example.com',output.getvalue())
        self.assertNotIn('cleanup_token_hash',ticket)
        state=json.loads(self.path.read_text()); state['controller_url']='http://control.example.com'
        ns['atomic_write'](self.path,state); before=self.path.read_bytes()
        with self.assertRaisesRegex(RuntimeError,'HTTPS'): ns['ticket_reissue'](args)
        self.assertEqual(self.path.read_bytes(),before)

    def test_provisioning_cannot_be_selected_and_failed_registration_can_be_cleaned(self):
        ticket, _ = self.issue()
        controller = ns['Controller'](self.path)
        _, plan = controller.prepare({'ticket':ticket['token']}, secure=True)
        body = dict(ticket=ticket['token'], revision=plan['revision'], public_ip='192.0.2.10',
                    address_family='ipv4', detected_engine='caddy', node_token='a'*43)
        with patch.object(ns['ipaddress'].IPv4Address, 'is_global', new_callable=lambda: property(lambda _: True)):
            self.assertEqual(controller.commit(body, secure=True)[0], 200)
        args = SimpleNamespace(state=str(self.path), node_id='edge-a')
        for op in ('ticket_reissue', 'ticket_revoke', 'registration_cleanup'):
            with self.assertRaises(RuntimeError): ns[op](args)
        for self.clock in (1000,1030,1060):
            controller.heartbeat(dict(node_id='edge-a',healthy=True,used_bytes=0), 'a'*43)
        self.assertIsNone(controller.private_status()['selected_node'])
        self.assertEqual(controller.registration_result({'node_id':'edge-a','success':False}, 'wrong')[0], 403)
        self.assertEqual(controller.registration_result({'node_id':'edge-a','success':False}, 'a'*43)[0], 200)
        self.assertEqual(controller.private_status()['registration_tasks']['edge-a']['status'], 'needs_cleanup')
        with redirect_stdout(io.StringIO()): ns['registration_cleanup'](args)
        self.assertNotIn('edge-a', controller.private_status()['nodes'])
        # Controller-side manual cleanup must not strand an edge recovery
        # receipt when its authenticated cleanup acknowledgement is retried.
        self.assertEqual(controller.registration_result({'node_id':'edge-a','success':False}, 'a'*43)[0], 200)
        self.assertEqual(controller.revoke({'node_id':'edge-a'}, 'a'*43)[0], 200)
        self.assertEqual(controller.revoke({'node_id':'edge-a'}, 'wrong')[0], 403)
        with redirect_stdout(io.StringIO()): ns['ticket_reissue'](args)

    def test_installed_registration_is_not_a_cleanup_candidate(self):
        ticket, _ = self.issue()
        controller = ns['Controller'](self.path)
        _, plan = controller.prepare({'ticket':ticket['token']}, secure=True)
        body = dict(ticket=ticket['token'],revision=plan['revision'],public_ip='192.0.2.10',
                    address_family='ipv4',detected_engine='caddy',node_token='a'*43)
        with patch.object(ns['ipaddress'].IPv4Address, 'is_global', new_callable=lambda: property(lambda _: True)):
            controller.commit(body, secure=True)
        controller.registration_result({'node_id':'edge-a','success':True}, 'a'*43)
        for self.clock in (1000,1030,1060):
            controller.heartbeat(dict(node_id='edge-a',healthy=True,used_bytes=0), 'a'*43)
        status=controller.private_status()
        self.assertEqual(status['registration_tasks']['edge-a']['status'], 'ready')
        self.assertEqual(status['selected_node'], 'edge-a')
        with self.assertRaises(RuntimeError):
            ns['registration_cleanup'](SimpleNamespace(state=str(self.path),node_id='edge-a'))

    def test_real_http_proxy_routes_prepare_commit_and_failure_without_public_delete(self):
        ticket, _ = self.issue()
        server = ns['Server'](('127.0.0.1',0), ns['Controller'](self.path))
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        self.addCleanup(lambda: (server.shutdown(),server.server_close(),thread.join(timeout=3)))
        def request(route, payload, auth='', https=True):
            headers={'Content-Type':'application/json'}
            if https: headers['X-Forwarded-Proto']='https'  # Simulates the trusted local Caddy hop.
            if auth: headers['Authorization']='Bearer '+auth
            req=urllib.request.Request('http://127.0.0.1:%s%s' % (server.server_port,route),
                                       data=json.dumps(payload).encode(), headers=headers)
            try:
                with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=3) as response:
                    return response.status,json.load(response)
            except urllib.error.HTTPError as error:
                with error: return error.code,json.load(error)
        code,plan=request('/enroll/prepare', {'ticket':ticket['token']})
        self.assertEqual(code,200,plan)
        self.assertEqual(request('/enroll/prepare', {'ticket':ticket['token']}, https=False)[0],403)
        code,_=request('/enroll',dict(entry_id=self.state['entry_id'],node_id='edge-a',enroll_token=ticket['token']))
        self.assertEqual(code,409,'legacy route must not bypass v2 preflight')
        with patch.object(ns['ipaddress'].IPv4Address, 'is_global', new_callable=lambda: property(lambda _: True)):
            code,result=request('/enroll/commit',dict(ticket=ticket['token'],revision=plan['revision'],
                          public_ip='192.0.2.10',address_family='ipv4',detected_engine='caddy',node_token='a'*43))
        self.assertEqual(code,200,result)
        self.assertEqual(request('/enroll/result', {'node_id':'edge-a','success':False}, auth='a'*43)[0],200)
        self.assertEqual(request('/reconcile', {})[0],404)
        self.assertEqual(request('/revoke', {'node_id':'edge-a'}, auth='wrong')[0],403)
        self.assertEqual(request('/revoke', {'node_id':'edge-a'}, auth='a'*43)[0],200)
        self.assertEqual(json.loads(self.path.read_text())['registration_tasks']['edge-a']['status'],'failed_cleaned')
        self.assertEqual(request('/revoke', {'node_id':'edge-a'}, auth='a'*43)[0],200)
        self.assertEqual(request('/enroll/prepare', {'ticket':'非ASCII'*10})[0],403)
        race,_=self.issue('edge-race')
        _,plan=request('/enroll/prepare',{'ticket':race['token']})
        body=dict(ticket=race['token'],revision=plan['revision'],public_ip='192.0.2.20',
                  address_family='ipv4',detected_engine='caddy')
        with patch.object(ns['ipaddress'].IPv4Address,'is_global',new_callable=lambda: property(lambda _: True)):
            with ThreadPoolExecutor(max_workers=2) as pool:
                replies=list(pool.map(lambda token:request('/enroll/commit',dict(body,node_token=token)),('b'*43,'c'*43)))
        self.assertEqual(sorted(code for code,_ in replies),[200,403])
        self.assertEqual(list(ns['Controller'](self.path).private_status()['nodes']),['edge-race'])


class EdgeInstallTests(unittest.TestCase):
    """Real installer/controller state flow with only OS and HTTP adapters isolated."""
    def setUp(self):
        RegistrationTests.setUp(self)
        self.home=Path(self.tmp.name)/'edge'; self.home.mkdir()
        self.real_path=Path
        def edge_path(value):
            text=str(value)
            return self.real_path(self.home/text.lstrip('/')) if text.startswith(('/etc/','/var/lib/','/var/log/','/usr/')) else self.real_path(value)
        self.edge_path=edge_path
        backend=edge_path('/usr/local/lib/emby-proxy/setup-emby-proxy.sh')
        backend.parent.mkdir(parents=True); backend.write_text('fixture backend'); backend.chmod(0o755)
        self.commands=[]; self.preflight_fail=False; self.install_fail=False; self.lost_commit=False; self.revoke_fail=False
        self.engine='caddy'
        self.foreign_loaded_unit=False
        self.commit_not_sent=False; self.systemd_fail=False; self.backend_help_fail=False; self.lost_result=False; self.lost_revoke=False; self.expire_on_commit=False
        self.controller=ns['Controller'](self.path)
        def post(url,payload,token=''):
            if url.endswith('/enroll/prepare'): code,result=self.controller.prepare(payload,secure=True)
            elif url.endswith('/enroll/commit'):
                if self.commit_not_sent: raise RuntimeError('request not sent')
                if self.expire_on_commit: self.clock=1900
                code,result=self.controller.commit(payload,secure=True)
                if self.lost_commit: raise RuntimeError('response lost')
            elif url.endswith('/enroll/result'):
                code,result=self.controller.registration_result(payload,token)
                if self.lost_result and payload.get('success'): raise RuntimeError('completion response lost')
            elif url.endswith('/heartbeat'): code,result=self.controller.heartbeat(payload,token)
            elif url.endswith('/revoke'):
                if self.revoke_fail: raise RuntimeError('controller unavailable')
                code,result=self.controller.revoke(payload,token)
                if self.lost_revoke: raise RuntimeError('revoke response lost')
            else: raise AssertionError(url)
            if code != 200: raise ns['ControllerHTTPError'](code)
            return result
        def run(cmd,**kwargs):
            self.commands.append(cmd)
            if cmd[:2] == ['systemctl','show']:
                return SimpleNamespace(returncode=0,stdout='loaded' if self.foreign_loaded_unit else 'not-found',stderr='')
            if '--help' in cmd: return SimpleNamespace(returncode=1 if self.backend_help_fail else 0,stdout='' if self.backend_help_fail else '--node-preflight',stderr='backend error' if self.backend_help_fail else '')
            if '--node-preflight' in cmd:
                return SimpleNamespace(returncode=1 if self.preflight_fail else 0,stdout='',stderr='')
            if str(backend) in cmd:
                if self.install_fail: return SimpleNamespace(returncode=1)
                site=edge_path('/etc/emby-proxy/sites.d/domain-test.example.com.json')
                site.parent.mkdir(parents=True,exist_ok=True)
                site.write_text(json.dumps(dict(id='domain-test.example.com',domain='test.example.com',engine=self.engine,
                    managed_kind='standalone',config_file='/etc/caddy/Caddyfile' if self.engine == 'caddy' else '/etc/nginx/conf.d/emby-proxy-test.example.com.conf',listen_port=443,
                    routes=[dict(path='/',upstream='https://origin.example.com')],
                    registration_transaction=kwargs['env']['EMBY_PROXY_REGISTRATION_TRANSACTION'])))
            if 'delete' in cmd:
                edge_path('/etc/emby-proxy/sites.d/domain-test.example.com.json').unlink()
            if self.systemd_fail and cmd[:2] == ['systemctl','enable']:
                raise ns['subprocess'].CalledProcessError(1,cmd)
            return SimpleNamespace(returncode=0,stdout='',stderr='')
        patches=[patch.dict(ns,Path=edge_path,post_json=post),
                 patch.object(ns['os'],'geteuid',return_value=0),
                 patch.object(ns['shutil'],'which',side_effect=lambda name:None if name in ('caddy','nginx') and name != self.engine else '/fixture/'+name),
                 patch.object(ns['subprocess'],'run',side_effect=run),
                 patch.object(ns['ipaddress'].IPv4Address,'is_global',new_callable=lambda: property(lambda _: True))]
        for p in patches: p.start(); self.addCleanup(p.stop)

    def args(self,ticket):
        return SimpleNamespace(ticket=ticket['token'],controller_url='https://control.example.com',public_ip='192.0.2.10')

    issue = RegistrationTests.issue

    def test_preflight_failure_leaves_ticket_unconsumed_and_creates_no_receipt(self):
        ticket,_=self.issue(); self.preflight_fail=True
        with self.assertRaisesRegex(RuntimeError,'预检'):
            ns['node_install'](self.args(ticket))
        self.assertIn('edge-a',json.loads(self.path.read_text())['enroll_tokens'])
        self.assertFalse(self.edge_path('/etc/emby-proxy/node-install-recovery.json').exists())
        self.assertFalse(any('enable' in command for command in self.commands))

    def test_backend_help_failure_is_a_recoverable_user_error(self):
        ticket,_=self.issue(); self.backend_help_fail=True
        with self.assertRaisesRegex(RuntimeError,'帮助检查失败') as caught:
            ns['node_install'](self.args(ticket))
        self.assertNotIn('Traceback',str(caught.exception))
        self.assertIn('edge-a',json.loads(self.path.read_text())['enroll_tokens'])
        self.assertFalse(self.edge_path('/etc/emby-proxy/node-install-recovery.json').exists())

    def test_old_controller_gives_an_upgrade_hint_before_any_local_apply(self):
        ticket,_=self.issue()
        with patch.dict(ns,post_json=lambda *args: (_ for _ in ()).throw(ns['ControllerHTTPError'](404))):
            with self.assertRaisesRegex(RuntimeError,'升级主控.*重启'):
                ns['node_install'](self.args(ticket))
        self.assertFalse(self.edge_path('/etc/emby-proxy/node-install-recovery.json').exists())
        self.assertEqual(self.controller.private_status()['registration_tasks']['edge-a']['status'],'pending')

    def test_success_consumes_only_after_preflight_and_waits_for_health(self):
        ticket,_=self.issue()
        with redirect_stdout(io.StringIO()): ns['node_install'](self.args(ticket))
        status=self.controller.private_status()
        self.assertEqual(status['registration_tasks']['edge-a']['status'],'observing')
        self.assertIsNone(status['selected_node'])
        self.assertNotIn('edge-a',json.loads(self.path.read_text())['enroll_tokens'])
        self.assertFalse(self.edge_path('/etc/emby-proxy/node-install-recovery.json').exists())

    def test_lost_commit_response_is_recoverable_without_reusing_ticket(self):
        ticket,_=self.issue(); self.lost_commit=True
        with self.assertRaisesRegex(RuntimeError,'response lost'):
            ns['node_install'](self.args(ticket))
        self.assertNotIn('edge-a',self.controller.private_status()['nodes'])
        self.assertEqual(self.controller.private_status()['registration_tasks']['edge-a']['status'],'failed_cleaned')

    def test_commit_not_sent_can_cleanup_and_retry_the_same_unconsumed_ticket(self):
        ticket,_=self.issue(); self.commit_not_sent=True
        with self.assertRaisesRegex(RuntimeError,'request not sent'):
            ns['node_install'](self.args(ticket))
        self.assertEqual(self.controller.private_status()['registration_tasks']['edge-a']['status'],'pending')
        self.assertFalse(self.edge_path('/etc/emby-proxy/node-install-recovery.json').exists())
        self.commit_not_sent=False
        with redirect_stdout(io.StringIO()): ns['node_install'](self.args(ticket))
        self.assertEqual(self.controller.private_status()['registration_tasks']['edge-a']['status'],'observing')

    def test_failed_install_retains_cleanup_receipt_when_controller_unavailable(self):
        ticket,_=self.issue(); self.install_fail=True; self.revoke_fail=True
        with self.assertRaises(RuntimeError): ns['node_install'](self.args(ticket))
        receipt=self.edge_path('/etc/emby-proxy/node-install-recovery.json')
        self.assertTrue(receipt.exists())
        self.assertEqual(receipt.stat().st_mode & 0o777,0o600)
        self.assertEqual(self.controller.private_status()['registration_tasks']['edge-a']['status'],'needs_cleanup')
        self.assertIsNone(self.controller.private_status()['selected_node'])
        self.revoke_fail=False
        with redirect_stdout(io.StringIO()): ns['node_cleanup'](SimpleNamespace())
        self.assertFalse(receipt.exists())
        with redirect_stdout(io.StringIO()): ns['ticket_reissue'](SimpleNamespace(state=str(self.path),node_id='edge-a'))

    def test_systemd_failure_after_backend_apply_removes_only_new_installation(self):
        ticket,_=self.issue(); self.systemd_fail=True
        original=self.edge_path('/etc/systemd/system/other.service')
        original.parent.mkdir(parents=True,exist_ok=True); original.write_text('unrelated service')
        used=self.edge_path('/var/lib/emby-proxy/usage.offset')
        used.parent.mkdir(parents=True,exist_ok=True); used.write_text('existing usage cursor')
        with self.assertRaises(ns['subprocess'].CalledProcessError): ns['node_install'](self.args(ticket))
        for target in ('/etc/emby-proxy/multiline-node.json', '/etc/emby-proxy/node-install-recovery.json',
                       '/etc/emby-proxy/sites.d/domain-test.example.com.json',
                       '/etc/systemd/system/emby-proxy-node.service', '/etc/systemd/system/emby-proxy-node.timer',
                       '/var/lib/emby-proxy/used_bytes'):
            self.assertFalse(self.edge_path(target).exists(),target)
        self.assertEqual(original.read_text(),'unrelated service')
        self.assertEqual(used.read_text(),'existing usage cursor')
        self.assertEqual(self.controller.private_status()['registration_tasks']['edge-a']['status'],'failed_cleaned')

    def test_commit_rejected_after_preflight_expires_leaves_no_local_receipt(self):
        ticket,_=self.issue(); self.expire_on_commit=True
        with self.assertRaises(ns['ControllerHTTPError']): ns['node_install'](self.args(ticket))
        self.assertFalse(self.edge_path('/etc/emby-proxy/node-install-recovery.json').exists())
        self.assertEqual(self.controller.private_status()['registration_tasks']['edge-a']['status'],'expired')
        self.assertFalse(any('enable' in command for command in self.commands))

    def test_lost_completion_and_revoke_responses_remain_retryable(self):
        ticket,_=self.issue(); self.lost_result=True; self.lost_revoke=True
        with self.assertRaisesRegex(RuntimeError,'completion response lost'):
            ns['node_install'](self.args(ticket))
        receipt=self.edge_path('/etc/emby-proxy/node-install-recovery.json')
        self.assertTrue(receipt.exists())
        self.assertEqual(self.controller.private_status()['registration_tasks']['edge-a']['status'],'failed_cleaned')
        self.lost_revoke=False
        with redirect_stdout(io.StringIO()): ns['node_cleanup'](SimpleNamespace())
        self.assertFalse(receipt.exists())
        self.assertEqual(self.controller.revoke({'node_id':'edge-a'},'wrong')[0],403)

    def test_cleanup_refuses_changed_site_and_preserves_recovery_record(self):
        ticket,_=self.issue(); self.install_fail=True; self.revoke_fail=True
        with self.assertRaises(RuntimeError): ns['node_install'](self.args(ticket))
        site=self.edge_path('/etc/emby-proxy/sites.d/domain-test.example.com.json')
        site.parent.mkdir(parents=True,exist_ok=True)
        site.write_text(json.dumps({'domain':'test.example.com','registration_transaction':'b'*32}))
        before=site.read_bytes(); self.revoke_fail=False
        with self.assertRaisesRegex(RuntimeError,'已改变'): ns['node_cleanup'](SimpleNamespace())
        self.assertEqual(site.read_bytes(),before)
        self.assertTrue(self.edge_path('/etc/emby-proxy/node-install-recovery.json').exists())
        self.assertNotIn(['systemctl','disable','--now','other.service'],self.commands)

    def test_existing_local_node_is_not_overwritten_or_consumed(self):
        ticket,_=self.issue()
        existing=self.edge_path('/etc/emby-proxy/multiline-node.json')
        existing.parent.mkdir(parents=True,exist_ok=True); existing.write_text('{"node_id":"other"}')
        before=existing.read_bytes()
        with self.assertRaisesRegex(RuntimeError,'已有节点'): ns['node_install'](self.args(ticket))
        self.assertEqual(existing.read_bytes(),before)
        self.assertEqual(self.controller.private_status()['registration_tasks']['edge-a']['status'],'pending')

    def test_loaded_unit_outside_etc_is_rejected_without_consuming_ticket(self):
        ticket,_=self.issue(); self.foreign_loaded_unit=True
        with self.assertRaisesRegex(RuntimeError,'服务单元'):
            ns['node_install'](self.args(ticket))
        self.assertEqual(self.controller.private_status()['registration_tasks']['edge-a']['status'],'pending')
        self.assertFalse(self.edge_path('/etc/emby-proxy/node-install-recovery.json').exists())
        self.assertFalse(any('enable' in cmd for cmd in self.commands))

    def test_cleanup_refuses_a_same_named_foreign_unit(self):
        ticket,_=self.issue(); self.install_fail=True; self.revoke_fail=True
        with self.assertRaises(RuntimeError): ns['node_install'](self.args(ticket))
        unit=self.edge_path('/etc/systemd/system/emby-proxy-node.timer')
        unit.parent.mkdir(parents=True,exist_ok=True); unit.write_text('foreign unit, do not delete')
        self.revoke_fail=False
        with self.assertRaisesRegex(RuntimeError,'归属不匹配'): ns['node_cleanup'](SimpleNamespace())
        self.assertEqual(unit.read_text(),'foreign unit, do not delete')
        self.assertTrue(self.edge_path('/etc/emby-proxy/node-install-recovery.json').exists())

    def test_cleanup_without_receipt_keeps_a_working_node(self):
        ticket,_=self.issue()
        with redirect_stdout(io.StringIO()): ns['node_install'](self.args(ticket))
        node=self.edge_path('/etc/emby-proxy/multiline-node.json'); before=node.read_bytes()
        with redirect_stdout(io.StringIO()): ns['node_cleanup'](SimpleNamespace())
        self.assertEqual(node.read_bytes(),before)
        self.assertIn('edge-a',self.controller.private_status()['nodes'])

    def test_nginx_systemd_failure_uses_the_same_owned_cleanup_flow(self):
        self.engine='nginx'
        state=json.loads(self.path.read_text()); state['engine']='nginx'; ns['atomic_write'](self.path,state)
        ticket,_=self.issue(); self.systemd_fail=True
        with self.assertRaises(ns['subprocess'].CalledProcessError): ns['node_install'](self.args(ticket))
        self.assertFalse(self.edge_path('/etc/emby-proxy/sites.d/domain-test.example.com.json').exists())
        self.assertFalse(self.edge_path('/etc/emby-proxy/node-install-recovery.json').exists())
        self.assertNotIn('edge-a',self.controller.private_status()['nodes'])
        self.assertTrue(any('--node-preflight' in cmd and 'nginx' in cmd for cmd in self.commands))

    def test_ipv6_ticket_keeps_the_family_bound_through_install_and_health(self):
        state=json.loads(self.path.read_text()); state['address_family']='ipv6'; ns['atomic_write'](self.path,state)
        args=SimpleNamespace(state=str(self.path),controller_url='https://control.example.com',node_id='edge-v6',
            name='IPv6',priority=100,quota_bytes=0,public_ip='',address_family='ipv6')
        with redirect_stdout(io.StringIO()): ns['issue'](args)
        ticket=json.loads(self.path.read_text())['enroll_tokens']['edge-v6']
        install=SimpleNamespace(ticket=ticket['token'],controller_url='https://control.example.com',public_ip='2001:db8::20')
        with patch.object(ns['ipaddress'].IPv6Address,'is_global',new_callable=lambda: property(lambda _: True)):
            with redirect_stdout(io.StringIO()): ns['node_install'](install)
        node=self.controller.private_status()['nodes']['edge-v6']
        self.assertEqual(node['address_family'],'ipv6')
        self.assertEqual(node['public_ip'],'2001:db8::20')
        self.assertIsNone(self.controller.private_status()['selected_node'])
        self.assertTrue(any('--node-preflight' in cmd and 'ipv6' in cmd for cmd in self.commands))
        self.assertTrue(any(cmd[0]=='curl' and '-6' in cmd and 'test.example.com:443:[::1]' in cmd for cmd in self.commands))


if __name__ == '__main__': unittest.main()
