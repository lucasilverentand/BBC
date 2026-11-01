# Scheduled sends

BBC keeps a local scheduled-send outbox in the Mac app. It dispatches due messages while the API is running in the signed-in macOS session. It does not wake the Mac or run a separate daemon. A message that became due while the API was stopped is sent on the next active check, so cancel unwanted overdue messages before starting the API.

All routes require the creating API key. Create, update and cancel also require a saved UUID `Idempotency-Key`, like other BBC mutations. The schedule ID is the create operation's UUID. Another key cannot inspect or change that schedule, even if it knows the ID. Revocation cancels pending sends when the scheduler next checks them; an already dispatched send may finish.

| Route | Parameters |
| --- | --- |
| `POST /v1/schedules/create` | `send_at` ISO 8601 timestamp, `message` |
| `POST /v1/schedules/update` | `schedule_id`, optional replacement `send_at` and/or `message` |
| `POST /v1/schedules/cancel` | `schedule_id` |
| `POST /v1/schedules/get` | `schedule_id` |
| `POST /v1/schedules/list` | Optional `limit` from 1 to 256; default 100 |

For a direct send, `message` is the usual `/v1/messages` body: `to` with either `text` or `media_id`. For a native multipart send, use `chat_guid`, optional `text`, up to eight unique `media_ids` and optional native `effect`. BBC accepts these send shapes only; schedules cannot invoke arbitrary API methods. Native multipart sends need a connected native bridge and retain its exact-chat and capability checks.

```json
{
  "send_at": "2027-01-20T09:00:00Z",
  "message": {
    "to": "person@example.com",
    "text": "A scheduled message"
  }
}
```

New or updated times must be in the future and no more than 366 days away. Media must remain valid beyond the scheduled time: uploads expire 24 hours after upload, and BBC rejects schedules past that upload's expiry. The sending worker validates the file again at dispatch; a long shutdown can leave an overdue media schedule unable to send. Uploads are not copied into permanent schedule storage.

A schedule reports `pending`, `dispatching`, `sent`, `failed`, `uncertain` or `cancelled`. Its `result` contains the send receipt when available. `sent` means BBC confirmed the local send, with the same limits as an immediate send; it is not recipient-delivery confirmation. `last_operation_id` links to the latest schedule-management operation. That operation's receipt acknowledges management of the schedule; use `get` for its later send outcome.

Update and cancel work while pending. Once dispatch starts they fail rather than claim to reverse a send. BBC writes the dispatch intent before invoking the sending worker. An interrupted or unconfirmed dispatch becomes `uncertain` and is never automatically replayed, including after restart. Keep the existing schedule ID for reconciliation; creating another schedule can send a duplicate.

The private store holds at most 256 schedules within an 8 MiB bound. Terminal records may be pruned seven days after their last change when creating a new schedule. Pending and dispatching records are retained, and the API's operation-receipt ledger has its own retention rules. A lifetime store lock prevents another instance from opening the outbox while an old instance or its in-flight send can still save a receipt. The app reuses that service across API stop/start.
