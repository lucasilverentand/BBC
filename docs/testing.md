# Testing without an iMessage account

You can test BBC without signing into Messages, granting Full Disk Access or changing host protections. The portable SDK tests run on Linux or macOS. The native app and bridge fixture suites need a Mac toolchain, but do not need an Apple account or a configured messaging host.

## Portable SDK and test runner

Install Swift 6+, Python 3 and SQLite development headers (`libsqlite3-dev` on Ubuntu), then run from the repository root:

```sh
python3 -m unittest discover -s script -p 'test_*.py'
python3 script/test_swift.py .
```

The SDK suite starts disposable Python HTTP servers on ephemeral loopback ports. It checks authentication, route selection, exact reply identities, persisted operation UUIDs, upload bytes, rejection before dispatch, redirect refusal and failure handling without automatic mutation retries. Fixture requests contain invented values and never reach Messages. These tests need permission to bind and connect to loopback sockets; no external HTTP service is required.

On macOS, the same package also tests the local stdio adapter with temporary fake executables. Linux excludes that adapter because the production implementation is macOS-only. Linux passing therefore establishes the HTTP SDK contract, not the behavior of the Mac app.

`script/test_swift.py` fails when a successful build executes no tests or falls below `--min-tests N`. CI sets a separate floor for each package/platform. A partial run below its floor fails immediately; it is never rerun to mask missing tests. On Apple toolchains that build XCTest bundles without executing them, the fallback runs bundles from the current build directory and enforces the floor across them. A nonzero subprocess exit always fails, even if the output includes passing tests.

Use `--configuration release` to exercise optimized code; the default is `debug`. XCTest fallback resolves the same configuration's output directory. The native CI lane runs optimized SDK, bridge and app suites alongside the unsigned release build, while the transport lane retains debug SDK coverage.

`BBC_TEST_TIMEOUT_SECONDS` sets one overall deadline for the run, including build-output lookup and XCTest fallback; the default is 900 seconds. The runner terminates its owned process group on timeout and escalates to SIGKILL after a short grace period. Use `--log path/to/output.log` to retain test output. CI uploads test logs on failure. Python regressions check floors, fallback selection, process cleanup, nonzero exits, invalid deadlines and log capture.

If a local Apple toolchain hangs in its default Swift Build engine, select SwiftPM's native engine explicitly: `BBC_SWIFT_BUILD_SYSTEM=native python3 script/test_swift.py .`. The override also applies to either native package below. The native engine is deprecated in newer toolchains, so use this only as a local workaround.

## Native fixture suites

With the Xcode version required by [setup](setup.md), run:

```sh
python3 script/test_swift.py NativeBridge
bash script/prepare_native.sh
python3 script/test_swift.py NativeMessages
```

The native tests use synthetic Objective-C objects, temporary databases and stores, fake bridge peers, and injected actions. Loopback listeners request OS-assigned ports. Fixture readiness, socket reads, HTTP peer teardown and movie-writer waits have watchdogs; blocked loopback access fails with diagnostics rather than skipping coverage. Native message-load and scan deadlines are shortened through fixture seams while production defaults stay at five and ten seconds. Broker tests use explicit transaction IDs and protocol barriers to check command counts, rejection ownership and late results. See [native bridge architecture](native-bridge.md) for that boundary. Do not start the app, run native-access diagnostics, or connect a bridge merely to run fixture tests. Build and packaging validation in CI is separate from runtime messaging.

## Worker and receipt contracts

The operational-log persistence fixture uses atomic writes without device-lock protection so synthetic files remain readable when the host keybag is unavailable. Production retains its `completeFileProtectionUnlessOpen` default; the fixture does not verify device-lock behavior or change any host protection.

Worker tests must inject database, bridge and lock paths beneath a temporary root, plus fake startup/permission/script actions for the legacy RPC worker. Never override HOME or run the live script executor in a fixture. Classify proven pre-dispatch errors as non-dispatched; once script execution begins or forwarding may have occurred, retain uncertainty until exact native/database confirmation is established. Confirmation polling must never redispatch.

Router tests cover pending requests, operation ownership and replay after reopening stores. Atomic replacement and process-restart safety do not establish power-loss durability. A receipt-write failure after dispatch must preserve the observed result while the surviving intent blocks replay.

## CI and acceptance

The `portable-linux` job runs the HTTP SDK and test-runner regressions in a Swift Linux container. The `transport` job runs SDK and stdio fixture tests on macOS. The `native` job uses the reviewed hosted Xcode 27.2 selection to build optimized arm64 code with system SQLite, run all three optimized fixture suites, check the bridge ABI, preserve the Icon Composer source, and collect binary and icon evidence. [Release tooling](releases.md) validates the exact compiler build and path; a changed image cannot silently select a different compiler.

Synthetic tests cannot establish Apple's private-API compatibility, live reaction ownership, recipient-visible previews or delivery. Those remain separate, explicitly authorized acceptance checks on a configured host. Preserve exact identities and saved receipts during acceptance; an uncertain native mutation must not be retried automatically.

## Local verification record

On 2026-11-04 clean rebuilds of all three Swift packages passed on macOS: 24 SDK tests, 29 native bridge fixture tests, 164 app tests and 16 Python runner checks. The app total includes one intentional skip, `testPreparedParakeetTranscribesSyntheticSpeechLocally`, which requires separately staged public model files. No model download is part of normal fixture testing. The bridge build retained arm64, arm64e and x86_64 slices targeting Mac Catalyst.

On 2026-11-05 [hosted CI at `4ae0b36`](https://github.com/lucasilverentand/BBC/actions/runs/42021393933) passed 16 HTTP SDK tests on Linux, 25 SDK tests on macOS, 34 bridge tests and 169 app tests with the same intentional skip. Those suites ran in debug configuration. The hosted Xcode 26.6 experiment passed the SDK suite but could not compile the accepted Icon Composer document; that lane was retired in favor of the verified hosted `xcode-27` image. Optimized suites are a separate gate in the current workflow. Local runner checks now pass 17 tests, including release-configuration fallback selection.

Local development builds may still report Homebrew SQLite deployment-target warnings. Distribution builds use system SQLite and reject machine-specific dylib paths; debug fixture success alone does not establish portability of a locally linked library.

On 2026-11-05 the combined unsigned validation script also passed locally with final Xcode 27.2 build 27B52: 25 SDK, 34 bridge and 169 app tests in release configuration, with the same single intentional skip, plus 17 Python runner checks and both 16-test Ruby suites. Its optimized executable is arm64 with minimum macOS 26.0; bridge slices retain the Mac Catalyst 26.0 minimum. This local result still needs the corresponding hosted run.
