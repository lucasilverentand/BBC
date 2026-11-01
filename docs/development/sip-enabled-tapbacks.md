# Custom emoji Tapbacks with SIP enabled

## Result

No working SIP-enabled, unattended custom-emoji sending path has been demonstrated. A standalone IMCore client is blocked by a daemon entitlement check on the tested macOS 27.2 build (26B123), including when signed with BBC's existing Apple Development identity. This is a failed connection, not a failed emoji search or UI focus problem.

The initial connection tests ran with SIP **disabled**, with CSR configuration `111` (`0x6f`) and the library-validation override set to `1`. They establish an additional entitlement barrier even on that weakened host. They do **not** count as SIP-enabled live verification. A fresh test after restoring SIP remains outstanding.

The experiment sends no messages, reads no conversations, opens no picker, and changes no host protections or installed apps. The production bridge and its readiness check are unchanged.

## Evidence

### Standalone IMCore client

BBC's probe loads the installed IMCore framework into its own process, under its own bundle identifier. It validates the connection method signatures, calls `connectToDaemonWithLaunch:NO`, waits up to five seconds for `isConnected`, then disconnects. It does not launch Messages, impersonate an Apple listener, add private entitlements or inject a library.

The ad-hoc and development-signed probes both observed:

```json
{
  "connect_return": true,
  "connected_before": false,
  "connected_after": false,
  "mutation_attempted": false
}
```

Outside the execution sandbox, the daemon logged a rejection matching each probe's exact process ID:

```text
imagent: [com.apple.Messages:DaemonClientConnections]
Client <probe PID> does not have any of allowed entitlements <private>, invalidating connection
```

The private entitlement names are redacted by macOS, so their identities are not established. An ordinary development signature does not resolve this rejection. `connect_return: true` acknowledges a connection attempt; it must never be treated as a connected session or successful mutation.

The installed `IMMessage` class has the emoji setter/getter and reaction initializer used by BBC. Selector presence establishes only that message construction APIs exist. It does not grant access to the daemon that sends them. An [upstream first-hand investigation](https://github.com/openclaw/imsg/issues/60) records the same connection failure on macOS 26; that corroborates the result but does not replace BBC's local test.

### Public automation and extension surfaces

| Surface | Observed limit |
| --- | --- |
| Installed `Messages.sdef` | Send, login and logout commands; no reaction command or exact reaction-target parameter. |
| Installed Messages App Intents metadata | Only `ConversationListFocusFilterAction`; no Tapback action. |
| Installed Siri assistant extension declarations | Send, search, play sound, set attributes, edit and unsend intents; no declared reaction intent. |
| App Intents messages schemas | Schemas describe actions implemented by the adopting app. The `customReaction` enum schema does not itself provide an API for invoking Apple's Messages reaction sender. |
| Messages app extensions | Apple's iMessage app extension surface targets iOS/iPadOS. Its send method also requires a visible extension and recent user interaction, so it does not supply BBC's unattended Mac reaction path. |

Sources: [Apple messages schemas](https://developer.apple.com/documentation/appintents/app-schema-domain-messages), [iMessage app platform support](https://developer.apple.com/design/human-interface-guidelines/imessage-apps-and-stickers), [extension send interaction requirements](https://developer.apple.com/documentation/messages/msconversation/send(_:completionhandler:)-9krz).

These checks rule out the inspected routes on this build. They are not a proof that no future OS version or other legitimate interface can support the feature.

## Reproduce without sending

Requires macOS and Xcode command-line tools. Metadata inspection is the default and never attempts a daemon connection:

```sh
bash script/diagnostics/probe_native_access.sh --metadata
```

To test the standalone daemon handshake, opt in explicitly:

```sh
bash script/diagnostics/probe_native_access.sh --connect
```

The script creates and removes its own temporary app bundle. Signing defaults to ad-hoc; set `BBC_SIGNING_IDENTITY` to your existing development identity to compare a normally signed client. It never adds entitlements. Run outside an execution sandbox that denies Messages daemon IPC, otherwise the sandbox may obscure the platform result.

The JSON reports the actual CSR configuration and `sip_fully_enabled`. `sip_on_daemon_connection` is true only when `isConnected` is observed and the CSR configuration is known to be zero. Unknown or weakened protection settings cannot pass that check. Exit codes: `0` for completed metadata inspection or an observed SIP-on connection, `2` for unavailable/rejected access, `3` for a connection observed without fully enabled SIP, `64` for invalid arguments. Even a successful handshake does not verify a Tapback.

If a connection fails, scope local unified-log inspection to that probe's PID and the daemon's entitlement rejection. Keep private logs and account details out of public issues and commits.

## Next acceptance gate

Repeat the ordinary, development-signed helper handshake with SIP enabled and record the library-validation setting. If it is rejected again, keep custom emoji sending unavailable in this mode; do not disguise a UI action or plain emoji message as a native reaction. A new route must identify a legitimate callable interface before any send is attempted.

Only after a SIP-on connection is established should a live test target one exact message and one fixed emoji. Dispatch add once, confirm its exact outgoing reaction GUID/type/emoji in the database, reconcile the receipt, dispatch removal once and confirm its exact removal event. Never retry an uncertain mutation automatically. Existing [native bridge confirmation rules](../native-bridge.md#verification-boundary) continue to apply.
