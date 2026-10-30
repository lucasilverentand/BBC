# Blue Bubble Club

**A self-hosted iMessage API powered by your Mac.**

Build bots and messaging integrations with native iMessage threads, reactions and typing indicators.

## Features

- **Threaded replies** attached to the original message.
- **Tapbacks** — classic reactions and custom emoji.
- **Typing indicators, read receipts and delivery-state checks.**
- **Photos, videos and audio** — send uploads and download received attachments.
- **Rich links** with native previews and received link metadata.
- **Local media processing**, including optional on-device audio transcription.
- **Revocable API keys** and saved operation receipts to guard against duplicate sends.
- **Guided setup** with a floating permissions helper, draggable app icon and startup toggles.

Native actions currently support one-to-one iMessage chats. Read and delivery status reflect what Messages reports locally.

## How it works

BBC runs alongside Messages in your signed-in macOS session. One Swift app hosts the HTTP API and handles native messaging actions. Create an API key in the app, then connect your bot or service to the Mac. Choose local-only access or allow connections from other devices.

## Get started

Requires macOS 26+, Xcode 27.2+ and an Apple Development signing identity.

```sh
git clone https://github.com/lucasilverentand/BBC.git
cd BBC
./script/build_and_run.sh
```

Sign into Messages, follow the permission checklist, create an API key and select **Start API**.

```sh
curl http://127.0.0.1:7861/v1/messages \
  -H "Authorization: Bearer $BBC_API_KEY" \
  -H "Idempotency-Key: $OPERATION_UUID" \
  -H 'Content-Type: application/json' \
  -d '{"to":"+15555550123","text":"Hello from Blue Bubble Club"}'
```

Use a new UUID for each operation; reuse it when retrying the same request.

[API guide](docs/api.md) · [Protocol](docs/protocol.md) · [Swift SDK](Sources/BBCClient)

[MIT license](LICENSE) · [Third-party notices](NOTICE)
