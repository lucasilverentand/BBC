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

`script/test_swift.py` fails when a successful build executes no tests. On Apple toolchains that build XCTest bundles without executing them, it runs bundles from the current build directory and checks that those runs execute tests too. The Python runner tests guard against a false green result.

If a local Apple toolchain hangs in its default Swift Build engine, select SwiftPM's native engine explicitly: `BBC_SWIFT_BUILD_SYSTEM=native python3 script/test_swift.py .`. The override also applies to either native package below. The native engine is deprecated in newer toolchains, so use this only as a local workaround.

## Native fixture suites

With the Xcode version required by [setup](setup.md), run:

```sh
python3 script/test_swift.py NativeBridge
bash script/prepare_native.sh
python3 script/test_swift.py NativeMessages
```

The native tests use synthetic Objective-C objects, temporary databases and stores, fake bridge peers, and injected actions. See [native bridge architecture](native-bridge.md) for that boundary. Do not start the app, run native-access diagnostics, or connect a bridge merely to run fixture tests. Build and packaging validation in CI is separate from runtime messaging.

## CI and acceptance

The `portable-linux` job runs the HTTP SDK and test-runner regressions in a Swift Linux container. The `transport` job runs SDK and stdio fixture tests on macOS. The `native` job builds the application and embedded bridge, checks the bridge ABI, and runs native fixture tests. The native lane requires the runner and Xcode installation named in the workflow; the portable lane has no dependency on that machine.

Synthetic tests cannot establish Apple's private-API compatibility, live reaction ownership, recipient-visible previews or delivery. Those remain separate, explicitly authorized acceptance checks on a configured host. Preserve exact identities and saved receipts during acceptance; an uncertain native mutation must not be retried automatically.
