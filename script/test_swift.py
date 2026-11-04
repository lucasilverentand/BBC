#!/usr/bin/env python3
"""Run SwiftPM tests, rejecting green builds that execute no tests."""
from pathlib import Path
import os
import re
import subprocess
import sys


def executed_tests(output):
    """Accept XCTest and Swift Testing summaries, never build-only output."""
    counts = re.findall(r"Executed (\d+) tests?\b", output)
    counts += re.findall(r"Test run with (\d+) tests?\b.*passed", output)
    return bool(counts) and max(map(int, counts)) > 0


def stream(command, environment):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, env=environment)
    lines = []
    for line in process.stdout:
        print(line, end="", flush=True)
        lines.append(line)
    if process.wait():
        raise SystemExit(process.returncode)
    return "".join(lines)


def main():
    package = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    build_options = ["--build-system", os.environ["BBC_SWIFT_BUILD_SYSTEM"]] if os.environ.get("BBC_SWIFT_BUILD_SYSTEM") else []
    command = ["swift", "test", *build_options, "--package-path", str(package), "--disable-sandbox", "--jobs", "2"]
    environment = os.environ.copy()
    cache = str(package / ".build" / "module-cache")
    environment.setdefault("CLANG_MODULE_CACHE_PATH", cache)
    environment.setdefault("SWIFTPM_MODULECACHE_OVERRIDE", cache)
    if executed_tests(stream(command, environment)):
        return
    if sys.platform != "darwin":
        raise SystemExit("SwiftPM succeeded but executed no tests")
    # Some Apple toolchains build XCTest bundles without running them. Resolve
    # only this build's output directory, excluding stale release/architecture bundles.
    output = subprocess.check_output(
        ["swift", "build", *build_options, "--package-path", str(package), "--show-bin-path"],
        text=True, env=environment)
    build_path = Path(output.strip())
    bundles = sorted(build_path.glob("*.xctest"))
    if not bundles:
        raise SystemExit("SwiftPM reported no test execution and produced no XCTest bundle")
    for bundle in bundles:
        print(f"SwiftPM did not execute XCTest; running {bundle.name}", flush=True)
        if not executed_tests(stream(["xcrun", "xctest", str(bundle)], environment)):
            raise SystemExit(f"XCTest bundle executed no tests: {bundle.name}")


if __name__ == "__main__":
    main()
