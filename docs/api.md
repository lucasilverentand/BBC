# API

Start the API in the Mac app. All routes require `Authorization: Bearer <API key>`. Create and revoke keys in the app; the API cannot mint keys. The default base URL is `http://127.0.0.1:7861`.

Every mutation requires an `Idempotency-Key` header containing a UUID chosen and saved by the client before dispatch. Retrying the same UUID and body returns the saved receipt. A changed body returns HTTP 409. An interrupted operation remains uncertain and is never automatically dispatched again. Use `GET /v1/operations/<uuid>` with the same API key to retrieve its retained outcome. Do not create a new UUID merely because the original response was lost.

## Endpoints

| Route | Body / result |
| --- | --- |
| `GET /v1/status` | Observed permissions and available methods |
| `POST /v1/messages` | `to`, `text`; always iMessage, SMS fallback disabled |
| `POST /v1/messages/after` | `since_rowid`, `limit` (1–200); incremental messages and `next_rowid` |
| `POST /v1/messages/status` | `chat_guid`, `message_guid`; observed local sent/delivered/read flags |
| `POST /v1/replies` | `chat_guid`, `message_guid`, `text`, `read_guids` |
| `POST /v1/tapbacks` | `chat_guid`, `message_guid`, `reaction`, optional `remove` |
| `POST /v1/read` | `chat_guid`, `message_guid`, `read_guids` |
| `POST /v1/read/status` | Same exact target and `read_guids`; observation only |
| `POST /v1/typing/start` | `chat_guid`, `message_guid`, `read_guids`, optional `typing_id` UUID |
| `POST /v1/typing/stop` | `typing_id` from start |
| `POST /v1/media/visual` | `chat_guid`, `message_guid`, `attachment_guid` |
| `POST /v1/media/transcribe` | Same attachment target; needs staged local models |
| `GET /v1/operations/<uuid>` | Receipt for that API key and operation UUID |

Status, message pages/status, read status and media preparation do not require an idempotency key. Requests accept at most 64 KB; responses are bounded at 2 MB. HTTP connections serve one request and close. The listener accepts at most 32 simultaneous connections.

## Sending

This sends a real message through the signed-in local account:

```sh
curl http://127.0.0.1:7861/v1/messages \
  -H "Authorization: Bearer $BBC_API_KEY" \
  -H "Idempotency-Key: $OPERATION_UUID" \
  -H 'Content-Type: application/json' \
  -d '{"to":"person@example.com","text":"Hello from Blue Bubble Club"}'
```

## Threading

A message page preserves `guid`, `chat_guid`, `reply_to_guid` and `thread_root_guid` separately. Apple's native thread originator identifies the reply root; it does not always expose an immediate parent reply. Top-level messages use their own GUID as `thread_root_guid`. Do not infer a thread from the latest message, matching text or another conversation with the same person.

Reply with the exact message GUID and chat GUID. The native adapter resolves and confirms the thread root and returns it as `thread_root_guid`, together with the new message `guid`. Existing drafts and ambiguous selections reject the action. `read_guids` must cover the conversation's current unread messages before an action can implicitly mark them read. A new unread message that was not consumed causes rejection.

## Tapbacks and read state

Tapback names are `love`, `like`, `dislike`, `laugh`, `emphasis` and `question`. The target is an exact UUID message in a verified direct iMessage chat. Setting an already present reaction is a no-op; the helper never repeats a button press to recover missing confirmation.

Read opens one verified message in its owned Messages process, then observes the local database. Apple may mark the conversation read as a side effect. A local read confirmation is not proof that the sender saw Apple's Read receipt. `messages.status` reports only the database flags the Mac actually observed; unknown remote visibility must stay unknown.

## Typing

Start returns an accepted session UUID promptly. A session lasts at most 30 seconds. Stop requests cancellation and cleanup of that session's own placeholder. Retrieve the start operation's receipt to see the eventual native result. An accepted start is not confirmation that the recipient saw typing, and a stop request is not proof of placeholder cleanup. Native failure receipts retain uncertainty. Starting another session while automation is owned can fail busy.

## Operation receipts and custody

Local records live in `~/Library/Application Support/Blue Bubble Club` with private directory/file permissions. Keys are stored as SHA-256 hashes of 256-bit random secrets; operation records retain request fingerprints and receipts. Uncertain records deliberately survive restarts. There is no automatic expiry or replay of retained operations.

The operator owns network exposure. The app offers loopback or other-device binding, without creating tunnels or opening router ports. Use a private trusted network or put your own HTTPS endpoint in front of the app. Keys grant access to the signed-in account's supported messaging features. Revoking a key blocks new calls; already dispatched effects may finish.
