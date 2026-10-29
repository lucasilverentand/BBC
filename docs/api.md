# API

Start the API in the Mac app. All routes require `Authorization: Bearer <API key>`. Create and revoke keys in the app; the API cannot mint keys. The default base URL is `http://127.0.0.1:7861`.

Every mutation requires an `Idempotency-Key` header containing a UUID chosen and saved by the client before dispatch. Retrying the same UUID and body returns the saved receipt. A changed body returns HTTP 409. An interrupted operation remains uncertain and is never automatically dispatched again. Use `GET /v1/operations/<uuid>` with the same API key to retrieve its retained outcome. Do not create a new UUID merely because the original response was lost.

## Endpoints

| Route | Body / result |
| --- | --- |
| `GET /v1/status` | Observed permissions and available methods |
| `POST /v1/messages` | `to`, either `text` or uploaded `media_id`; always iMessage, SMS fallback disabled |
| `POST /v1/messages/after` | `since_rowid`, `limit` (1–200); incremental messages and `next_rowid` |
| `POST /v1/messages/status` | `chat_guid`, `message_guid`; observed local sent/delivered/read flags |
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

Status, message pages/status, read status, uploads, downloads and media preparation do not require an idempotency key. JSON requests accept at most 64 KB; raw uploads accept 32 MiB; responses are bounded at 2 MB. HTTP connections serve one request and close. The listener accepts at most eight simultaneous connections.

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

Send `{"to":"person@example.com","media_id":"<returned UUID>"}` to `/v1/messages` with a new operation UUID. Each send accepts one upload or text. Audio is sent as a file attachment; BBC does not label it as a recorded voice note. Supported uploads: JPEG, PNG, GIF, HEIC/HEIF, WebP, TIFF; MOV, MP4/M4V; M4A, MP3, CAF, WAV, AIFF and AAC. BBC validates the local file before accepting it. Uploads expire after 24 hours, with a 512 MiB local quota; expired files are removed on the next upload. Successful receipts confirm an exact new sent attachment in the local database, not recipient delivery.

Request message pages with `attachments: true` to receive opaque attachment GUIDs, MIME types and byte counts; `is_audio_message` identifies native audio messages. `/v1/media/download` returns original bytes as `data_base64`, with `offset`, `next_offset`, `total_bytes` and `complete`. Request successive offsets until complete. Each chunk is at most 512 KiB; each attachment is at most 32 MiB. Downloads require the exact direct-chat/message/attachment tuple and a local file already available in Messages. Paths and remote download URLs are never accepted. Both sent and received attachments can be downloaded.

## Rich links

Send `{"chat_guid":"…","message_guid":"…","url":"https://example.com","read_guids":["…"]}` to `/v1/links` with an operation UUID. The anchor must be a message in the intended direct chat, and `read_guids` must cover its current unread messages. BBC uses the native composer once, preserves existing drafts, and rejects an open reply composer. Messages generates the preview; `preview: "managed-by-messages"` does not guarantee the site supplies a card or the recipient sees one. Plain URL text can also be sent through `/v1/messages`.

Message pages include `links`: the URL and, when present in Apple’s rich-link payload, title, summary, site name and preview image/icon attachment GUIDs. `preview: false` means only a URL was detected in text. Metadata parsing makes no network requests. Download preview images through the attachment endpoint.

## Threading

A message page preserves `guid`, `chat_guid`, `reply_to_guid` and `thread_root_guid` separately. Apple's native thread originator identifies the reply root; it does not always expose an immediate parent reply. Top-level messages use their own GUID as `thread_root_guid`. Do not infer a thread from the latest message, matching text or another conversation with the same person.

Reply with the exact message GUID and chat GUID. The native adapter resolves and confirms the thread root and returns it as `thread_root_guid`, together with the new message `guid`. Existing drafts and ambiguous selections reject the action. `read_guids` must cover the conversation's current unread messages before an action can implicitly mark them read. A new unread message that was not consumed causes rejection.

## Tapbacks and read state

Tapbacks accept `love`, `like`, `dislike`, `laugh`, `emphasis`, `question`, or a single emoji such as `🎉` or `👩‍💻`. Set `remove: true` to remove the exact reaction. Message pages expose custom emoji as `reaction_emoji` alongside native add/removal types. Picker availability depends on the Mac’s emoji support; confirmation checks the exact emoji, including modifiers. The target is an exact UUID message in a verified direct iMessage chat. Setting an already present reaction is a no-op; the helper never repeats a button press to recover missing confirmation.

Read opens one verified message in its owned Messages process, then observes the local database. Apple may mark the conversation read as a side effect. A local read confirmation is not proof that the sender saw Apple's Read receipt. `messages.status` reports only the database flags the Mac actually observed; unknown remote visibility must stay unknown.

## Typing

Start returns an accepted session UUID promptly. A session lasts at most 30 seconds. Stop requests cancellation and cleanup of that session's own placeholder. Retrieve the start operation's receipt to see the eventual native result. An accepted start is not confirmation that the recipient saw typing, and a stop request is not proof of placeholder cleanup. Native failure receipts retain uncertainty. Starting another session while automation is owned can fail busy.

## Operation receipts and custody

Local records live in `~/Library/Application Support/Blue Bubble Club` with private directory/file permissions. Keys are stored as SHA-256 hashes of 256-bit random secrets; operation records retain request fingerprints and receipts. Uncertain records deliberately survive restarts. There is no automatic expiry or replay of retained operations.

The operator owns network exposure. The app offers loopback or other-device binding, without creating tunnels or opening router ports. Use a private trusted network or put your own HTTPS endpoint in front of the app. Keys grant access to the signed-in account's supported messaging features. Revoking a key blocks new calls; already dispatched effects may finish.
