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
        self.assertIn('auto-ip', out.getvalue())
        self.assertIn(') && sudo ep', out.getvalue())

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


if __name__ == "__main__":
    unittest.main()
