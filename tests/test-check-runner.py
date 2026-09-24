#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("check_runner", Path(__file__).resolve().parents[1] / "scripts/check.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "tests").mkdir()
        (self.root / "scripts").mkdir()
        for name in (*runner.RELEASE_FILES, "setup-emby-caddy.sh"):
            (self.root / name).write_text("#!/bin/bash\n:\n")
        self.scope = patch.object(runner, "ROOT", self.root)
        self.scope.start()
        self.addCleanup(self.scope.stop)

    def test_syntax_checks_backend_not_just_first_file(self):
        (self.root / "setup-emby-proxy.sh").write_text("if then\n")
        with self.assertRaises(runner.subprocess.CalledProcessError):
            runner.syntax_checks()

    def test_bad_checksum_is_not_silently_regenerated(self):
        manifest = self.root / "checksums.txt"
        original = ''.join('0' * 64 + '  ' + name + '\n' for name in runner.RELEASE_FILES)
        manifest.write_text(original)
        with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
            runner.checksum_check()
        self.assertEqual(manifest.read_text(), original)

    def test_failure_and_timeout_are_nonzero(self):
        fail = self.root / "tests/test-fail.sh"
        fail.write_text("exit 7\n")
        self.assertEqual(runner.run_suite(fail, 2, self.root)["exit_code"], 7)
        hang = self.root / "tests/test-hang.sh"
        hang.write_text("sleep 30\n")
        result = runner.run_suite(hang, 0.1, self.root)
        self.assertEqual(result["exit_code"], 124)
        self.assertTrue(result["timeout"])


if __name__ == "__main__":
    unittest.main()
