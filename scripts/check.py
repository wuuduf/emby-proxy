#!/usr/bin/env python3
"""Repository checks only. Never installs software or connects to a VPS."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
RELEASE_FILES = ("emby-proxy", "setup-emby-proxy.sh")


def syntax_checks():
    # bash -n a b checks only a: b is an argument, not another input file.
    files = [ROOT / name for name in (*RELEASE_FILES, "setup-emby-caddy.sh")]
    files += sorted((ROOT / "tests").glob("*.sh"))
    for path in files:
        subprocess.run(["bash", "-n", str(path)], check=True)
    for path in sorted((ROOT / "scripts").glob("*.py")) + sorted((ROOT / "tests").glob("*.py")):
        compile(path.read_text(), str(path), "exec")
    source = (ROOT / "emby-proxy").read_text()
    blocks = re.findall(r"<<'PY'\n(.*?)\nPY\n", source, re.DOTALL)
    if not blocks:
        raise ValueError("No embedded Python found in manager; update syntax checker")
    for index, block in enumerate(blocks, 1):
        compile(block, f"emby-proxy:embedded-python-{index}", "exec")
    print(f"PASS syntax: {len(files)} shell files, {len(blocks)} embedded Python blocks")


def checksum_check():
    records = {}
    for line in (ROOT / "checksums.txt").read_text().splitlines():
        digest, name = line.split()
        if name in records or name not in RELEASE_FILES:
            raise ValueError(f"Duplicate or unexpected checksum entry: {name}")
        records[name] = digest
    if set(records) != set(RELEASE_FILES):
        raise ValueError("checksums.txt must contain both release files")
    for name, expected in records.items():
        actual = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
        if actual != expected:
            raise ValueError(f"Checksum mismatch: {name}; review diff, then explicitly regenerate checksums.txt")
    print("PASS release checksums")


def run_suite(path, timeout, log_dir):
    command = [sys.executable if path.suffix == ".py" else "bash", str(path)]
    log = log_dir / (path.stem + ".log")
    start = time.monotonic()
    timed_out = False
    with log.open("w") as output:
        proc = subprocess.Popen(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                                start_new_session=True)
        try:
            code = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass
            # Also reap descendants that outlive a terminated shell.
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
            code = 124
        except KeyboardInterrupt:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
            raise
    result = {"suite": path.name, "exit_code": code, "timeout": timed_out,
              "seconds": round(time.monotonic() - start, 2), "log": str(log)}
    print(f"{'PASS' if code == 0 else 'FAIL'} {path.name} ({result['seconds']}s)", flush=True)
    if code:
        print("\n".join(log.read_text(errors="replace").splitlines()[-30:]))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quick", action="store_true", help="syntax + checksums only")
    parser.add_argument("--suite", action="append", default=[], help="test name, e.g. menu-update (repeatable)")
    parser.add_argument("--timeout", type=int, default=120, help="seconds per suite")
    parser.add_argument("--log-dir", type=Path, default=ROOT / ".test-results")
    args = parser.parse_args()
    if args.timeout <= 0 or (args.quick and args.suite):
        parser.error("timeout must be positive; --quick and --suite are mutually exclusive")
    all_tests = sorted(p for p in (ROOT / "tests").glob("test-*") if p.suffix in (".sh", ".py"))
    known = {p.stem.removeprefix("test-"): p for p in all_tests}
    if any(name not in known for name in args.suite):
        parser.error("unknown suite; choose: " + ", ".join(known))
    tests = [known[name] for name in dict.fromkeys(args.suite)] if args.suite else all_tests
    if not args.quick and os.geteuid() == 0:
        parser.error("Run tests as a normal user, never sudo: some suites exercise the non-root installer path")
    deps = ["bash"] if args.quick else ["bash", "jq", "curl", "tar", "diff"]
    missing = [name for name in deps if not shutil.which(name)]
    if missing:
        parser.error("Missing dependencies (nothing installed automatically): " + ", ".join(missing))
    syntax_checks()
    checksum_check()
    if args.quick:
        return 0
    args.log_dir.mkdir(parents=True, exist_ok=True)
    results = [run_suite(path, args.timeout, args.log_dir.resolve()) for path in tests]
    report = args.log_dir / "summary.json"
    report.write_text(json.dumps(results, indent=2) + "\n")
    passed = sum(r["exit_code"] == 0 for r in results)
    print(f"{passed}/{len(results)} suites passed; report: {report}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError, SyntaxError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
