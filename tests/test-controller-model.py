#!/usr/bin/env python3
"""Offline tests of the actual embedded controller; never starts systemd or calls DNS."""
import json
from pathlib import Path
import tempfile
import unittest
import os
import stat
from unittest.mock import patch, Mock
from types import SimpleNamespace
from contextlib import redirect_stdout
import io
from concurrent.futures import ThreadPoolExecutor

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "emby-proxy").read_text()
source = source.split("controller_cli() {", 1)[1].split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
ns = {"__name__": "controller_under_test"}
exec(compile(source, "emby-proxy:controller", "exec"), ns)


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "state.json"
        self.state = dict(schema_version=1, entry_id="domain-test.example.com",
                          domain="test.example.com", source="https://origin.example.com",
                          engine="caddy", nodes={}, enroll_tokens={"edge-a": "fixture-token"},
                          active_node=None)
        self.path.write_text(json.dumps(self.state))
        self.controller = ns["Controller"](self.path)
        # Any accidentally introduced outbound request makes this offline suite fail.
        self.net = patch.object(ns["urllib"].request, "urlopen", side_effect=AssertionError("unexpected network"))
        self.net.start()
        self.addCleanup(self.net.stop)
        self.clock = patch.dict(ns, now=lambda: 1000)
        self.clock.start()
        self.addCleanup(self.clock.stop)

    def nodes(self):
        self.controller.state["nodes"] = {
            "edge-a": dict(priority=100, quota_bytes=100, used_bytes=0, healthy=True, last_seen=1000),
            "edge-b": dict(priority=50, quota_bytes=200, used_bytes=0, healthy=True, last_seen=1000),
        }
        return self.controller.state["nodes"]

    def test_priority_and_exact_quota_boundary(self):
        nodes = self.nodes()
        self.assertEqual(self.controller.select(), "edge-a")
        nodes["edge-a"]["used_bytes"] = 100
        self.assertEqual(self.controller.select(), "edge-b")
        nodes["edge-b"]["used_bytes"] = 200
        self.assertIsNone(self.controller.select())

    def test_unhealthy_stale_and_unlimited(self):
        nodes = self.nodes()
        nodes["edge-a"]["healthy"] = False
        self.assertEqual(self.controller.select(), "edge-b")
        nodes["edge-a"].update(healthy=True, last_seen=909)
        self.assertEqual(self.controller.select(), "edge-b")
        nodes["edge-a"].update(last_seen=910, quota_bytes=0, used_bytes=10**12)
        self.assertEqual(self.controller.select(), "edge-a")

    def test_enrollment_token_is_single_use_and_status_redacted(self):
        body = dict(entry_id=self.state["entry_id"], node_id="edge-a", enroll_token="fixture-token")
        code, result = self.controller.enroll(body)
        self.assertEqual(code, 200)
        self.assertTrue(result["node_token"])
        self.assertEqual(self.controller.enroll(body)[0], 403)
        status = self.controller.public_status()
        self.assertEqual(status, {"entry_id": "domain-test.example.com", "domain": "test.example.com"})
        self.assertNotIn("enroll_tokens", status)

    def test_enrollment_token_expires(self):
        body = dict(entry_id=self.state["entry_id"], node_id="edge-a", enroll_token="fixture-token")
        self.controller.state["enroll_tokens"]["edge-a"] = {"token": "fixture-token", "issued_at": 1000 - 901}
        self.controller.save()
        self.assertEqual(self.controller.enroll(body)[0], 403)
        self.assertNotIn("edge-a", json.loads(self.path.read_text())["enroll_tokens"])

    def test_enrollment_rejects_untrusted_limits_and_non_global_address(self):
        body = dict(entry_id=self.state["entry_id"], node_id="edge-a", enroll_token="fixture-token",
                    priority=1_000_001, quota_bytes=-1, public_ip="127.0.0.1")
        code, result = self.controller.enroll(body)
        self.assertEqual(code, 400)
        self.assertIn("invalid_node_limits", result["error"])
        self.assertIn("edge-a", self.controller.state["enroll_tokens"])
        body.update(priority=100, quota_bytes=0, public_ip="127.0.0.1")
        code, result = self.controller.enroll(body)
        self.assertEqual(code, 400)
        self.assertIn("invalid_public_ip", result["error"])
        self.assertIn("edge-a", self.controller.state["enroll_tokens"])

    def test_heartbeat_auth_and_monotonic_usage(self):
        _, result = self.controller.enroll(dict(entry_id=self.state["entry_id"], node_id="edge-a", enroll_token="fixture-token"))
        body = dict(node_id="edge-a", healthy=True, used_bytes=80)
        before = self.path.read_bytes()
        self.assertEqual(self.controller.heartbeat(body, "wrong-token")[0], 403)
        self.assertEqual(before, self.path.read_bytes())
        self.controller.heartbeat(body, result["node_token"])
        body["used_bytes"] = 10
        self.controller.heartbeat(body, result["node_token"])
        self.assertEqual(json.loads(self.path.read_text())["nodes"]["edge-a"]["used_bytes"], 80)

    def test_dns_failure_preserves_active_then_retries(self):
        self.nodes()
        self.controller.state["active_node"] = "edge-b"
        self.controller.save()
        with patch.object(self.controller, "update_dns", return_value={"ok": False}) as dns:
            result = self.controller.reconcile()
            self.assertEqual(result["selected_node"], "edge-a")
            self.assertEqual(result["active_node"], "edge-b")
            dns.assert_called_once_with("edge-a")
        with patch.object(self.controller, "update_dns", return_value={"ok": True}):
            self.assertEqual(self.controller.reconcile()["active_node"], "edge-a")

    def test_weighted_pool_expands_records_by_configured_ratio(self):
        nodes = self.nodes()
        for nid, ip in (("edge-a", "192.0.2.1"), ("edge-b", "192.0.2.2")):
            nodes[nid]["public_ip"] = ip
        token = self.path.parent / "cf-token"
        token.write_text("fixture-token")
        self.controller.state.update(
            dns=dict(provider="cloudflare", zone_id="zone", record_id="r1",
                     record_ids=["r1", "r2", "r3", "r4", "r5"], token_file=str(token)),
            routing=dict(mode="weighted", weights={"edge-a": 80, "edge-b": 20}))
        self.controller.save()
        assignments = self.controller.weighted_pool_assignments()
        self.assertEqual([nid for _, nid in assignments].count("edge-a"), 4)
        self.assertEqual([nid for _, nid in assignments].count("edge-b"), 1)

    def test_weighted_reconcile_persists_active_record_pool(self):
        nodes = self.nodes()
        for nid, ip in (("edge-a", "192.0.2.1"), ("edge-b", "192.0.2.2")):
            nodes[nid]["public_ip"] = ip
        self.controller.state.update(
            dns=dict(provider="cloudflare", zone_id="zone", record_id="r1",
                     record_ids=["r1", "r2"], token_file=str(self.path.parent / "cf-token")),
            routing=dict(mode="weighted", weights={"edge-a": 1, "edge-b": 1}))
        (self.path.parent / "cf-token").write_text("fixture-token")
        self.controller.save()
        with patch.object(self.controller, "update_dns_pool", return_value={"ok": True, "verified": True}) as update:
            result = self.controller.reconcile()
        self.assertEqual(result["reason"], "dns_confirmed")
        self.assertEqual(self.controller.state["active_nodes"], ["edge-a", "edge-b"])
        update.assert_called_once_with([("r1", "edge-a"), ("r2", "edge-b")])

    def test_weighted_pool_rejects_unrepresentable_ratio_with_two_slots(self):
        nodes = self.nodes()
        for nid, ip in (("edge-a", "192.0.2.1"), ("edge-b", "192.0.2.2")):
            nodes[nid]["public_ip"] = ip
        self.controller.state.update(
            dns=dict(provider="cloudflare", zone_id="zone", record_id="r1",
                     record_ids=["r1", "r2"], token_file=str(self.path.parent / "cf-token")),
            routing=dict(mode="weighted", weights={"edge-a": 80, "edge-b": 20}))
        (self.path.parent / "cf-token").write_text("fixture-token")
        self.controller.save()
        with patch.object(self.controller, "update_dns_pool") as update:
            result = self.controller.reconcile()
        self.assertEqual(result["reason"], "dns_unconfirmed")
        self.assertIn("重复 IP 记录", result["dns"]["error"])
        update.assert_not_called()

    def test_weighted_reconcile_rejects_cloudflare_duplicate_slots_before_put(self):
        nodes = self.nodes()
        for nid, ip in (("edge-a", "192.0.2.1"), ("edge-b", "192.0.2.2")):
            nodes[nid]["public_ip"] = ip
        self.controller.state.update(
            dns=dict(provider="cloudflare", zone_id="zone", record_id="r1",
                     record_ids=["r1", "r2", "r3", "r4"], token_file=str(self.path.parent / "cf-token")),
            routing=dict(mode="weighted", weights={"edge-a": 80, "edge-b": 20}))
        (self.path.parent / "cf-token").write_text("fixture-token")
        self.controller.save()
        with patch.object(self.controller, "update_dns_pool") as update:
            result = self.controller.reconcile()
        self.assertEqual(result["reason"], "dns_unconfirmed")
        self.assertIn("重复 IP 记录", result["dns"]["error"])
        update.assert_not_called()

    def test_set_pool_weights_requires_registered_nodes_and_record_pool(self):
        nodes = self.nodes()
        self.controller.state["dns"] = dict(provider="cloudflare", record_id="r1",
                                             record_ids=["r1", "r2"])
        self.controller.save()
        args = SimpleNamespace(state=str(self.path), weight=["edge-a=80", "edge-b=20"])
        with redirect_stdout(io.StringIO()):
            ns["set_pool_weights"](args)
        saved = json.loads(self.path.read_text())
        self.assertEqual(saved["routing"], {"mode": "weighted", "weights": {"edge-a": 80, "edge-b": 20}, "schedule": []})
        args.weight = ["unknown=1"]
        with self.assertRaisesRegex(RuntimeError, "未注册节点"):
            ns["set_pool_weights"](args)

    def test_shrinking_cloudflare_pool_clears_weighted_metadata(self):
        self.controller.state.update(
            dns=dict(provider="cloudflare", record_id="abcd", record_ids=["abcd", "bcde"]),
            routing=dict(mode="weighted", weights={"edge-a": 80, "edge-b": 20}, schedule=[]),
            active_nodes=["edge-a", "edge-b"], confirmed_record_ips={"abcd": "192.0.2.1"})
        self.controller.save()
        args = SimpleNamespace(state=str(self.path), record_ids="abcd")
        with redirect_stdout(io.StringIO()):
            ns["set_cloudflare_records"](args)
        saved = json.loads(self.path.read_text())
        self.assertNotIn("routing", saved)
        self.assertEqual(saved["active_nodes"], [])
        self.assertNotIn("confirmed_record_ips", saved)

    def test_schedule_profiles_select_latest_slot_and_wrap_midnight(self):
        nodes = self.nodes()
        self.controller.state["dns"] = dict(provider="cloudflare", record_id="r1",
                                             record_ids=["r1", "r2"])
        self.controller.state["routing"] = dict(mode="weighted", weights={"edge-a": 100}, schedule=[
            {"start": "08:00", "weights": {"edge-a": 80, "edge-b": 20}},
            {"start": "20:00", "weights": {"edge-a": 20, "edge-b": 80}}])
        self.assertEqual(self.controller.schedule_profile(self.controller.state["routing"]["schedule"], "weights", 9 * 60)["edge-a"], 80)
        self.assertEqual(self.controller.schedule_profile(self.controller.state["routing"]["schedule"], "weights", 21 * 60)["edge-b"], 80)
        self.assertEqual(self.controller.schedule_profile(self.controller.state["routing"]["schedule"], "weights", 2 * 60)["edge-b"], 80)

    def test_dnspod_schedule_overrides_only_declared_lines(self):
        self.controller.state["dns"] = dict(provider="dnspod", routes={"默认": "edge-a", "电信": "edge-a"},
                                             schedule=[{"start": "00:00", "routes": {"电信": "edge-b"}}])
        nodes = self.nodes()
        nodes["edge-a"]["public_ip"] = "192.0.2.1"
        nodes["edge-b"]["public_ip"] = "192.0.2.2"
        plan = self.controller.line_plan()
        self.assertEqual(plan["电信"]["preferred_node"], "edge-b")
        self.assertEqual(plan["默认"]["preferred_node"], "edge-a")

    def test_set_schedule_validates_and_persists_cloudflare_profiles(self):
        self.controller.state["dns"] = dict(provider="cloudflare", record_id="r1", record_ids=["r1", "r2"])
        self.nodes()
        self.controller.save()
        args = SimpleNamespace(state=str(self.path), provider="cloudflare",
                               slot=["00:00|edge-a=80,edge-b=20", "08:00|edge-a=20,edge-b=80"])
        with redirect_stdout(io.StringIO()):
            ns["set_schedule"](args)
        saved = json.loads(self.path.read_text())
        self.assertEqual(saved["routing"]["schedule"][1]["weights"], {"edge-a": 20, "edge-b": 80})
        args.slot = ["08:00|edge-a=100", "08:00|edge-b=100"]
        with self.assertRaisesRegex(RuntimeError, "时间重复"):
            ns["set_schedule"](args)

    def test_set_schedule_rejects_duplicate_dnspod_line(self):
        self.controller.state["dns"] = dict(provider="dnspod")
        self.nodes()
        self.controller.save()
        args = SimpleNamespace(state=str(self.path), provider="dnspod",
                               slot=["00:00|电信=edge-a,电信=edge-b"])
        with self.assertRaisesRegex(RuntimeError, "线路不能重复"):
            ns["set_schedule"](args)

    def test_clear_schedule_preserves_static_cloudflare_weights(self):
        self.controller.state["routing"] = dict(mode="weighted",
                                                  weights={"edge-a": 80, "edge-b": 20},
                                                  schedule=[{"start": "00:00", "weights": {"edge-a": 1}}])
        self.controller.save()
        with redirect_stdout(io.StringIO()):
            ns["clear_schedule"](SimpleNamespace(state=str(self.path)))
        saved = json.loads(self.path.read_text())
        self.assertEqual(saved["routing"]["weights"], {"edge-a": 80, "edge-b": 20})
        self.assertNotIn("schedule", saved["routing"])

    def test_dnspod_same_line_pool_assigns_records_by_weight(self):
        nodes = self.nodes()
        self.controller.state["dns"] = dict(
            provider="dnspod", line_records={
                "默认": [
                    {"record_id": "101", "record_line_id": "0"},
                    {"record_id": "102", "record_line_id": "0"},
                    {"record_id": "103", "record_line_id": "0"},
                    {"record_id": "104", "record_line_id": "0"},
                    {"record_id": "105", "record_line_id": "0"},
                ]},
            line_weights={"默认": {"edge-a": 80, "edge-b": 20}})
        nodes["edge-a"]["public_ip"] = "192.0.2.1"
        nodes["edge-b"]["public_ip"] = "192.0.2.2"
        assignments = self.controller.line_pool_assignments("默认", {
            "selected_node": "edge-a", "active_node": None})
        self.assertEqual([nid for _, nid in assignments].count("edge-a"), 4)
        self.assertEqual([nid for _, nid in assignments].count("edge-b"), 1)

    def test_set_dnspod_line_pool_requires_multiple_records(self):
        self.nodes()
        self.controller.state["dns"] = dict(provider="dnspod", line_records={
            "默认": {"record_id": "101", "record_line_id": "0"}})
        self.controller.save()
        args = SimpleNamespace(state=str(self.path), line="默认", weight=["edge-a=80", "edge-b=20"])
        with self.assertRaisesRegex(RuntimeError, "至少需要两条"):
            ns["set_dnspod_line_pool"](args)

    def test_no_healthy_candidate_keeps_actual_active_node(self):
        nodes = self.nodes()
        self.controller.state["active_node"] = "edge-a"
        nodes["edge-a"]["healthy"] = False
        nodes["edge-b"]["healthy"] = False
        self.controller.save()
        with patch.object(self.controller, "update_dns") as dns:
            result = self.controller.reconcile()
        self.assertIsNone(result["selected_node"])
        self.assertEqual(result["active_node"], "edge-a")
        dns.assert_not_called()

    def test_issue_remembers_controller_url_under_state_lock(self):
        args = SimpleNamespace(state=str(self.path), node_id='', public_ip='192.0.2.10',
            controller_url='https://control.example.com/', name='fixture-edge', priority=100, quota_bytes=0)
        with redirect_stdout(io.StringIO()):
            ns['issue'](args)
        saved = json.loads(self.path.read_text())
        self.assertEqual(saved['controller_url'], 'https://control.example.com')
        self.assertIn('edge-192-0-2-10', saved['enroll_tokens'])
        backups = list(self.path.parent.glob('state.json.bak-*'))
        self.assertEqual(len(backups), 1)
        self.assertNotIn('edge-192-0-2-10', json.loads(backups[0].read_text()).get('enroll_tokens', {}))

    def test_issue_without_ip_generates_unique_ids_and_upgrade_guard(self):
        args = SimpleNamespace(state=str(self.path), node_id='', public_ip='',
            controller_url='https://control.example.com', name='', priority=100, quota_bytes=0)
        out = io.StringIO()
        with redirect_stdout(out):
            ns['issue'](args)
            ns['issue'](args)
        pending = json.loads(self.path.read_text())['enroll_tokens']
        self.assertIn('edge-node', pending)
        self.assertIn('edge-node-2', pending)
        self.assertNotIn('--public-ip', out.getvalue())
        self.assertIn("grep -q -- '--address-family'", out.getvalue())
        self.assertIn(') && sudo ep', out.getvalue())

    def test_issue_prefers_saved_controller_url_over_domain_fallback(self):
        self.state['control_domain'] = 'control.example.com'
        self.state['controller_url'] = 'https://saved-control.example.com'
        self.path.write_text(json.dumps(self.state))
        args = SimpleNamespace(state=str(self.path), node_id='edge-saved', public_ip='192.0.2.12',
            controller_url='', name='saved-edge', priority=100, quota_bytes=0)
        out = io.StringIO()
        with redirect_stdout(out):
            ns['issue'](args)
        self.assertIn('--controller-url https://saved-control.example.com', out.getvalue())
        self.assertNotIn('http://control.example.com:19090', out.getvalue())
        self.assertEqual(json.loads(self.path.read_text())['controller_url'], 'https://saved-control.example.com')

    def test_issue_uses_saved_controller_domain_when_url_omitted(self):
        self.state['control_domain'] = 'control.example.com'
        self.path.write_text(json.dumps(self.state))
        args = SimpleNamespace(state=str(self.path), node_id='edge-domain', public_ip='192.0.2.11',
            controller_url='', name='domain-edge', priority=100, quota_bytes=0)
        out = io.StringIO()
        with redirect_stdout(out):
            ns['issue'](args)
        self.assertIn('--controller-url http://control.example.com:19090', out.getvalue())
        self.assertEqual(json.loads(self.path.read_text())['controller_url'], 'http://control.example.com:19090')

    def test_edge_ip_detection_is_bounded_and_tls_verified(self):
        with patch.object(ns['subprocess'], 'run', return_value=SimpleNamespace(stdout='8.8.8.8\n')) as run:
            self.assertEqual(ns['resolve_edge_ipv4'](''), '8.8.8.8')
        command = run.call_args.args[0]
        self.assertIn('-4', command)
        self.assertIn('--noproxy', command)
        self.assertNotIn('-k', command)
        self.assertEqual(run.call_args.kwargs['timeout'], 10)

    def test_manual_edge_ip_never_uses_network_and_validates(self):
        with patch.object(ns['subprocess'], 'run') as run:
            self.assertEqual(ns['resolve_edge_ipv4']('8.8.8.8'), '8.8.8.8')
            for ip in ['127.0.0.1', '10.0.0.1', 'bad', '999.1.1.1', '::1']:
                with self.assertRaises(RuntimeError):
                    ns['resolve_edge_ipv4'](ip)
            run.assert_not_called()

    def test_edge_ipv6_detection_uses_ipv6_endpoint_and_validates(self):
        with patch.object(ns['subprocess'], 'run', return_value=SimpleNamespace(stdout='2001:4860:4860::8888\n')) as run:
            self.assertEqual(ns['resolve_edge_ip']('', 'ipv6'), '2001:4860:4860::8888')
        command = run.call_args.args[0]
        self.assertIn('-6', command)
        self.assertIn('api64.ipify.org', command[-1])
        with self.assertRaisesRegex(RuntimeError, 'IPv6'):
            ns['resolve_edge_ip']('192.0.2.1', 'ipv6')

    def test_enrollment_rejects_address_family_mismatch(self):
        self.state['address_family'] = 'ipv6'
        self.path.write_text(json.dumps(self.state))
        body = dict(entry_id=self.state['entry_id'], node_id='edge-a', enroll_token='fixture-token',
                    address_family='ipv4', public_ip='192.0.2.1')
        code, result = self.controller.enroll(body)
        self.assertEqual(code, 409)
        self.assertIn('address_family', result['error'])

    def test_edge_detection_failure_does_not_consume_registration(self):
        args = SimpleNamespace(controller_url='https://control.example.com', public_ip='', node_id='edge-node')
        with patch.object(ns['os'], 'geteuid', return_value=0), \
             patch.dict(ns, resolve_edge_ipv4=Mock(side_effect=RuntimeError('detect failed')), post_json=Mock()) as _:
            with self.assertRaisesRegex(RuntimeError, 'detect failed'):
                ns['node_install'](args)
            ns['post_json'].assert_not_called()

    def test_source_validation_rejects_path_and_revoke_removes_node(self):
        bad = SimpleNamespace(state=str(self.path), entry_id='', domain='test.example.com',
                              source='https://origin.example.com/path', engine='caddy',
                              zone_id=None, record_id=None, token_file=None, force=False)
        with self.assertRaises(RuntimeError):
            ns['init_state'](bad)
        code, result = self.controller.enroll(dict(entry_id=self.state['entry_id'], node_id='edge-a', enroll_token='fixture-token'))
        self.assertEqual(code, 200)
        self.assertEqual(self.controller.revoke({'node_id': 'edge-a'}, result['node_token'])[0], 200)
        self.assertNotIn('edge-a', self.controller.state['nodes'])

    def test_init_stores_dedicated_controller_domain_and_rejects_collision(self):
        target = Path(self.temp.name) / 'init.json'
        args = SimpleNamespace(state=str(target), entry_id='', domain='test.example.com',
                               source='https://origin.example.com', engine='caddy',
                               control_domain='control.example.com', zone_id=None,
                               record_id=None, token_file=None, force=False)
        with redirect_stdout(io.StringIO()):
            ns['init_state'](args)
        self.assertEqual(json.loads(target.read_text())['control_domain'], 'control.example.com')
        args.control_domain = 'test.example.com'
        args.force = True
        with self.assertRaisesRegex(RuntimeError, '不能与业务入口域名相同'):
            ns['init_state'](args)

    def test_init_persists_ipv6_address_family_and_aaaa_record_type(self):
        target = Path(self.temp.name) / 'ipv6-init.json'
        args = SimpleNamespace(state=str(target), entry_id='', domain='test.example.com',
                               source='https://origin.example.com', engine='caddy',
                               address_family='ipv6', control_domain='', zone_id='zone',
                               record_id='abcd', record_ids='abcd', token_file='/tmp/token', force=False)
        with redirect_stdout(io.StringIO()):
            ns['init_state'](args)
        saved = json.loads(target.read_text())
        self.assertEqual(saved['address_family'], 'ipv6')
        self.assertEqual(saved['dns']['record_type'], 'AAAA')

    def test_master_install_checks_restart_and_failure(self):
        args = SimpleNamespace(state=str(self.path), listen='127.0.0.1:19090', reconcile_interval=30)
        for fail in (False, True):
            output = io.StringIO()
            error = ns['subprocess'].CalledProcessError(1, 'systemctl')
            with patch.dict(ns, {'write_unit': Mock(return_value=None), 'restore_file': Mock()}), \
                 patch.object(ns['os'], 'geteuid', return_value=0), \
                 patch.object(ns['subprocess'], 'run', side_effect=error if fail else None) as run, \
                 redirect_stdout(output):
                if fail:
                    with self.assertRaises(ns['subprocess'].CalledProcessError):
                        ns['master_install'](args)
                    self.assertNotIn('已启动', output.getvalue())
                else:
                    ns['master_install'](args)
                    self.assertTrue(all(c.kwargs.get('check') is True for c in run.call_args_list))
                    self.assertIn(['systemctl', 'restart', 'emby-proxy-master.service'],
                                  [c.args[0] for c in run.call_args_list])

    def test_master_unit_quotes_custom_state_path(self):
        captured = {}
        args = SimpleNamespace(state='/tmp/state dir/controller.json', listen='127.0.0.1:19090', reconcile_interval=30)
        def write(path, content): captured['content'] = content; return None
        with patch.dict(ns, {'write_unit': write}), patch.object(ns['os'], 'geteuid', return_value=0), \
             patch.object(ns['subprocess'], 'run', return_value=SimpleNamespace()):
            with redirect_stdout(io.StringIO()): ns['master_install'](args)
        self.assertIn('--state "/tmp/state dir/controller.json"', captured['content'])
        for hardening in ('NoNewPrivileges=true', 'PrivateTmp=true', 'ProtectHome=true',
                          'RestrictSUIDSGID=true', 'RestrictNamespaces=true',
                          'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6', 'UMask=0077'):
            self.assertIn(hardening, captured['content'])

    def test_generated_id_avoids_nodes_and_pending_tokens(self):
        state = dict(nodes={"edge-192-0-2-1": {}}, enroll_tokens={"edge-192-0-2-1-2": "fixture"})
        self.assertEqual(ns["auto_node_id"](state, "192.0.2.1"), "edge-192-0-2-1-3")

    def test_controller_state_is_private_and_init_requires_force(self):
        self.path.chmod(0o644)
        ns["atomic_write"](self.path, self.state)
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        args = SimpleNamespace(state=str(self.path), entry_id="", domain="test.example.com",
                               source="https://origin.example.com", engine="caddy",
                               zone_id=None, record_id=None, token_file=None, force=False)
        with self.assertRaises(RuntimeError):
            ns["init_state"](args)
        args.force = True
        with redirect_stdout(io.StringIO()):
            ns["init_state"](args)
        backups = list(self.path.parent.glob("state.json.bak-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(stat.S_IMODE(backups[0].stat().st_mode), 0o600)

    def test_reconcile_endpoint_is_not_publicly_mutable(self):
        handler = object.__new__(ns["Handler"])
        handler.path = "/reconcile"
        handler.headers = {}
        handler.body = lambda: {}
        handler.server = SimpleNamespace(controller=SimpleNamespace(reconcile=lambda: {"ran": True}))
        captured = []
        handler.reply = lambda *args: captured.append(args)
        handler.do_POST()
        self.assertEqual(captured, [(404, {"error": "not_found"})])

    def test_edge_health_requires_local_https_health_route(self):
        calls = []
        fake = SimpleNamespace(returncode=0)
        with patch.object(ns["shutil"], "which", return_value="/usr/bin/curl"), \
             patch.object(ns["subprocess"], "run", side_effect=lambda *args, **kwargs: calls.append((args, kwargs)) or fake):
            self.assertTrue(ns["local_entry_health"]({"domain": "emby.example.com"}))
        command = calls[0][0][0]
        self.assertIn("--resolve", command)
        self.assertIn("emby.example.com:443:127.0.0.1", command)
        self.assertIn("https://emby.example.com/_emby_proxy_health", command)
        self.assertNotIn("-k", command)

    def test_usage_collector_accumulates_json_bytes_once_and_excludes_health(self):
        log = Path(self.temp.name) / "access.log"
        used = Path(self.temp.name) / "used_bytes"
        offset = Path(self.temp.name) / "usage.offset"
        entries = [
            {"path": "/_emby_proxy_health", "size": 200},
            {"request": {"uri": "/Videos/stream?id=1"}, "status": 200, "size": 4096},
            {"path": "/Items", "bytes_sent": 512},
        ]
        log.write_text("".join(json.dumps(item) + "\n" for item in entries))
        state = {"access_log": str(log), "used_file": str(used), "usage_offset_file": str(offset)}
        self.assertEqual(ns["collect_usage"](state), 4608)
        self.assertEqual(ns["collect_usage"](state), 4608)
        with log.open("a") as stream:
            stream.write(json.dumps({"path": "/Videos/next", "size": 1024}) + "\n")
        self.assertEqual(ns["collect_usage"](state), 5632)
        log.write_text(json.dumps({"path": "/Videos/after-rotate", "size": 2048}) + "\n")
        self.assertEqual(ns["collect_usage"](state), 7680)
        self.assertEqual(used.read_text().strip(), "7680")

    def test_usage_cursor_handles_inode_rotation_and_partial_line(self):
        log = Path(self.temp.name) / "access.log"
        used = Path(self.temp.name) / "used_bytes"
        offset = Path(self.temp.name) / "usage.offset"
        state = {"access_log": str(log), "used_file": str(used), "usage_offset_file": str(offset)}
        log.write_text(json.dumps({"path": "/first", "size": 100}) + "\n")
        self.assertEqual(ns["collect_usage"](state), 100)
        # A line that has not received its newline must be retried, not lost.
        with log.open("a") as stream:
            stream.write(json.dumps({"path": "/partial", "size": 200}))
        self.assertEqual(ns["collect_usage"](state), 100)
        with log.open("a") as stream:
            stream.write("\n")
        self.assertEqual(ns["collect_usage"](state), 300)
        # Rename rotation: drain the old inode tail exactly once, then read the
        # new file from byte zero. Repeated heartbeats must remain idempotent.
        with log.open("a") as stream:
            stream.write(json.dumps({"path": "/before-rotate", "size": 400}) + "\n")
        rotated = log.with_name("access.log.1")
        log.rename(rotated)
        log.write_text(json.dumps({"path": "/after-rotate", "size": 500}) + "\n")
        self.assertEqual(ns["collect_usage"](state), 1200)
        self.assertEqual(ns["collect_usage"](state), 1200)

    def test_usage_collector_serializes_concurrent_readers(self):
        log = Path(self.temp.name) / "access.log"
        state = {"access_log": str(log), "used_file": str(Path(self.temp.name) / "used_bytes"),
                 "usage_offset_file": str(Path(self.temp.name) / "usage.offset")}
        log.write_text("".join(json.dumps({"path": "/item", "size": 7}) + "\n" for _ in range(100)))
        with ThreadPoolExecutor(max_workers=5) as pool:
            results = list(pool.map(lambda _: ns["collect_usage"](state), range(5)))
        self.assertEqual(results[-1], 700)
        self.assertEqual(Path(state["used_file"]).read_text().strip(), "700")


if __name__ == "__main__":
    unittest.main()
