# Incoming typing observation

On 2026-11-17 the installed IMCore runtime exposed read-only `IMChat.lastIncomingMessage`, `isLastMessageTypingIndicator`, `participants`, and `IMMessage.isTypingMessage`, `isCancelTypingMessage`, `isFromMe`, `sender`, `time` and `guid`, with `IMHandle.ID`. A metadata-only standalone probe loaded the framework and inspected Objective-C method signatures; it made no daemon connection or native mutation. That establishes ABI presence, not remote-device behavior.

BBC's embedded bridge uses its own scoped getter implementation. It does not swizzle methods or install another application's helper. Unsupported types, missing native identities, group chats or a sender mismatch fail closed. Incoming observation never dispatches a mutation or populates Messages' history cache. The public contract and verification limits are in [events and search](../events-and-search.md#incoming-typing-ephemeral).

Development provenance: [BlueBubbles' IMCore observations](https://github.com/BlueBubblesApp/bluebubbles-docs/blob/master/private-api/imcore-documentation.md) identify incoming typing-message getters and describe timing problems in callback interception. This informed the read-only getter investigation; it is not a runtime dependency or an operator prerequisite. BBC uses bounded sampling and an expiry derived from the native timestamp instead of installing those interception hooks.

Synthetic tests prove direction/sender/scope validation, cancellation, stale deadlines, non-renewal, ephemeral framing, authentication and exclusion from replay storage. Recipient-generated typing transitions still require acceptance on a configured host; selector presence alone must not be reported as that acceptance.
