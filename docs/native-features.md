# Native groups, message changes and multipart sends

These features use BBC's embedded [native bridge](native-bridge.md). They require a configured host and a connected bridge; `GET /v1/status` reports the available methods. Unsupported private APIs fail before dispatch. BBC does not fall back to clicking Messages.

All mutations require a saved `Idempotency-Key` UUID. Keep uncertain receipts and reconcile them rather than submitting the same action with a new UUID. A native state or local database confirmation does not prove remote delivery.

## Groups

| Route | Parameters |
| --- | --- |
| `POST /v1/groups/create` | `participants`: 2–32 distinct iMessage addresses; optional `name` |
| `POST /v1/groups/add` | Exact `chat_guid`, `participants`: 1–32 addresses |
| `POST /v1/groups/remove` | Exact `chat_guid`, `participants`: 1–32 addresses |
| `POST /v1/groups/name` | Exact `chat_guid`, nonempty `name` up to 256 UTF-8 bytes |
| `POST /v1/groups/photo` | Exact `chat_guid`, one uploaded image's `media_id` |
| `POST /v1/groups/leave` | Exact `chat_guid` |

Group mutations require an existing exact iMessage group, and native membership/leave eligibility must permit the operation. Apple may restrict changes based on the group's participants and service. Creating a group requests a fresh native conversation; the result contains its exact `chat_guid`. It does not send an introductory message.

BBC observes the native participant identities, name or left flag before returning `ok: true`. A photo update currently confirms only that the native call returned: its receipt has `accepted: true`, `uncertain: true`, `native_confirmation: "pending"` and `confirmation: "native-call"`, without `ok: true`. A group change whose resulting state cannot be observed uses the same pending receipt. Neither receipt should trigger an automatic retry.

Native group creation, mutations, multipart sends and message changes support group identities. The existing Tapback, threaded reply, read, typing and attachment-download routes retain their one-to-one contract in this version.

## Edit and unsend

Send an exact `chat_guid` and `message_guid` to `/v1/messages/edit` or `/v1/messages/unsend`. `part_index` selects a native part from 0–63 and defaults to 0. Editing also requires nonempty `text` up to 64,000 UTF-8 bytes.

Only sent messages belonging to the local account are eligible. BBC checks the original send time, with an upper bound of 15 minutes for editing and two minutes for unsending, then asks the native part whether the operation is allowed. Native eligibility retains Apple's edit-count and compatibility restrictions. These limits follow [Apple's documented edit and unsend behavior](https://support.apple.com/en-ca/guide/messages/ichtd68328c6/mac). Both direct and group iMessage chats are supported; SMS is excluded.

An edit succeeds only when the exact native part reports an edited state with the requested text. Unsend succeeds only when that part is retracted or the exact message is fully retracted. A returned native call with no observed result produces a pending, uncertain receipt. Older recipients may still retain the original content.

## Multipart messages and effects

`POST /v1/messages/multipart` sends one native message in an exact direct or group `chat_guid`:

```json
{
  "chat_guid": "iMessage;+;<exact-group-identifier>",
  "text": "Photos from today",
  "media_ids": ["<first-upload-UUID>", "<second-upload-UUID>"],
  "effect": "com.apple.messages.effect.CKConfettiEffect"
}
```

Text is optional, and a message must have text or at least one attachment. Up to eight distinct uploaded images, videos or audio files may accompany it, with 32 MiB of attachment data in total. Text comes first, followed by attachments in the supplied order. Uploads must still be valid when dispatched. The API accepts upload IDs rather than paths or native transfer GUIDs.

`effect` accepts an Apple native effect identifier of up to 160 bytes, beginning with `com.apple.messages.effect.` or `com.apple.MobileSMS.expressivesend.`. BBC verifies that the native message retains the requested identifier. Rendering support depends on Messages and the recipient's software.

BBC builds one attributed native body using the platform's exported attribute keys and sends it once through the explicit iMessage service. A successful receipt requires the exact BBC-created message GUID, new sent database row, body, attachment filenames and effect identifier to match. A missing confirmation remains uncertain. Private handoffs for native transfers live under `~/Library/Messages/BBCTransfers` so Messages can access them within its sandbox; completed copies are removed when their exact storage handoff is observed.

## Availability

`POST /v1/availability` accepts `{"address":"person@example.com"}` or an E.164 phone number. This observation does not require an idempotency key. BBC asks the native IDS service for iMessage registration and returns `available: true`, `false` or `null`, with a corresponding `status` of `available`, `unavailable` or `unknown`.

An availability result is a current observation, not a delivery guarantee or permission to contact the address. A missing native query capability is explicitly unavailable. Live compatibility for this bridge still requires validation on a configured host; synthetic runtime fixtures do not establish it.
