# Native adapter development

`script/prepare_native.sh` prepares the pinned iMessage adapter and builds BBC. Adapter changes belong in `NativeMessages/beeper-bbc.patch`; the cache must match that patch exactly.

After editing the prepared adapter from the repository root:

```sh
git -C build/beeper-imessage diff > NativeMessages/beeper-bbc.patch
git -C build/beeper-imessage apply --reverse --check "$PWD/NativeMessages/beeper-bbc.patch"
git diff --check
```

For a new adapter file, mark it with `git add -N` inside that cache before generating the patch. Full validation is defined in [.github/workflows/ci.yml](../.github/workflows/ci.yml).

## Picker debugging

Keep one emoji, chat and message throughout a reproduction. Record an operation UUID and its exact body before dispatch; reconcile uncertain results through exact-chat reads rather than issuing another toggle. A successful AX call, a rendered glyph or a writable selection attribute is not proof that a reaction was submitted.

Check the Mac's session before diagnosing UI code. A locked session can retain Accessibility permission while Messages exposes a window with no readable conversation controls. The `CGSSessionScreenIsLocked` flag and bounded `NativeMessagesUI` observations distinguish this condition from a picker failure. Wait for the operator to unlock the Mac before another live attempt.

The internal `BBC_TEST_FULL_EMOJI_PICKER` environment variable supports native diagnosis:

- `1` forces the full picker even when the same emoji becomes recent.
- `observe` prepares the exact picker and stops before activation. It deliberately returns a pre-dispatch failure and leaves that picker open for a native reproducer.
- Unset uses the normal API path.

`NativeEmojiPicker` logs expose fixed role/action information without message content, search terms or recipient identities. Confirm the resulting own-reaction event against the exact target, then test removal. Recipient-visible acceptance remains separate from local confirmation.

When installing a CI binary, verify the run's source revision and artifact digest, preserve bundle resources, and use the operator's existing development-signing identity. Revoke temporary API keys and stop the test listener when the live session ends.
