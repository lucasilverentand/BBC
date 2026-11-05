# Blue Bubble Club

**A self-hosted iMessage API powered by your Mac.**

Build bots and messaging integrations with native iMessage threads, reactions and typing indicators.

## Features

- **Threaded replies** attached to the original message.
- **Tapbacks** — classic reactions and custom emoji.
- **Typing indicators, read receipts and delivery-state checks.**
- **Photos, videos and audio** — send uploads and download received attachments.
- **Rich links** with native previews and received link metadata.
- **Group management, edit/unsend and multipart messages** with native effects, where supported.
- **Webhooks** for incoming messages and observed updates, plus history search.
- **Read-only mode** for a personal account alongside a separate full-API macOS user.
- **Scheduled sends** with update/cancel operations and iMessage availability checks.
- **Local media processing**, including optional on-device audio transcription.
- **Revocable API keys** and saved operation receipts to guard against duplicate sends.
- **Guided setup** with a floating permissions helper, draggable app icon and startup toggles.

Replies, Tapbacks, read and typing currently target direct chats. Group management and multipart sending use the native bridge. [Capability limits](docs/native-features.md) and local read/delivery observations stay explicit.

## How it works

BBC runs alongside Messages in your signed-in macOS session. One Swift app hosts the HTTP API, manages keys and connects to its own embedded native messaging bridge. Create a key, start the API and connect your bot or service to the Mac.

Advanced messaging needs the host configuration in [BBC's setup guide](docs/setup.md#native-messaging), including SIP and library-validation settings. BBC reports the requirements and starts its embedded bridge explicitly. It never automates the mouse, keyboard or Messages composer.

## Get started

Requires macOS 26+, Xcode 27.2+ and an Apple Development signing identity.

```sh
git clone https://github.com/lucasilverentand/BBC.git
cd BBC
./script/build_and_run.sh
```

Follow the [setup guide](docs/setup.md) for permissions and API access. For this sending example, create a key with **Full access**, then select **Start API**.

```sh
curl http://127.0.0.1:7861/v1/messages \
  -H "Authorization: Bearer $BBC_API_KEY" \
  -H "Idempotency-Key: $OPERATION_UUID" \
  -H 'Content-Type: application/json' \
  -d '{"to":"+15555550123","text":"Hello from Blue Bubble Club"}'
```

Use a new UUID for each operation; reuse it when retrying the same request.

[Setup guide](docs/setup.md) · [API guide](docs/api.md) · [Protocol](docs/protocol.md) · [Swift SDK](Sources/BBCClient)

[Testing without iMessage](docs/testing.md) · [Marketing website](website/)

[Release process](docs/releases.md) · [Changelog](CHANGELOG.md)

[MIT license](LICENSE) · [Third-party notices](NOTICE)

## Project guidance

See [project guidance](docs/project-guidance.md) for accepted requirements, decisions and technical context. Maintain project knowledge with the source; Notion holds global/cross-project guidance and planning, and Linear tracks delivery and acceptance.
