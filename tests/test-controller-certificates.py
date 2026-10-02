#!/usr/bin/env python3
"""Certificate API and deployment regressions, with ephemeral test keys only."""
import json
import os
from pathlib import Path
import ssl
import subprocess
import threading
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'emby-proxy').read_text().split('controller_cli() {', 1)[1]
source = source.split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
ns = {'__name__': 'certificate_test'}
exec(compile(source, 'embedded-controller', 'exec'), ns)

class Certificates(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        pair = self.root / 'certificates' / 'entry' / 'current'
        pair.mkdir(parents=True)
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
            '-keyout', str(pair / 'privkey.pem'), '-out', str(pair / 'fullchain.pem'),
            '-days', '3', '-subj', '/CN=test.example.com',
            '-addext', 'subjectAltName=DNS:test.example.com'], check=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.pair = pair
        self.path = self.root / 'controller.json'
        self.state = dict(entry_id='domain-test.example.com', domain='test.example.com',
            source='https://origin.example.com', nodes={'edge-a': {'token_hash': ns['digest']('fixture-token')}},
            certificates={'directory': str(self.root / 'certificates'), 'control_domain': 'control.example.com'})
        self.path.write_text(json.dumps(self.state))
        self.controller = ns['Controller'](self.path)

    def test_certificate_requires_tls_and_authenticated_matching_entry(self):
        body = dict(entry_id=self.state['entry_id'], node_id='edge-a')
        method = self.controller.certificate
        self.assertEqual(method(body, 'fixture-token', secure=False)[0], 403)
        self.assertEqual(method(body, 'wrong', secure=True)[0], 403)
        self.assertEqual(method(dict(body, entry_id='other'), 'fixture-token', secure=True)[0], 403)
        code, bundle = method(body, 'fixture-token', secure=True)
        self.assertEqual(code, 200)
        self.assertEqual(bundle['domain'], 'test.example.com')
        self.assertEqual(bundle['certificate'], (self.pair / 'fullchain.pem').read_text())
        self.assertEqual(bundle['private_key'], (self.pair / 'privkey.pem').read_text())
        public = self.controller.public_status()
        self.assertNotIn('certificates', public)
        self.assertNotIn('PRIVATE KEY', json.dumps(public))

    def test_install_validates_identity_and_rolls_back_reload_failure(self):
        bundle=dict(domain='test.example.com', certificate=(self.pair/'fullchain.pem').read_text(),
                    private_key=(self.pair/'privkey.pem').read_text())
        state=dict(domain='test.example.com', engine='nginx', certificate_directory=str(self.root/'edge'))
        with patch.dict(os.environ, SSL_CERT_FILE=str(self.pair/'fullchain.pem')):
            version=ns['install_certificate'](state,bundle,reload=False)
            current=Path(state['certificate_directory'])/'current'
            original=current.resolve()
            self.assertEqual((current/'privkey.pem').stat().st_mode & 0o777, 0o600)
            with self.assertRaises(RuntimeError):
                ns['install_certificate'](dict(state,domain='other.example.com'),bundle,reload=False)
            with self.assertRaises(RuntimeError):
                ns['install_certificate'](dict(state,domain='other.example.com'),dict(bundle,domain='other.example.com'),reload=False)
            with self.assertRaises(RuntimeError):
                ns['install_certificate'](state,dict(bundle,private_key='invalid-key'),reload=False)
            self.assertEqual(current.resolve(),original)
            # A new valid pair must not replace the working version if reload fails.
            subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes',
                '-keyout',str(self.root/'new.key'),'-out',str(self.root/'new.pem'),'-days','3',
                '-subj','/CN=test.example.com','-addext','subjectAltName=DNS:test.example.com'],
                check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            bundle.update(certificate=(self.root/'new.pem').read_text(), private_key=(self.root/'new.key').read_text())
            real_run=subprocess.run
            def run(cmd, **kwargs):
                if cmd[0] == 'systemctl': raise subprocess.CalledProcessError(1,cmd)
                if cmd[0] == 'nginx': return subprocess.CompletedProcess(cmd,0)
                return real_run(cmd,**kwargs)
            with patch.dict(os.environ,SSL_CERT_FILE=str(self.root/'new.pem')), patch.object(subprocess,'run',side_effect=run):
                with self.assertRaises(Exception): ns['install_certificate'](state,bundle,reload=True)
            self.assertEqual(current.resolve(),original)
            self.assertEqual(version,ns['hashlib'].sha256((self.pair/'fullchain.pem').read_bytes()).hexdigest())

    def test_real_https_distribution_and_plaintext_rejection(self):
        cert=self.root/'localhost.pem'; key=self.root/'localhost.key'
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes',
            '-keyout',str(key),'-out',str(cert),'-days','3','-subj','/CN=localhost',
            '-addext','subjectAltName=DNS:localhost'],check=True,
            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        server=ns['Server'](('127.0.0.1',0),self.controller)
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cert,key)
        server.tls_context=context
        thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
        try:
            state=dict(controller='https://localhost:'+str(server.server_port),node_id='edge-a',
                node_token='fixture-token',entry_id=self.state['entry_id'])
            with patch.dict(os.environ, SSL_CERT_FILE=str(cert), NO_PROXY='localhost', no_proxy='localhost'):
                bundle=ns['secure_certificate_request'](state)
            self.assertEqual(bundle['private_key'],(self.pair/'privkey.pem').read_text())
            with self.assertRaises(RuntimeError):
                ns['secure_certificate_request'](dict(state,controller='http://localhost:'+str(server.server_port)))
            with self.assertRaises(RuntimeError):
                ns['secure_certificate_request'](state)  # Untrusted self-signed controller must fail.
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=3)

    def test_http_enrollment_does_not_consume_token_after_config_change(self):
        self.controller.state.pop('certificates')  # Simulate an old HTTP process's cached state.
        current=json.loads(self.path.read_text())
        current['enroll_tokens']={'new':dict(token='fixture',issued_at=ns['now']())}
        self.path.write_text(json.dumps(current))
        code,_=self.controller.enroll(dict(entry_id=self.state['entry_id'],node_id='new',enroll_token='fixture'))
        self.assertEqual(code,403)
        self.assertIn('new',json.loads(self.path.read_text())['enroll_tokens'])

    def test_dns01_renewal_uses_only_scoped_credentials_and_publishes_both_pairs(self):
        control=self.root/'control-fixture'; control.mkdir()
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes',
            '-keyout',str(control/'privkey.pem'),'-out',str(control/'fullchain.pem'),'-days','3',
            '-subj','/CN=control.example.com','-addext','subjectAltName=DNS:control.example.com'],
            check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        roots=self.root/'roots.pem'; roots.write_text((control/'fullchain.pem').read_text()+(self.pair/'fullchain.pem').read_text())
        token=self.root/'token'; token.write_text('fixture-token')
        self.state['dns']=dict(provider='cloudflare',token_file=str(token))
        self.state['certificates']['directory']=str(self.root/'managed')
        self.path.write_text(json.dumps(self.state))
        real_run=subprocess.run; commands=[]
        def run(cmd, **kwargs):
            if cmd[0] != 'certbot': return real_run(cmd,**kwargs)
            commands.append(cmd)
            name=cmd[cmd.index('--cert-name')+1]
            target=Path(cmd[cmd.index('--config-dir')+1])/'live'/name; target.mkdir(parents=True,exist_ok=True)
            fixture=self.pair if name=='entry' else control
            for f in ('fullchain.pem','privkey.pem'): (target/f).write_bytes((fixture/f).read_bytes())
            return subprocess.CompletedProcess(cmd,0)
        with patch.object(os,'geteuid',return_value=0), patch.dict(os.environ,SSL_CERT_FILE=str(roots)), \
             patch.object(subprocess,'run',side_effect=run):
            ns['cert_renew'](SimpleNamespace(state=str(self.path)))
        self.assertEqual(len(commands),2)
        for cmd in commands:
            self.assertIn('--dns-cloudflare',cmd)
            self.assertNotIn('fixture-token',cmd)
            self.assertNotIn('--webroot',cmd)
        for name in ('entry','control'):
            self.assertTrue((self.root/'managed'/name/'current'/'privkey.pem').exists())
        self.assertEqual((self.root/'managed'/'cloudflare.ini').stat().st_mode & 0o777,0o600)

    def test_setup_timer_or_master_failure_preserves_live_configuration(self):
        self.state.pop('certificates'); self.state['controller_url']='http://192.0.2.1:19090'
        self.path.write_text(json.dumps(self.state))
        args=SimpleNamespace(state=str(self.path), control_domain='control.example.com', install_deps=False)
        for failure in ('timer','master'):
            with self.subTest(failure=failure), patch.object(os,'geteuid',return_value=0), \
                 patch.object(ns['shutil'],'which',return_value='/fixture/certbot'), \
                 patch.object(subprocess,'run',return_value=subprocess.CompletedProcess([],0)), \
                 patch.dict(ns,issue_certificates=lambda *a:None), \
                 patch.dict(ns,install_certificate_timer=lambda *a: (_ for _ in ()).throw(RuntimeError('timer failed')) if failure=='timer' else None), \
                 patch.dict(ns,master_install=lambda *a: (_ for _ in ()).throw(RuntimeError('master failed'))):
                with self.assertRaises(RuntimeError): ns['cert_setup'](args)
            after=json.loads(self.path.read_text())
            self.assertNotIn('certificates',after)
            self.assertEqual(after['controller_url'],self.state['controller_url'])

    def test_sync_http_rejection_keeps_valid_existing_certificate(self):
        bundle=dict(domain='test.example.com', certificate=(self.pair/'fullchain.pem').read_text(),
                    private_key=(self.pair/'privkey.pem').read_text())
        st=dict(domain='test.example.com',engine='nginx',controller='http://192.0.2.1:19090',
            certificate_directory=str(self.root/'edge'))
        with patch.dict(os.environ, SSL_CERT_FILE=str(self.pair/'fullchain.pem')):
            ns['install_certificate'](st,bundle,reload=False)
        path=self.root/'node.json'; path.write_text(json.dumps(st))
        current=(self.root/'edge'/'current').resolve()
        with self.assertRaises(RuntimeError): ns['node_cert_sync'](SimpleNamespace(state=str(path)))
        self.assertEqual((self.root/'edge'/'current').resolve(),current)
        self.assertEqual(json.loads((self.root/'edge'/'status.json').read_text())['status'],'sync_failed')

    def test_caddy_controller_block_is_marked_idempotent_and_refuses_conflict(self):
        path=self.root/'Caddyfile'
        path.write_text('existing.example.com {\n\trespond "ok"\n}\n\n'
                        'control.example.com {\n\n reverse_proxy 127.0.0.1:19090\n}\n')
        backup=ns['update_controller_caddyfile']('control.example.com',path)
        self.assertIsNotNone(backup)
        text=path.read_text()
        self.assertIn('# BEGIN MANAGED EMBY PROXY CONTROLLER: control.example.com',text)
        self.assertEqual(text.count('control.example.com {'),1)
        self.assertIsNone(ns['update_controller_caddyfile']('control.example.com',path))
        conflict=self.root/'conflict.Caddyfile'
        conflict.write_text('control.example.com {\n reverse_proxy 127.0.0.1:9000\n}\n')
        with self.assertRaises(RuntimeError):
            ns['update_controller_caddyfile']('control.example.com',conflict)
        self.assertNotIn('BEGIN MANAGED',conflict.read_text())

if __name__ == '__main__': unittest.main()
