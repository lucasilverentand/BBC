#!/usr/bin/env python3
"""Run SwiftPM tests, rejecting green builds that execute fewer tests than expected."""
from pathlib import Path
import argparse
import math
import time
import os
import re
import signal
import subprocess
import sys
import threading

DEFAULT_TIMEOUT_SECONDS = 900
TERMINATE_GRACE_SECONDS = 1


def executed_count(output):
    """Largest XCTest or Swift Testing executed-test count; build-only output is zero."""
    counts = re.findall(r"Executed (\d+) tests?\b", output)
    counts += re.findall(r"Test run with (\d+) tests?\b.*passed", output)
    return max(map(int, counts), default=0)


def executed_tests(output):
    return executed_count(output) > 0


def timeout_seconds(environment=os.environ):
    raw = environment.get("BBC_TEST_TIMEOUT_SECONDS", str(DEFAULT_TIMEOUT_SECONDS))
    try:
        value = float(raw)
    except ValueError:
        raise SystemExit(f"BBC_TEST_TIMEOUT_SECONDS must be a positive number, got {raw!r}")
    if not math.isfinite(value) or value <= 0:
        raise SystemExit(f"BBC_TEST_TIMEOUT_SECONDS must be a positive number, got {raw!r}")
    return value


def remaining_seconds(environment):
    limit = timeout_seconds(environment)
    if "_BBC_TEST_DEADLINE" in environment:
        limit = min(limit, float(environment["_BBC_TEST_DEADLINE"]) - time.monotonic())
    if limit <= 0:
        raise SystemExit("Overall test deadline expired")
    return limit


def terminate_group(process):
    """Reap the leader and stop descendants even if the leader exits first."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        process.wait()
        return
    deadline = time.monotonic() + TERMINATE_GRACE_SECONDS
    while time.monotonic() < deadline:
        process.poll()
        time.sleep(0.02)
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=TERMINATE_GRACE_SECONDS)


def stream(command, environment, log=None, echo=True):
    limit = remaining_seconds(environment)
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, env=environment, start_new_session=True)
    lines = []

    def pump():
        for line in process.stdout:
            if echo:
                print(line, end="", flush=True)
            lines.append(line)
            if log:
                log.write(line)
                log.flush()

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    try:
        process.wait(timeout=limit)
    except subprocess.TimeoutExpired:
        terminate_group(process)
        reader.join(timeout=5)
        process.stdout.close()
        raise SystemExit(f"Test command timed out after {limit:g} seconds: {' '.join(command[:2])}")
    except BaseException:
        terminate_group(process)
        raise
    reader.join(timeout=1)
    if reader.is_alive():
        terminate_group(process)
        reader.join(timeout=1)
        if reader.is_alive():
            raise SystemExit("Test output remained open after child cleanup")
    process.stdout.close()
    if process.returncode:
        terminate_group(process)
        raise SystemExit(process.returncode)
    return "".join(lines)


def build_output(command, environment):
    return stream(command, environment, echo=False)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("package", nargs="?", default=".")
    parser.add_argument("--min-tests", type=int, default=1)
    parser.add_argument("--log", help="append complete test output to this file")
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)
    minimum = max(args.min_tests, 1)
    package = Path(args.package).resolve()
    build_options = ["--build-system", os.environ["BBC_SWIFT_BUILD_SYSTEM"]] if os.environ.get("BBC_SWIFT_BUILD_SYSTEM") else []
    command = ["swift", "test", *build_options, "--package-path", str(package), "--disable-sandbox", "--jobs", "2"]
    environment = os.environ.copy()
    environment["_BBC_TEST_DEADLINE"] = str(time.monotonic() + timeout_seconds(environment))
    cache = str(package / ".build" / "module-cache")
    environment.setdefault("CLANG_MODULE_CACHE_PATH", cache)
    environment.setdefault("SWIFTPM_MODULECACHE_OVERRIDE", cache)
    log = None
    if args.log:
        Path(args.log).parent.mkdir(parents=True, exist_ok=True)
        log = open(args.log, "a", encoding="utf-8")
    try:
        run = (lambda cmd: stream(cmd, environment, log)) if log else (lambda cmd: stream(cmd, environment))
        count = executed_count(run(command))
        if count >= minimum:
            return
        if count > 0 or sys.platform != "darwin":
            raise SystemExit(f"SwiftPM succeeded but executed {count} tests; expected at least {minimum}"
                             if count else "SwiftPM succeeded but executed no tests")
        # Some Apple toolchains build XCTest bundles without running them. Resolve
        # only this build's output directory, excluding stale release/architecture bundles.
        output = build_output(
            ["swift", "build", *build_options, "--package-path", str(package), "--show-bin-path"],
            environment)
        bundles = sorted(Path(output.strip()).glob("*.xctest"))
        if not bundles:
            raise SystemExit("SwiftPM reported no test execution and produced no XCTest bundle")
        total = 0
        for bundle in bundles:
            print(f"SwiftPM did not execute XCTest; running {bundle.name}", flush=True)
            bundle_count = executed_count(run(["xcrun", "xctest", str(bundle)]))
            if not bundle_count:
                raise SystemExit(f"XCTest bundle executed no tests: {bundle.name}")
            total += bundle_count
        if total < minimum:
            raise SystemExit(f"XCTest bundles executed {total} tests; expected at least {minimum}")
    finally:
        if log:
            log.close()


if __name__ == "__main__":
    main()
