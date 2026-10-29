# Blue Bubble Club Mac app

This Swift package builds the single `BlueBubbleClub` executable. It contains the SwiftUI app, local API, API key store, direct Messages reader/sender and native reaction/reply/read/typing workers. Build and run through the root `script/build_and_run.sh` so the app has a stable bundle and signature.

`--rpc` and `--native-actions` are isolated internal modes of that same executable. They are invoked locally by the SDK and never start an API listener. Workers require the current non-root macOS identity, verify the Messages process owner and exact native targets, serialize automation, preserve existing drafts and never retry a dispatched mutation. Apple database access is read-only. Read actions open one exact message GUID; opening a chat may itself mark other messages read, so current unread coverage is required.

The pinned Beeper source and exact patch are prepared in ignored `build/beeper-imessage`. `Package.resolved` pins transitive dependencies. The patch prevents shared Messages termination, hidden-Space recovery, generic draft clearing and uncontrolled action retries. Fixed diagnostic stages omit message text, account handles, paths and raw UI trees. Tests use fixtures and do not open Messages.
