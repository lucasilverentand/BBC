# Native messaging bridge

BBC remains one local Mac app with its Swift HTTP API and keys. Runtime messaging uses native calls without mouse clicks, picker navigation or composer manipulation. There is no UI-automation fallback.

The library, broker and messaging adapter are BBC's own implementation. [Research provenance](development/native-api-research.md) is kept separately from operator instructions.

The embedded library targets Messages' Mac Catalyst runtime, with arm64, arm64e and x86_64 slices. The Swift host remains a macOS app. Building the library for ordinary macOS/arm64 can leave it unloaded even when host requirements pass; CI checks the produced library's platform and CPU slices. A connected, authenticated session is still required before advertising native readiness.

The Swift app brokers authenticated loopback IPC to BBC's own embedded library in the signed-in user's Messages process. Separate random credentials authenticate the embedded library and request workers. Worker credentials stay in a private local descriptor; the library credential is supplied only to its launch. Commands are bounded, correlated by UUID and dispatched once. A lost response remains uncertain.

The embedded library waits for Messages' main queue before opening its socket, then performs blocking network work on a background queue. Creating the socket directly from the loader constructor can lose the descriptor during early app startup, after authentication but before readiness is announced.

The library resolves exact native chats and messages and verifies selector signatures before invocation. Native acknowledgements are separate from exact database confirmation. Custom emoji retain their full Unicode sequence. Replies use native thread identities. Read and typing operations call native methods without opening a conversation or creating a draft. Existing background text/media sends and exact attachment reads remain available independently.

An older message may be absent from Messages' in-memory cache. For Tapbacks, BBC requests native history loading once with a nonzero window and observes the exact message for up to five seconds before dispatch. It never opens the conversation to populate that cache. Other actions retain their existing synchronous lookup. Tapback preparation resolves balloon references through the same verified database chat, including when the optional balloon column is present. Database-column expressions are qualified with the query's message alias.

Typing sessions use UUID leases with a deadline of at most 30 seconds. An old stop request cannot clear a newer lease, and the embedded session clears its own leases on disconnect. Native mutations use BBC-created message GUIDs for database confirmation. Late results cannot cause another send.

The pinned Beeper dependency supplies only the attributed-body decoder and its database utilities. BBC does not build or use its Accessibility controller. `NativeBridge` has synthetic Objective-C fixtures; the Swift IPC tests use a fake native peer. Neither suite opens Messages or sends a real message.

## Host setup

Follow [BBC's setup guide](setup.md#native-messaging) for building, permissions, Recovery steps, library validation, verification and rollback.

BBC's current bridge requires disabled SIP and disabled library validation. BBC reports those settings and never changes them. Unknown or partial configuration is treated as unavailable.

Select **Start native bridge** in BBC. It asks Messages to quit gracefully, then launches it with BBC's embedded library and a fresh authenticated session. A refused or timed-out quit aborts startup without force-killing Messages. **Stop native bridge** closes the connection and clears its owned typing leases; Messages remains open. The separate startup toggle opts into repeating this setup when BBC opens.

`GET /v1/status` reports `native_bridge_ready` and `native_bridge.capabilities`. A connected bridge can still lack individual methods on a particular macOS version. Unsupported selectors fail before a send whenever possible; uncertainty after dispatch is retained in the operation receipt.

## Verification boundary

Builds, synthetic native fixtures and fake-peer IPC tests do not establish live compatibility with Apple's private APIs. Live validation requires a configured host. Verify BBC's exact native message identities, local state and saved receipts; do not treat a callback or elapsed timer as confirmation. For the first custom-emoji check, use one fixed emoji for add/remove and reconcile each operation before another mutation.

[SIP-enabled Tapback research](development/sip-enabled-tapbacks.md) records the standalone-client experiment and public API checks. No SIP-on custom-emoji sending path is verified. A standalone daemon entitlement rejection is separate from the injected bridge's host checks; removing those checks would not establish access.
