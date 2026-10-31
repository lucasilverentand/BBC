# Local transport protocol

`BBCClient.request` and the embedded API accept an object with `method`, optional `params`, and optional `trace_id`. The client routes ordinary requests to the app's local JSON-RPC worker and native requests to its native worker. Both are modes of the same executable. Workers receive no HTTP API keys. The native worker authenticates to the app's loopback broker, which forwards one command to BBC's embedded Messages library. See [native bridge](native-bridge.md).

| Method | Route | Purpose |
| --- | --- | --- |
| `status` | local + native status | Report observed capabilities and existing permissions |
| `messages.after` | read-only SQLite verification | Read a cursor page and verify service/thread/attachment metadata |
| `send` | local Apple Events | Send text or an opaque local media upload with explicit recipient and service |
| `send` with `params.reply_to` | native `reply` | Reply to an exact message |
| `link` | native bridge | Create a URL message for Messages to preview |
| `media.download` | local read-only worker | Download an exact local attachment in bounded base64 chunks |
| `tapback` | native | Set/remove a classic reaction or one custom emoji |
| `read`, `read.status` | native / read-only database | Mark an exact chat read, or observe local read state |
| `media.visual`, `media.transcribe` | native | Prepare an exact message attachment |
| `typing.start` | native session | Hold a bounded typing session; cancellation closes its stdin |
| `messages.search` | read-only SQLite | Search text, conversation and date with bounded pagination |
| `groups.create/add/remove/name/photo/leave` | native bridge | Manage native group chats where supported |
| `messages.edit/unsend` | native bridge | Change an exact owned outgoing message within native limits |
| `messages.multipart` | native bridge | Send text, uploaded attachments and an optional native effect |
| `availability` | native bridge | Query observed iMessage availability for an address |
| `webhooks.register/list/remove` | app-local HTTP service | Configure authenticated event delivery |
| `schedule.create/update/cancel/get/list` | app-local HTTP service | Manage durable local scheduled sends |

Webhooks and schedules run inside the API host and are available through `BBCHTTPClient`; they are not one-shot `BBCClient` worker methods. See [events/search](events-and-search.md), [scheduling](scheduling.md) and [native features](native-features.md) for schemas and capability limits.

Native parameters bind `chat_guid` and `message_guid` to one exact direct iMessage conversation in the current user's read-only Messages database. Replies accept `reply_to`, `text` and `read_guids`; reads require `read_guids`. These unread GUIDs must cover the current unread set before an action that can mark it read. Reactions accept a classic `reaction` (`love`, `like`, `dislike`, `laugh`, `emphasis`, `question`) or one emoji sequence and optional `remove`. Media requests also require `attachment_guid`. See `NativeRequest.validated` for exact field validation.

An `ok: true` native receipt confirms the observed local state. `observation_only` explicitly describes a read-only check. A failed receipt with `uncertain: true`, a timeout, cancellation or a missing/mismatched JSON-RPC receipt must be reconciled by the consumer before any new mutation. BBC never automatically retries a dispatched mutation. A local send/read confirmation does not establish recipient-visible delivery or Read.

The consumer must persist intent before dispatch, associate the receipt with that intent and retain uncertain outcomes. Authorization, contacts, schedules and assistant task execution belong to the consuming application. The transport never infers permission from an exact database match.

Native process output is bounded at 2 MB. Request input is bounded at 64 KB. Native diagnostics use fixed stages and opaque trace IDs and exclude message contents, account addresses and file paths. Bridge frames are bounded at 128 KiB and mutually authenticated with role-specific challenge proofs. A lost connection after dispatch is uncertain; commands are never reconnected or replayed. Default native data and preferences use BBC's own namespace.

HTTP media uploads use raw bytes outside the worker protocol (32 MiB maximum), returning an opaque UUID. Workers resolve only private, unexpired uploads; paths are not an API parameter. Attachment downloads use chunks of at most 512 KiB so worker output stays within the 2 MB bound. Message pages include native custom-reaction emoji and bounded rich-link metadata decoded from property lists without instantiating archived classes.
