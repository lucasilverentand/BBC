# Reliability review and next tests

This review covers BBC's synthetic test coverage and failure handling on 2026-11-04. Claude reviewed native and receipt paths; Codex implemented and tested the changes below. It does not establish live compatibility with Apple's private APIs or complete outstanding delivery acceptance. Contributor commands and test boundaries are in [testing](../testing.md).

## Implemented regression coverage

- HTTP SDK requests run against disposable loopback servers: authentication, endpoint routing, operation identities, upload bytes, redirects, failures and no automatic mutation retry. Linux has a dedicated CI job; macOS also exercises the local stdio adapter.
- The test runner rejects successful builds that execute no tests and limits its Apple XCTest fallback to the current build output. Python regression tests cover its success and failure behavior.
- Native link scans have a bounded deadline before the broker timeout. A late or repeated callback cannot send after a non-dispatched timeout receipt. Synthetic tests cover missing callbacks and a delayed main queue.
- Multipart effects and selector availability are checked before registering transfers. Synthetic tests assert zero transfer creation for rejected effects.
- Reply validation accepts the documented `reply_to` alias and rejects conflicting native message identities.
- Local typing validation happens before an operation intent is reserved. Invalid identities do not create a misleading uncertain receipt.
- If receipt storage fails after dispatch, the API returns the observed result rather than a misleading rejected-request response. A fault-injection test moves the temporary store during dispatch, restores it, and verifies that the surviving intent prevents replay.
- Sol and Opus endorsed a focused [implementation plan](test-suite-plan.md). Sonnet agents at low effort implemented its packages, with moderator integration and final suite verification.
- Native worker request/result seams now use explicit database, bridge, lock and confirmation dependencies. Synthetic reply and Tapback tests require exact database confirmation, reject wrong identities, and count zero or one forwarded command without redispatch.
- The legacy RPC worker uses injected startup, permission and script actions. Proven pre-script failures are non-dispatched; post-entry failures remain uncertain. Fixtures never execute AppleScript.
- Broker deadlines and limits are injectable with unchanged production defaults. Tests cover pending UUID ownership, duplicate status IDs, actual late results, duplicate results, helper replacement rejection, capacity, unauthenticated idle expiry, malformed frames and reply kinds. Shutdown checks endpoint ownership before removal.
- Router tests cover concurrent identical requests, conflicts, key isolation, corrupt/truncated records, intent-write failures, file permissions and replay after reopening both stores and routers. Typing tests follow accepted requests through completion and cancellation.
- SDK tests cover all current routes and binary uploads, redirects and disconnects. HTTP peers publish ports atomically and capture bounded startup diagnostics; teardown is confirmed before files are deleted. Native listeners use ephemeral ports and fixture waits are bounded.
- The runner enforces an overall deadline and minimum test counts, rejects nonzero exits regardless of positive output, and terminates owned process groups. Partial execution below the floor fails without re-executing the suite.

## Proposed follow-up work

These are remaining engineering proposals, not accepted runtime operations or claims of completed fixes.

### Durable receipts and failure classification

The API router writes operation files atomically, but does not explicitly flush the file and parent directory. Define the crash/power-loss durability guarantee, then implement and test a shared durable store for mutation intents and receipts. Test failed writes before dispatch, after dispatch, and after rename. Keep reconciliation mandatory when the observed outcome cannot be established.

### Worker integration without a configured host

Reply and Tapback orchestration now have fixture coverage, and legacy text sends have injected native actions. Extend these seams to advanced actions, media staging and typing sessions when adding behavior there. Preserve exact native/database identities and the rule that confirmation polling never dispatches again. Do not rely on overriding HOME.

Extract reusable request validation and receipt classification into a Foundation-only target when that enables actual Linux regression coverage. The UI and private Objective-C bridge remain Mac-only.

### Bridge lifecycle

Broker timeout, ownership, capacity and reply-kind cases now have synthetic regression tests. Authenticated workers that never call remain a separate lifecycle policy decision; the current change preserves production idle behavior.

EmbeddedSession's typing lease table is outside the current NativeBridge SwiftPM target. Extract its state transitions behind an injected native action and test replacement leases, stale stop requests, deadline expiry and disconnect cleanup. Starting lease B followed by stopping A must leave B active.

### Media cleanup

Preflight reduces avoidable transfer registrations, but failures during registration, message construction or an effect setter can still leave native transfers. Swift handoff cleanup also needs explicit coverage for a confirmed non-dispatched failure. Add rollback where the native API supports it; retain files needed by an uncertain dispatched transfer. Use fixture transfer counters and temporary files to establish ownership and cleanup without loading Messages.

## Acceptance boundary

An unconfigured Mac can run the native fixture suites; Linux can run the portable HTTP SDK and runner checks. Neither proves recipient delivery, live reaction ownership, preview rendering or compatibility across macOS private-API versions. Keep those checks separately authorized and recorded with exact message identities and durable receipts. Tests and builds must never change SIP, library validation or signing policy.
