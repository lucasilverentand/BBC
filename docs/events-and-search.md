# Webhooks and history search

BBC observes the local Messages database without opening a conversation. These features need Full Disk Access; they do not need the native bridge.

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

## History search

`POST /v1/messages/search` is read-only and does not require an operation UUID:

```json
{"text":"invoice","chat_guid":"any;-;person@example.com","from":"2026-10-01T00:00:00Z","to":"2026-11-01T00:00:00Z","limit":50}
```

At least one of `text`, `chat_guid`, `from` or `to` is required. Text is a literal substring, with Unicode case and diacritic matching; `%` and `_` are ordinary characters. Dates are ISO 8601, inclusive `from` and exclusive `to`. Conversations match their exact GUID. Groups can be searched as well as direct chats.

Results run from newest to oldest. `limit` is 1–200. A call scans at most 400 candidate database rows, including attributed-only message bodies, so a page can contain fewer matches or no matches while `more` remains true. To continue, pass `next_before_rowid` as `before_rowid` and `next_before_chat_guid` as `before_chat_guid`, keeping the original filters. The composite cursor preserves messages associated with more than one conversation.

Search returns exact identities, timestamps, direction, service and up to 1,000 characters of text per result. `text_truncated` identifies a shortened result. Plain text is inspected up to 64,000 characters; attributed-only bodies are decoded up to 256 KB. Larger attributed bodies cannot supply text matches. Database batches contain at most 26 candidates to keep memory bounded. This is a local scan, without an index or writes to Apple's database.
