#!/usr/bin/env python3
"""Regression tests for private state writes and systemd unit ownership."""
import json, os, stat, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'emby-proxy').read_text().split("controller_cli() {",1)[1].split("<<'PY'\n",1)[1].split("\nPY\n",1)[0]
ns={'__name__':'state_unit_under_test'}
exec(compile(source,'emby-proxy:state-unit','exec'),ns)

class StateUnitSafetyTests(unittest.TestCase):
    def test_atomic_write_private_and_no_stale_tmp(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'state.json'; ns['atomic_write'](p, {'ok': True})
            self.assertEqual(stat.S_IMODE(p.stat().st_mode), 0o600)
            self.assertEqual(json.loads(p.read_text()), {'ok': True})
            self.assertFalse(list(Path(d).glob('*.tmp')))

    def test_atomic_write_does_not_follow_existing_symlink(self):
        with tempfile.TemporaryDirectory() as d:
            d=Path(d); victim=d/'victim'; victim.write_text('keep'); p=d/'state.json'; p.symlink_to(victim)
            ns['atomic_write'](p, {'new': True})
            self.assertEqual(victim.read_text(), 'keep')
            self.assertFalse(p.is_symlink())
            self.assertEqual(json.loads(p.read_text()), {'new': True})

    def test_backup_and_restore_reject_symlink_targets(self):
        with tempfile.TemporaryDirectory() as d:
            d=Path(d); victim=d/'victim'; victim.write_text('keep'); p=d/'state.json'; p.symlink_to(victim)
            with self.assertRaises(RuntimeError): ns['backup_file'](p)
            with self.assertRaises(RuntimeError): ns['restore_file'](p, None)
            self.assertEqual(victim.read_text(), 'keep')

    def test_atomic_text_write_rejects_symlink_and_preserves_target(self):
        with tempfile.TemporaryDirectory() as d:
            d=Path(d); victim=d/'victim'; victim.write_text('keep'); p=d/'Caddyfile'; p.symlink_to(victim)
            with self.assertRaisesRegex(RuntimeError, '符号链接'):
                ns['atomic_text_write'](p, 'replace')
            self.assertEqual(victim.read_text(), 'keep')
            self.assertTrue(p.is_symlink())

    def test_atomic_text_write_preserves_existing_mode(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'Caddyfile'; p.write_text('old'); p.chmod(0o640)
            ns['atomic_text_write'](p, 'new')
            self.assertEqual(p.read_text(), 'new')
            self.assertEqual(stat.S_IMODE(p.stat().st_mode), 0o640)
            self.assertFalse(list(Path(d).glob('*.tmp-*')))

    def test_atomic_text_write_failure_keeps_original(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'Caddyfile'; p.write_text('old')
            with patch.object(ns['os'], 'replace', side_effect=OSError('publish failed')):
                with self.assertRaises(OSError): ns['atomic_text_write'](p, 'new')
            self.assertEqual(p.read_text(), 'old')
            self.assertFalse(list(Path(d).glob('*.tmp-*')))

    def test_controller_caddy_update_refuses_symlink(self):
        with tempfile.TemporaryDirectory() as d:
            d=Path(d); victim=d/'victim'; victim.write_text('keep'); p=d/'Caddyfile'; p.symlink_to(victim)
            with self.assertRaisesRegex(RuntimeError, '符号链接'):
                ns['update_controller_caddyfile']('control.example.com', p)
            self.assertEqual(victim.read_text(), 'keep')

    def test_state_lock_rejects_symlink_lock(self):
        with tempfile.TemporaryDirectory() as d:
            d=Path(d); target=d/'victim'; target.write_text('keep')
            lock=d/'state.json.lock'; lock.symlink_to(target)
            with self.assertRaises(OSError):
                with ns['state_lock'](d/'state.json'):
                    pass
            self.assertEqual(target.read_text(), 'keep')

    def test_write_unit_rejects_unmanaged_same_name(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'emby-proxy-master.service'; p.write_text('[Service]\nExecStart=/usr/local/bin/other\n')
            with self.assertRaisesRegex(RuntimeError, '非脚本托管'):
                ns['write_unit'](p, '# MANAGED EMBY CONTROLLER\n[Service]\nExecStart=x\n')
            self.assertIn('/usr/local/bin/other', p.read_text())

    def test_write_unit_rejects_symlink_even_if_target_is_managed(self):
        with tempfile.TemporaryDirectory() as d:
            d=Path(d); target=d/'real'; target.write_text('# MANAGED EMBY CONTROLLER\n')
            p=d/'unit'; p.symlink_to(target)
            with self.assertRaisesRegex(RuntimeError, '符号链接'):
                ns['write_unit'](p, '# MANAGED EMBY CONTROLLER\nnew')
            self.assertEqual(target.read_text(), '# MANAGED EMBY CONTROLLER\n')

    def test_systemd_quote_escapes_specifiers_and_environment_expansion(self):
        value='/tmp/state%dir/$HOME/"x"'
        quoted=ns['systemd_quote'](value)
        self.assertEqual(quoted, '"/tmp/state%%dir/$$HOME/\\"x\\""')

    def test_master_unit_has_ownership_marker(self):
        args=type('A',(),{'state':'/tmp/controller.json','listen':'127.0.0.1:19090','reconcile_interval':30})()
        captured={}
        with patch.dict(ns, {'write_unit':lambda path,content: captured.setdefault('content',content) or None}), \
             patch.object(ns['os'],'geteuid',return_value=0), patch.object(ns['subprocess'],'run',return_value=type('R',(),{})()):
            with __import__('contextlib').redirect_stdout(__import__('io').StringIO()): ns['master_install'](args)
        self.assertIn('# MANAGED EMBY CONTROLLER', captured['content'])

    def test_master_install_failure_cleans_newly_created_unit_state(self):
        args=type('A',(),{'state':'/tmp/controller.json','listen':'127.0.0.1:19090','reconcile_interval':30})()
        calls=[]
        def run(command, **kwargs):
            calls.append(command)
            if command[:2] == ['systemctl','restart']:
                raise RuntimeError('restart failed')
            return type('R',(),{})()
        with patch.dict(ns, {'write_unit':lambda path,content: None,
                             'restore_file':lambda path,backup: None,
                             '_restore_systemd_state':lambda *args: calls.append(('restore',)+args)}), \
             patch.object(ns['os'],'geteuid',return_value=0), patch.object(ns['subprocess'],'run',side_effect=run):
            with self.assertRaises(RuntimeError): ns['master_install'](args)
        self.assertIn(('restore','emby-proxy-master.service',False,False), calls)

if __name__=='__main__': unittest.main()
