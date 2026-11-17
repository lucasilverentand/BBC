# Webhooks and history search

BBC observes the local Messages database without opening a conversation. These features need Full Disk Access; they do not need the native bridge.

## Resumable event stream

Open `GET /v1/events` with the same `Authorization: Bearer …` header as other API calls. The response is `text/event-stream`; credentials never belong in the URL. Full-access and read-only keys can watch. The listener rechecks authentication and the key's direct-peer network restrictions every second, including on an already open stream. `/v1/status` advertises `event_stream:true` when the service is available.

A first connection without `Last-Event-ID` establishes a baseline at the current tail. It emits `bbc.ready` with an opaque SSE `id`. Save that checkpoint before relying on the stream. Reconnect with `Last-Event-ID: <last durably consumed id>` to replay subsequent retained events. A stream ID is distinct from a message GUID, database row ID, operation UUID, and the payload's deduplication ID. Treat it as opaque.

Message notifications use the same observer and payload identities as webhooks:

```text
id: <opaque replay cursor>
event: bbc.event
data: {"id":"<stable event UUID>","type":"message.received","observed_at":"…","message":{…}}

```

`message.updated` reports changed message state, including local sent/delivered/read observations. `operation.updated` instead contains `id`, `type`, `operation_id`, `method`, and `result`. The `result` is BBC's saved operation receipt, including provisional typing acceptance or a later final receipt. Deduplicate these notifications by their payload `id`; more than one update can belong to the same operation. An interrupted publication can repeat a notification with a different replay cursor but the same payload ID. Native submission, local confirmation and recipient delivery remain separate observations. An uncertain receipt never authorizes another send.

The server emits `bbc.status` at least every 15 seconds while idle, carrying `{"observation":"watching"}` or the observer's current failure state. An open socket does not establish that Messages observation is healthy. Connections rotate after five minutes; reconnect with bounded backoff and the saved cursor. A `bbc.reset` event closes a stream whose authorization or cursor is no longer usable. Reconnect and inspect the HTTP status; 401/403 require correcting access, not a new mutation.

Replay is persisted in the observer store and survives BBC restarts. Up to eight API keys can establish stream baselines. The journal retains at most 512 notifications and 8 MiB across keys. Falling behind retention, presenting a future cursor, or using a cursor from another journal returns HTTP 409 `event_cursor_expired` before streaming. Never silently discard that error or advance the saved cursor: reconcile message history and known operation receipts, then deliberately open a new baseline. Stream retention does not delete operation receipts or cause native retries. History reconciliation has the observer limits documented below; it cannot recreate every intermediate edit that occurred during a gap.

Message replay entries are saved atomically with the database observation cursors. Operation receipts are saved before notification; a bounded round-robin repair scan visits up to 100 receipt files each second to recover an interrupted publication. Receipts created before a key's first streaming baseline do not generate retrospective operation notifications. Known operations remain directly readable at `/v1/operations/<UUID>` regardless of the stream. The observer pauses on database replacement rather than treating restored history as new messages.

Each event batch contains at most 16 notifications, with one network write in flight and a ten-second stalled-write deadline. At most two of the listener's eight connections can stream, leaving capacity for commands. Webhooks continue independently; a full webhook outbox still pauses the shared observer. Stream clients do not acknowledge or drain webhook deliveries.

### Client integration

Keep one stream for the configured BBC key using the existing trusted transport and hostname verification. Persist an incoming message and its deduplication ID before advancing the stream checkpoint. Filter exact configured chat identities and retain native sender proof before admitting owner commands or marking messages read. Use operation notifications to refresh known receipts; never interpret arbitrary events as permission to execute a command.

During migration, keep webhook intake until streaming custody and reconnect recovery are proven. Both transports share message event IDs, allowing one durable deduplication path. A stream does not alter command routes, operation UUIDs, unread coverage, or the rule against replaying uncertain sends. Text generation stays inside the client; send one completed reply rather than dispatching one iMessage per generated token.

## Webhooks

Register a destination with `POST /v1/webhooks/register` and a new `Idempotency-Key` UUID:

```json
{"url":"https://example.com/bbc-events","chat_guid":"any;-;person@example.com"}
```

`chat_guid` is optional. Without it the subscription covers the account's conversations. The response contains `webhook_id` and a `signing_secret`. Save the secret when registering. Registrations and queued deliveries belong to the API key that created them; another key cannot list or remove them. Revocation removes that key's subscriptions and pending deliveries on the next service tick. A request already sent may finish.

Use `POST /v1/webhooks/list` with `{}` to inspect your subscriptions, pending counts and observation state. Remove one with `POST /v1/webhooks/remove`, a new operation UUID and `{"webhook_id":"…"}`. Removal also discards its pending deliveries. Destinations must use HTTPS; HTTP is accepted only for an explicit loopback destination. Redirects are refused.

Deliveries are JSON objects with `id`, `type`, `observed_at` and `message`. Event types are `message.received` for new incoming rows and `message.updated` for a changed observed message. Payloads include the exact message/chat GUIDs, text, direction, service, local sent/delivered/read state, reaction fields and available edit/retraction timestamps. Text is bounded and carries `text_truncated`; attachment bytes are fetched through the media API using the message identity.

Each request includes:

| Header | Value |
| --- | --- |
| `X-BBC-Event-ID` | Stable event UUID, also present in the JSON body |
| `X-BBC-Timestamp` | Unix seconds for this delivery attempt |
| `X-BBC-Signature` | `v1=` followed by a lowercase HMAC-SHA256 hex digest |

Base64-decode the signing secret. Verify HMAC over the UTF-8 timestamp, a literal `.`, then the **original HTTP body bytes**. Compare signatures in constant time and reject timestamps outside your allowed clock window. Deduplicate by event ID before processing. Retries keep the same body and event ID; their timestamp and signature change.

Return a 2xx status to acknowledge an event. Failures retry with exponential delay capped at one hour. The queue survives app restarts. Delivery is at least once: an acknowledged request can be repeated if BBC loses the acknowledgement or cannot save it. No message action is retried by the webhook service.

The service runs while the API is running. Each second it checks up to 100 new rows, rechecks the most recent 100 message rows and revisits up to 100 rows of older history. Recent state updates are usually observed on the next tick; updates to older messages can take a full revisit cycle. Existing history establishes a baseline rather than producing incoming events. Updates become observable after that baseline. The most recent 100,000 message/chat identities are tracked; older updates and changes that disappear between observations are not guaranteed. A deleted database row is not inferred as an unsend event; BBC reports available retraction fields.

BBC stores at most eight subscriptions and 512 queued deliveries, within a 64 MiB state file. A full outbox pauses observation without advancing its cursor, while delivery continues to drain it. `outbox_full`, `observation_unavailable` and `storage_unavailable` are explicit observation states. Database access failure does not fabricate events. New arrivals catch up after access or queue capacity returns, subject to Messages retaining those rows.

Replacing the Messages database or rolling its maximum row ID behind the saved incoming cursor latches `database_changed`. BBC identifies the database by its inode, birth time and volume UUID. A reboot that renumbers the volume's device does not count as a replacement; a copy restored onto another volume does, even with the same inode and birth time. An identity saved by an earlier BBC without the volume UUID is matched on inode and birth time and gains the volume UUID on its next scan, without a new registration. On a volume that reports no UUID, BBC falls back to inode and birth time. The upgrade is one-way: an older build reading an identity that includes the volume UUID latches `database_changed`, so rolling back requires registering again. BBC pauses new observation and keeps that state across restarts, even if the replacement later reaches the old row count. Already queued events retain their delivery IDs and can finish. Remove every old subscription, or revoke their owning keys, then register again to establish a baseline for the current database. Restored history is not replayed as new incoming messages.

An unchanged revisit advances its scan position in memory without rewriting the snapshot file. Message changes, incoming cursors, registrations and delivery receipts remain durable. After restart an older revisit position can be scanned again; saved hashes prevent duplicate unchanged-message events.

## History search

`POST /v1/messages/search` is read-only and does not require an operation UUID:

```json
{"text":"invoice","chat_guid":"any;-;person@example.com","from":"2026-10-01T00:00:00Z","to":"2026-11-01T00:00:00Z","limit":50}
```

At least one of `text`, `chat_guid`, `from` or `to` is required. Text is a literal substring, with Unicode case and diacritic matching; `%` and `_` are ordinary characters. Dates are ISO 8601, inclusive `from` and exclusive `to`. Conversations match their exact GUID. Groups can be searched as well as direct chats.

Results run from newest to oldest. `limit` is 1–200. A call scans at most 400 candidate database rows, including attributed-only message bodies, so a page can contain fewer matches or no matches while `more` remains true. To continue, pass `next_before_rowid` as `before_rowid` and `next_before_chat_guid` as `before_chat_guid`, keeping the original filters. The composite cursor preserves messages associated with more than one conversation.

Search returns exact identities, timestamps, direction, service and up to 1,000 characters of text per result. `text_truncated` identifies a shortened result. Plain text is inspected up to 64,000 characters; attributed-only bodies are decoded up to 256 KB. Larger attributed bodies cannot supply text matches. Database batches contain at most 26 candidates to keep memory bounded. This is a local scan, without an index or writes to Apple's database.

## Incoming typing (ephemeral)

A client can opt into incoming typing observations for **one direct iMessage chat** on its existing SSE connection by adding `X-BBC-Typing-Chat: <exact chat GUID>` to `GET /v1/events`. The accepted GUID prefixes are `any;-;` and `iMessage;-;`. Group typing is unsupported. Malformed scopes fail before streaming. Existing Bearer authentication, per-key peer restrictions, read-only access and connection limits apply; access is rechecked after native observation as well. No scope header means no native typing sampling and no typing events.

`/v1/status` advertises `incoming_typing:true` only when the native bridge is ready and its installed getter ABI supports incoming typing. This capability is separate from outgoing typing leases. A supported ABI cannot guarantee that a particular remote device will transmit a typing indication; clients must keep their fallback timing.

The bridge samples Messages' current incoming typing state using read-only native getters, without opening a chat, loading history, marking anything read, changing delegates or sending a typing signal. It verifies the exact chat, incoming direction and sender against the chat's sole native participant. The API observes approximately once per second while the stream is open. This is best-effort state observation; a transition shorter than the sampling interval can be missed.

```text
event: bbc.typing
data: {"type":"typing.started","chat_guid":"any;-;person@example.com","sender_handle":"person@example.com","observed_at":123000,"expires_at":129000,"ttl_ms":6000}

```

`type` is `typing.started`, `typing.stopped` or `typing.expired`. Timestamps are Unix **milliseconds**. A start includes an absolute expiry and remaining TTL of at most 8,000 ms, bounded by the native typing message's timestamp. Repeated samples of the same native indication do not extend it. A native cancellation, cleared indicator or subsequent message ends the observed lease; missing callbacks, an unavailable bridge or a stale getter eventually expire it. Stop has `ttl_ms:0`; expiry keeps the expired deadline. No content or native typing-message GUID is exposed.

These frames have **no SSE `id`**, never enter the replay journal or webhook outbox, and never advance the durable stream cursor. On reconnect, clients clear their local typing state and may receive a new observation if the native indication is still fresh. Expire locally at `expires_at` even if a connection stalls or closes before a stop/expiry frame. Do not restore typing state from a durable message checkpoint. Ignore unknown ephemeral event kinds rather than assigning them provider-message or owner-command authority.

Consumers must match both the already-admitted exact owner chat and sender handle before applying the hint. Incoming typing is advisory, never owner proof or a reason to mark a message read. Preserve a bounded reply delay (Seven uses an eight-second hard cap) and work normally when this capability or signal is absent.

For a scoped connection, `bbc.status` includes an `incoming_typing` diagnostic on the first sample and subsequent idle heartbeats. `available` distinguishes a successful native read from an unavailable observation. A successful read reports `state` (`idle`, `typing` or `expired`) and fixed boolean flags (`has_incoming`, `current_indicator`, `typing_message`, `cancelled`, `from_me`). An unavailable read reports a fixed `reason` code. These fields contain no message content, sender identity or native source GUID and are not replayed. They establish what the observer saw, not that a remote device sent an indication. Treat `incoming_typing:true` in `/v1/status` as getter-ABI availability; recipient-originated transition acceptance remains separate.
