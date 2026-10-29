# Blue Bubble Club

A small Mac app that turns your local iMessage account into an API. Open the app, create an API key, start the API and connect your client to the Mac.

Blue Bubble Club (BBC) is a self-hosted alternative in [Sendblue's](https://sendblue.com) category. It runs locally as **one Swift executable** with a simple SwiftUI app and an embedded HTTP listener. You decide how your clients reach the Mac. There is no separate server stack, distributed system, cloud account or managed tunnel.

## What it does

- Send text through the local Messages iMessage account.
- Read incremental message pages with native message, chat, reply and thread-root GUIDs.
- Reply to an exact message and preserve its native thread root.
- Add or remove the six standard Tapbacks.
- Mark a consumed conversation read and observe local read/delivery state.
- Start bounded typing sessions and request their cleanup.
- Create and revoke named API keys in the app. Only hashes are stored; secrets are shown once.
- Retain operation receipts on the Mac so repeating a request cannot silently send it twice.

Optional local attachment preparation and transcription use the Mac's own access. Native UI actions currently support direct one-person iMessage chats. Group actions, custom emoji and commercial API parity are future work. Apple exposes chat-level read effects; the app cannot promise atomic per-message Read delivery. Native behavior and background-session compatibility need validation on your Mac.

## Run on your Mac

You need macOS 26+, Swift 6.2+ and an Apple Development signing identity for a stable local build.

```sh
git clone https://github.com/lucasilverentand/BBC.git
cd BBC
./script/build_and_run.sh
```

The script builds and signs `dist/Blue Bubble Club.app`. Open Messages and sign into iMessage in the same macOS account. Grant Blue Bubble Club Full Disk Access, Accessibility and Automation permission in System Settings. Status checks never prompt for permissions.

In Blue Bubble Club, create a named API key, save the secret in your client's secret settings and choose **Start API**. Enable **Start at login** to use macOS Login Items, and **Start API when the app opens** if the API should come up automatically. Both default off. Startup occurs in the signed-in user session, where Messages can access the account. The listener defaults to `127.0.0.1:7861`. Enable connections from other devices if needed; use your own trusted private network or HTTPS proxy. BBC does not configure remote access.

```sh
curl http://127.0.0.1:7861/v1/status \
  -H "Authorization: Bearer $BBC_API_KEY"
```

See [API usage](docs/api.md) for sending, threading, Tapbacks, read receipts, typing and idempotency. Keys grant messaging access to this Mac. Revocation blocks new requests; an already dispatched action may finish.

## Build and test

```sh
bash script/prepare_native.sh
python3 script/test_swift.py .
python3 script/test_swift.py NativeMessages
./script/build_and_run.sh build
```

`build` stages and signs the app without launching it. Set `BBC_SIGNING_IDENTITY` or create an ignored `Config/LocalSigning.env` if you need to select an identity. The app contains one executable plus ordinary resource bundles; native actions use isolated worker modes of that same executable. There is no imsg executable or separately deployed API service.

Tests use fixture databases and fake executables; they do not send real messages. The preference override test requires a disposable account and is skipped by default. Optional transcription tests need explicitly staged model weights. Local database confirmation remains separate from recipient-visible delivery, Read and typing.

## Swift clients and Seven

The root Swift package exposes `BBCClient`. It contains `BBCHTTPClient` for the app's API and `BBCClient` for local invocation of the app's worker modes. Importing the SDK does not fetch the app's native UI or audio dependency graph.

```swift
import BBCClient

let client = BBCHTTPClient(
    baseURL: URL(string: "http://127.0.0.1:7861")!,
    apiKey: apiKey
)
let status = try await client.request(.object(["method": .string("status")]))
```

For mutations, persist an operation UUID and pass it as `operationID`. Reuse that UUID only for the same operation. The API retains uncertain outcomes instead of replaying them. Consumers still own their authorization and reconciliation decisions.

Seven consumes BBC through its own adapter. BBC owns messaging transport; Seven retains assistant behavior, contact permissions and its execution journal.

## Optional local media

Visual attachment preparation runs locally. Transcription is advertised only when the pinned Parakeet weights are staged by an operator. Set `BBC_MODEL_DIRECTORY` and `BBC_MODEL_OWNER_UID` for that installation. Files and directories must be immutable to the runtime user and match `NativeMessages/Sources/BBCMessagesActions/Resources/ParakeetModels.lock.json`. The runtime never downloads weights.

## License

MIT. BBC was extracted from Seven's local iMessage implementation with a fresh repository history. The native adapter uses a pinned, narrowly patched MIT-licensed [Beeper platform-imessage](https://github.com/beeper/platform-imessage) dependency. See [NOTICE](NOTICE), [LICENSES](LICENSES) and the reviewed patch for third-party attribution and changes. BBC does not disable SIP or inject code into Messages. It is independent of Apple, Beeper, Sendblue and the BBC broadcasting organization.
