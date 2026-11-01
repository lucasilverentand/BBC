# Native messaging bridge

BBC remains one local Mac app with its Swift HTTP API and keys. Runtime messaging uses native calls without mouse clicks, picker navigation or composer manipulation. There is no UI-automation fallback.

The bridge is an original BBC implementation. [BlueBubbles Server](https://github.com/BlueBubblesApp/bluebubbles-server) and its [helper](https://github.com/BlueBubblesApp/bluebubbles-helper) are references for how Messages' private APIs can be used. Their source or helper binaries are not bundled. Research revisions: server `76d2b2e786c04d7516de089f31be978a68da8083`; helper `1ee57f3fde63f8cc5769d60cfabfe9a06fcc1069`.

The Swift app brokers authenticated loopback IPC to BBC's own embedded library in the signed-in user's Messages process. Separate random credentials authenticate the embedded library and request workers. Worker credentials stay in a private local descriptor; the library credential is supplied only to its launch. Commands are bounded, correlated by UUID and dispatched once. A lost response remains uncertain.

The library resolves exact native chats and messages and verifies selector signatures before invocation. Native acknowledgements are separate from exact database confirmation. Custom emoji retain their full Unicode sequence. Replies use native thread identities. Read and typing operations call native methods without opening a conversation or creating a draft. Existing background text/media sends and exact attachment reads remain available independently.

Typing sessions use UUID leases with a deadline of at most 30 seconds. An old stop request cannot clear a newer lease, and the embedded session clears its own leases on disconnect. Native mutations use BBC-created message GUIDs for database confirmation. Late results cannot cause another send.

The pinned Beeper dependency supplies only the attributed-body decoder and its database utilities. BBC does not build or use its Accessibility controller. `NativeBridge` has synthetic Objective-C fixtures; the Swift IPC tests use a fake native peer. Neither suite opens Messages or sends a real message.

## Host setup

Use a Mac signed into Messages. Build the app and complete its Full Disk Access and Messages Automation checklist. These permissions support database access and background text/media sending; Accessibility permission is no longer needed.

Loading the native library requires disabled SIP and disabled library validation. [BlueBubbles documents these host requirements](https://docs.bluebubbles.app/private-api/installation). Configure a host deliberately before enabling this feature. BBC reports the settings and never changes them. Unknown or partial configuration is treated as unavailable.

Select **Start native bridge** in BBC. It asks Messages to quit gracefully, then launches it with BBC's embedded library and a fresh authenticated session. A refused or timed-out quit aborts startup without force-killing Messages. **Stop native bridge** closes the connection and clears its owned typing leases; Messages remains open. The separate startup toggle opts into repeating this setup when BBC opens.

`GET /v1/status` reports `native_bridge_ready` and `native_bridge.capabilities`. A connected bridge can still lack individual methods on a particular macOS version. Unsupported selectors fail before a send whenever possible; uncertainty after dispatch is retained in the operation receipt.

## Verification boundary

Builds, synthetic native fixtures and fake-peer IPC tests do not establish live compatibility with Apple's private APIs. Live validation requires a configured host. Verify BBC's exact native message identities, local state and saved receipts; do not treat a callback or elapsed timer as confirmation. For the first custom-emoji check, use one fixed emoji for add/remove and reconcile each operation before another mutation.
