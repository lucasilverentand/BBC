# Incoming typing observation

On 2026-11-17 the installed IMCore runtime exposed read-only `IMChat.lastIncomingMessage`, `isLastMessageTypingIndicator`, `participants`, and `IMMessage.isTypingMessage`, `isCancelTypingMessage`, `isFromMe`, `sender`, `time` and `guid`, with `IMHandle.ID`. A metadata-only standalone probe loaded the framework and inspected Objective-C method signatures; it made no daemon connection or native mutation. That establishes ABI presence, not remote-device behavior.

BBC's embedded bridge uses its own scoped getter implementation. It does not swizzle methods or install another application's helper. Unsupported types, missing native identities, group chats or a sender mismatch fail closed. Incoming observation never dispatches a mutation or populates Messages' history cache. The public contract and verification limits are in [events and search](../events-and-search.md#incoming-typing-ephemeral).

Development provenance: [BlueBubbles' IMCore observations](https://github.com/BlueBubblesApp/bluebubbles-docs/blob/master/private-api/imcore-documentation.md) identify incoming typing-message getters and describe timing problems in callback interception. This informed the read-only getter investigation; it is not a runtime dependency or an operator prerequisite. BBC uses bounded sampling and an expiry derived from the native timestamp instead of installing those interception hooks.

Synthetic tests prove direction/sender/scope validation, cancellation, stale deadlines, non-renewal, ephemeral framing, authentication and exclusion from replay storage. Recipient-generated typing transitions still require acceptance on a configured host; selector presence alone must not be reported as that acceptance.

## Live acceptance follow-up

After #32 was installed on 2026-11-17, the authenticated gateway reported a ready native bridge and incoming-typing ABI capability, and a scoped SSE connection returned HTTP 200. During a fresh capture the operator confirmed typing briefly and clearing the draft; no typing frame arrived. That check did **not** establish working remote indication observation. Scoped, content-free native diagnostics were added to distinguish an idle native snapshot from lookup/signature/identity failure before repeating acceptance. Clients must retain fallback timing; the capability flag alone is not recipient-device proof.

## Live acceptance result

On 2026-11-17 a fresh, authenticated scoped SSE capture remained open while the operator confirmed typing for 3–5 seconds and clearing the draft without sending. The installed bridge was ready and native samples succeeded. After completing the diagnostics in #33/#34, a further five-minute capture included another operator-confirmed check: `available:true` and `has_incoming:true` remained present, while `current_indicator:false`, `typing_message:false`, `cancelled:false` and `from_me:false` remained unchanged. No start, stop or expiry event was emitted. The host could resolve the chat and its incoming message; these message getters did not expose the remote typing state in the controlled checks.

This does not prove that every IMCore observation path or remote device is incapable of exposing typing. It does establish that this implementation has **not** met live acceptance and must not advertise production support. `incoming_typing` is false; `incoming_typing_probe_available` separately describes getter-ABI availability for diagnostics. Consumers retain their text-based bounded continuation fallback. No messages were sent, read marks generated, UI input dispatched or host protections changed to perform these probes.

A future native notification or dedicated typing-state observation proposal needs its own exact chat/sender evidence and live start/cancel/expiry acceptance. Do not enable a production capability based only on method signatures, synthetic fixtures, or an open SSE connection. Do not use UI activation or composer automation to make the signal appear.
