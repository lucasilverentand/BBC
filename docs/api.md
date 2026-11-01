# API

The app's [access controls](api-access.md) can restrict client IP/CIDR ranges and give each key read-only or full access. Both key permissions and the account mode apply. Status reports `key_access`, `operating_mode` and the effective methods.

Start the API in the Mac app. All routes require `Authorization: Bearer <API key>`. Create and revoke keys in the app; the API cannot mint keys. The default base URL is `http://127.0.0.1:7861`.

Each macOS login selects Full API or [read-only/watch mode](operating-modes.md) in the app. Read-only mode permits observation and webhook configuration, rejects messaging mutations with HTTP 403 `readonly_mode`, and never starts the native bridge or scheduled sending. Status includes `operating_mode` and the allowed methods. Use distinct ports and keys for simultaneous logins.

Every mutation requires an `Idempotency-Key` header containing a UUID chosen and saved by the client before dispatch. Retrying the same UUID and body returns the saved receipt. A changed body returns HTTP 409. An interrupted operation remains uncertain and is never automatically dispatched again. Use `GET /v1/operations/<uuid>` with the same API key to retrieve its retained outcome. Do not create a new UUID merely because the original response was lost.

## Endpoints

| Route | Body / result |
| --- | --- |
| `GET /v1/status` | Observed permissions and available methods |
| `POST /v1/messages` | `to`, either `text` or uploaded `media_id`; always iMessage, SMS fallback disabled |
| `POST /v1/messages/after` | `since_rowid`, `limit` (1–200), optional exact `chat_guid`; incremental messages and `next_rowid` |
| `POST /v1/messages/status` | `chat_guid`, `message_guid`; observed local sent/delivered/read flags |
| `POST /v1/messages/search` | Text, conversation and date filters; [search guide](events-and-search.md) |
| `POST /v1/messages/edit`, `/v1/messages/unsend` | Exact owned message and part; [native features](native-features.md) |
| `POST /v1/messages/multipart` | Text, multiple uploaded media IDs and optional native effect |
| `POST /v1/availability` | `address`; observed iMessage availability |
| `POST /v1/groups/create`, `/add`, `/remove`, `/name`, `/photo`, `/leave` | Native group management; [native features](native-features.md) |
| `POST /v1/replies` | `chat_guid`, `message_guid`, `text`, `read_guids` |
| `POST /v1/links` | `chat_guid`, `message_guid`, `url`, `read_guids` |
| `POST /v1/media/upload` | Raw bytes, `X-BBC-Filename` header; returns `media_id` |
| `POST /v1/media/download` | `chat_guid`, `message_guid`, `attachment_guid`, optional `offset`, `length` |
| `POST /v1/tapbacks` | `chat_guid`, `message_guid`, `reaction`, optional `remove` |
| `POST /v1/read` | `chat_guid`, `message_guid`, `read_guids` |
| `POST /v1/read/status` | Same exact target and `read_guids`; observation only |
| `POST /v1/typing/start` | `chat_guid`, `message_guid`, `read_guids`, optional `typing_id` UUID |
| `POST /v1/typing/stop` | `typing_id` from start |
| `POST /v1/media/visual` | `chat_guid`, `message_guid`, `attachment_guid` |
| `POST /v1/media/transcribe` | Same attachment target; needs staged local models |
| `GET /v1/operations/<uuid>` | Receipt for that API key and operation UUID |
| `POST /v1/webhooks/register`, `/list`, `/remove` | Incoming messages and observed updates; [webhook guide](events-and-search.md) |
| `POST /v1/schedules/create`, `/update`, `/cancel`, `/get`, `/list` | Local scheduled sends; [scheduling guide](scheduling.md) |

Status, message pages/status/search, availability, read status, uploads, downloads, media preparation, webhook lists and schedule get/list do not require an idempotency key. JSON requests accept at most 64 KB; raw uploads accept 32 MiB; responses are bounded at 2 MB. HTTP connections serve one request and close. The listener accepts at most eight simultaneous connections.

## Native bridge

Start the native bridge in the Mac app after completing [host setup](native-bridge.md). Status reports `native_bridge_ready` and the bridge's observed capabilities. Advanced actions are unavailable while disconnected or when a required native selector is absent. There is no mouse, keyboard, Accessibility or composer fallback. Background text/media sending and read-only database operations remain independent of this bridge.

## Sending

This sends a real message through the signed-in local account:

```sh
curl http://127.0.0.1:7861/v1/messages \
  -H "Authorization: Bearer $BBC_API_KEY" \
  -H "Idempotency-Key: $OPERATION_UUID" \
  -H 'Content-Type: application/json' \
  -d '{"to":"person@example.com","text":"Hello from Blue Bubble Club"}'
```

## Photos, videos and audio

Upload original bytes, then send the returned opaque ID:

```sh
curl http://127.0.0.1:7861/v1/media/upload \
  -H "Authorization: Bearer $BBC_API_KEY" \
  -H 'X-BBC-Filename: photo.jpg' \
  -H 'Content-Type: application/octet-stream' --data-binary @photo.jpg
```

Send `{"to":"person@example.com","media_id":"<returned UUID>"}` to `/v1/messages` with a new operation UUID. Each send accepts one upload or text. Media uses a private temporary handoff so the background sender can access the file without changing the Messages composer. Messages may rewrite media metadata; downloads return its completed local representation. Handoffs have a separate 512 MiB limit and are removed after a completed copy into Messages storage. Later sends prune handoffs older than 24 hours only when Messages no longer references them; pending files remain within the quota. Audio is sent as a file attachment; BBC does not label it as a recorded voice note. Supported uploads: JPEG, PNG, GIF, HEIC/HEIF, WebP, TIFF; MOV, MP4/M4V; M4A, MP3, CAF, WAV, AIFF and AAC. BBC validates the local file before accepting it. Uploads expire after 24 hours, with a 512 MiB local quota; expired files are removed on the next upload. Successful receipts confirm an exact new sent attachment in the local database, not recipient delivery.

Request message pages with `attachments: true` to receive opaque attachment GUIDs, MIME types and byte counts; `is_audio_message` identifies native audio messages. `/v1/media/download` returns original bytes as `data_base64`, with `offset`, `next_offset`, `total_bytes` and `complete`. Request successive offsets until complete. Each chunk is at most 512 KiB; each attachment is at most 32 MiB. Downloads require the exact direct-chat/message/attachment tuple and a local file already available in Messages. Paths and remote download URLs are never accepted. Both sent and received attachments can be downloaded.

## Rich links

Send `{"chat_guid":"…","message_guid":"…","url":"https://example.com","read_guids":["…"]}` to `/v1/links` with an operation UUID. The anchor must be a message in the intended direct chat, and `read_guids` must cover its current unread messages. BBC creates a native message and requests Messages' link processing before one send. Messages generates the preview; `preview: "managed-by-messages"` does not guarantee the site supplies a card. Plain URL text can also be sent through `/v1/messages`.

Message pages include `links`: the URL and, when present in Apple’s rich-link payload, title, summary, site name and preview image/icon attachment GUIDs. `preview: false` means only a URL was detected in text. Metadata parsing makes no network requests. Download preview images through the attachment endpoint.

## Threading

A message page preserves `guid`, `chat_guid`, `reply_to_guid` and `thread_root_guid` separately. Apple's native thread originator identifies the reply root; it does not always expose an immediate parent reply. Top-level messages use their own GUID as `thread_root_guid`. Do not infer a thread from the latest message, matching text or another conversation with the same person.

Reply with the exact message GUID and chat GUID. The native adapter resolves the native thread identity, then confirms the new message against the database's thread root. The result includes `thread_root_guid` and the new message `guid`. An unavailable or ambiguous native part rejects the action. `read_guids` must cover the conversation's current unread messages before an action that may mark them read. A new unread message that was not consumed causes rejection.

## Tapbacks and read state

Tapbacks accept `love`, `like`, `dislike`, `laugh`, `emphasis`, `question`, or a single emoji such as `🎉` or `👩‍💻`. Set `remove: true` to remove your exact reaction, using the same `/v1/tapbacks` endpoint and a new operation UUID. The bridge sends an explicit native add/removal event, preserving the full emoji sequence, without searching a picker or toggling a button. Confirmation requires the exact new outgoing reaction GUID, target, native type and custom emoji in the local database. An absent database row is never treated as confirmed removal.

Reaction targets include Apple's balloon references; `reacted_to_guid` is the normalized UUID and `reacted_to_native_guid` preserves the original reference. Message pages expose custom emoji as `reaction_emoji` alongside native add/removal types. The current endpoint targets the first native message part in an exact verified direct chat; an ambiguous part rejects the action. Reusing an operation UUID returns its receipt without another native event.

Read marks the exact verified chat read through its native method, then confirms local database state. `read_guids` must cover its current unread set. A local read confirmation is not proof that the sender saw Apple's Read receipt. `messages.status` reports only the database flags the Mac actually observed.

## Typing

Start returns an accepted session UUID promptly. A session lasts at most 30 seconds and sets native typing state without creating a draft. Stop requests cancellation of that session's lease. The embedded bridge also expires owned leases and clears them when its connection closes. Retrieve the start operation's receipt to see the eventual native result and cleanup confirmation. An accepted start is not confirmation of native typing; a stop acknowledgement only confirms cancellation was requested. Native failure receipts retain uncertainty. Concurrent native operations can fail busy.

## Operation receipts and custody

Local records live in `~/Library/Application Support/Blue Bubble Club` with private directory/file permissions. Keys are stored as SHA-256 hashes of 256-bit random secrets; operation records retain request fingerprints and receipts. Uncertain records deliberately survive restarts. There is no automatic expiry or replay of retained operations.

The operator owns network exposure. The app offers loopback or other-device binding, without creating tunnels or opening router ports. Use a private trusted network or put your own HTTPS endpoint in front of the app. Keys grant access to the signed-in account's supported messaging features. Revoking a key blocks new calls; already dispatched effects may finish.
