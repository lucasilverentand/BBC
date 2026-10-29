#!/usr/bin/env python3
"""Run SwiftPM tests and execute XCTest bundles when SwiftPM reports zero."""
from pathlib import Path
import os
import re
import subprocess
import sys


def main():
    package = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    command = ["swift", "test", "--package-path", str(package), "--disable-sandbox", "--jobs", "2"]
    environment = os.environ.copy()
    cache = str(package / ".build" / "module-cache")
    environment.setdefault("CLANG_MODULE_CACHE_PATH", cache)
    environment.setdefault("SWIFTPM_MODULECACHE_OVERRIDE", cache)
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=environment)
    lines = []
    for line in process.stdout:
        print(line, end="", flush=True)
        lines.append(line)
    if process.wait():
        raise SystemExit(process.returncode)
    counts = re.findall(r"Executed (\d+) tests?", "".join(lines))
    if counts and max(map(int, counts)) > 0:
        return
    bundles = sorted({p.resolve() for p in (package / ".build").rglob("*.xctest") if p.is_dir()})
    if not bundles:
        raise SystemExit("SwiftPM reported no XCTest execution and produced no XCTest bundle")
    for bundle in bundles:
        print(f"SwiftPM did not execute XCTest; running {bundle.name}", flush=True)
        subprocess.run(["xcrun", "xctest", str(bundle)], check=True)


if __name__ == "__main__":
    main()
