#!/usr/bin/env python3
"""Offline crash and real access-log rotation regressions."""
import gzip
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "emby-proxy").read_text().split("controller_cli() {", 1)[1].split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
ns = {"__name__": "usage_under_test"}
exec(compile(source, "emby-proxy:controller", "exec"), ns)


class UsageConsistencyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.log = self.base / "emby-proxy-test.example.com-access.log"
        self.used = self.base / "used_bytes"
        self.offset = self.base / "usage.offset"
        self.state = dict(access_log=str(self.log), used_file=str(self.used), usage_offset_file=str(self.offset))
        self.net = patch.object(ns["urllib"].request, "urlopen", side_effect=AssertionError("unexpected network"))
        self.net.start()
        self.addCleanup(self.net.stop)

    def entry(self, size, path="/Videos/stream"):
        return (json.dumps(dict(path=path, size=size)) + "\n").encode()

    def collect(self):
        return ns["collect_usage"](self.state)

    def test_caddy_timestamp_gzip_drains_tail_and_multiple_rotations(self):
        self.log.write_bytes(self.entry(10))
        self.assertEqual(self.collect(), 10)
        self.log.write_bytes(self.log.read_bytes() + self.entry(20, "/tail"))
        first = self.log.with_name(self.log.stem + "-2026-01-01T00-00-00.000.log.gz")
        with gzip.open(first, "wb") as stream:
            stream.write(self.log.read_bytes())
        second = self.log.with_name(self.log.stem + "-2026-01-01T00-00-01.000.log.gz")
        with gzip.open(second, "wb") as stream:
            stream.write(self.entry(30, "/middle"))
        self.log.unlink()
        self.log.write_bytes(self.entry(40, "/current"))
        self.assertEqual(self.collect(), 100)
        self.assertEqual(self.collect(), 100)

    def test_compressed_rotations_with_same_prefix_match_cursor_context(self):
        # Two archives intentionally share their first line.  The bytes near
        # the old cursor distinguish the archive that owns the unread tail.
        self.log.write_bytes(self.entry(1, "/common"))
        self.assertEqual(self.collect(), 1)
        first = self.log.with_name(self.log.stem + "-2026-01-01T00-00-00.000.log.gz")
        with gzip.open(first, "wb") as stream:
            stream.write(self.log.read_bytes() + self.entry(10, "/old"))
        second = self.log.with_name(self.log.stem + "-2026-01-01T00-00-01.000.log.gz")
        with gzip.open(second, "wb") as stream:
            stream.write(self.entry(1, "/common") + self.entry(20, "/newer"))
        self.log.write_bytes(self.entry(30, "/current"))
        # The first archive owns the cursor context; later archive and active
        # file are additional complete files that must also be drained.
        self.assertEqual(self.collect(), 62)

    def test_nginx_multiple_rotations_drains_intermediate_log(self):
        self.log.write_bytes(self.entry(10))
        self.assertEqual(self.collect(), 10)
        with self.log.open("ab") as stream:
            stream.write(self.entry(20, "/tail"))
        self.log.rename(Path(str(self.log) + ".2"))
        Path(str(self.log) + ".1").write_bytes(self.entry(30, "/middle"))
        self.log.write_bytes(self.entry(40, "/current"))
        self.assertEqual(self.collect(), 100)
        self.assertEqual(self.collect(), 100)

    def test_failed_compatibility_mirror_write_cannot_double_charge(self):
        self.log.write_bytes(self.entry(100))
        original = Path.replace

        def broken_mirror(path, target):
            if Path(target) == self.used:
                raise OSError("simulated crash before legacy mirror publication")
            return original(path, target)

        with patch.object(Path, "replace", broken_mirror):
            with self.assertRaises(OSError):
                self.collect()
        self.assertEqual(self.collect(), 100)
        self.assertEqual(self.used.read_text().strip(), "100")

    def test_failed_checkpoint_write_cannot_double_charge(self):
        self.log.write_bytes(self.entry(100))
        original = Path.replace

        def broken_checkpoint(path, target):
            if Path(target) == self.offset:
                raise OSError("simulated crash before cursor publication")
            return original(path, target)

        with patch.object(Path, "replace", broken_checkpoint):
            with self.assertRaises(OSError):
                self.collect()
        self.assertEqual(self.collect(), 100)

    def test_legacy_cursor_migration_keeps_existing_total(self):
        initial = self.entry(100)
        self.log.write_bytes(initial + self.entry(20, "/new"))
        self.used.write_text("500\n")
        self.offset.write_text("%s %s\n" % (self.log.stat().st_ino, len(initial)))
        self.assertEqual(self.collect(), 520)
        self.assertEqual(self.collect(), 520)

    def test_scalar_json_is_ignored_without_losing_valid_entries(self):
        self.log.write_bytes(b"null\n[]\n1\n" + self.entry(50))
        self.assertEqual(self.collect(), 50)

    def test_oversized_line_is_bounded_and_following_line_is_counted(self):
        self.log.write_bytes(b'{"path":"/bad","padding":"' + b'x' * (1024 * 1024 + 3) +
                             b'"}\n' + self.entry(60, "/after-large"))
        self.assertEqual(self.collect(), 60)


if __name__ == "__main__":
    unittest.main()
