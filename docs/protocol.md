# Local transport protocol

`BBCClient.request` and the embedded API accept an object with `method`, optional `params`, and optional `trace_id`. The client routes ordinary requests to the app’s local JSON-RPC worker and native requests to the app’s native worker. The native helper is stdio only and receives no network credentials.

| Method | Route | Purpose |
| --- | --- | --- |
| `status` | local + native status | Report observed capabilities and existing permissions |
| `messages.after` | read-only SQLite verification | Read a cursor page and verify service/thread/attachment metadata |
| `send` | local Apple Events | Send text or an opaque local media upload with explicit recipient and service |
| `send` with `params.reply_to` | native `reply` | Reply to an exact message |
| `link` | native composer | Send a URL in an exact direct chat for Messages to preview |
| `media.download` | local read-only worker | Download an exact local attachment in bounded base64 chunks |
| `tapback` | native | Set/remove a classic reaction or one custom emoji |
| `read`, `read.status` | native | Open a verified message once, or observe local read state |
| `media.visual`, `media.transcribe` | native | Prepare an exact message attachment |
| `typing.start` | native session | Hold a bounded typing session; cancellation closes its stdin |

Native parameters bind `chat_guid` and `message_guid` to one exact direct iMessage conversation in the current user's read-only Messages database. Replies accept `reply_to`, `text` and `read_guids`; reads require `read_guids`. These unread GUIDs must cover the current native unread set before a UI action may implicitly mark it read. Reactions accept `reaction` (`love`, `like`, `dislike`, `laugh`, `emphasis`, `question`) and optional `remove`. Media requests also require `attachment_guid`. See `NativeRequest.validated` in the native helper for exact field validation.

An `ok: true` native receipt confirms the observed local state. `observation_only` explicitly describes a read-only check. A failed receipt with `uncertain: true`, a timeout, cancellation or a missing/mismatched JSON-RPC receipt must be reconciled by the consumer before any new mutation. BBC never automatically retries a dispatched mutation. A local send/read confirmation does not establish recipient-visible delivery or Read.

The consumer must persist intent before dispatch, associate the receipt with that intent and retain uncertain outcomes. Authorization, contacts, schedules and assistant task execution belong to the consuming application. The transport never infers permission from an exact database match.

Native process output is bounded at 2 MB. Request input is bounded at 64 KB. Native diagnostics use fixed stages and opaque trace IDs and exclude message contents, account addresses, file paths and raw Accessibility trees. Default native data and preferences use BBC's own namespace, with no dependency on Seven's macOS user or configuration.

HTTP media uploads use raw bytes outside the worker protocol (32 MiB maximum), returning an opaque UUID. Workers resolve only private, unexpired uploads; paths are not an API parameter. Attachment downloads use chunks of at most 768 KiB so worker output stays within the 2 MB bound. Message pages include native custom-reaction emoji and bounded rich-link metadata decoded from property lists without instantiating archived classes.
