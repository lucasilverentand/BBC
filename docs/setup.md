# Set up Blue Bubble Club

BBC runs in the macOS user signed into Messages. Its app contains the API server and BBC's own native bridge; no separate messaging server or helper installation is needed.

BBC runs in the menu bar without a Dock icon. Use its message-bubble menu bar icon to start or stop the API or open **Server…**, **API Keys…** or **Settings…**. Page shortcuts are **⌘1** Server, **⌘2** API Keys, **⌘3** Logs and **⌘4** Settings. **⌘,** also opens Settings. **⌘S** starts or stops the API. Closing the window keeps the app and API running; choose **Quit Blue Bubble Club** from the menu to exit. Startup options apply when the app launches, even while its window is closed.

## Choose what to enable

| Use | Key access | Permissions | Native host changes |
| --- | --- | --- | --- |
| History, search, downloads and webhooks | Read-only | Full Disk Access | None |
| Ordinary text, image, video and audio sends | Full access | Full Disk Access and Messages Automation | None |
| Tapbacks, replies, rich-link creation, typing, mark-read, groups, edit/unsend, multipart/effects and availability | Full access | Full Disk Access and Messages Automation | Native messaging setup below |

Native capabilities vary with macOS. Fixture tests and passing host checks do not establish live private-API compatibility. Validate the connection on your host; [capability limits](native-features.md) describe the current scope.

## Build and open

Building requires macOS 26+, Xcode 27.2+ selected for command-line tools, and an Apple Development signing identity. Check the developer directory and identities:

```sh
xcode-select -p
security find-identity -v -p codesigning
```

If needed, select the installed Xcode in Xcode Settings → Locations and add your development account in Xcode Settings → Accounts. Then:

```sh
git clone https://github.com/lucasilverentand/BBC.git
cd BBC
./script/build_and_run.sh build
open 'dist/Blue Bubble Club.app'
```

The script resolves pinned dependencies, builds the executable and embedded library, packages resources and signs the app. It does not change host protections. With multiple identities, set `BBC_SIGNING_IDENTITY` to the exact identity above when running the script. Reuse the same identity and app location on later builds so macOS can retain permission grants.

## Configure this login

1. Open Messages and sign into the account this login will use. BBC does not switch accounts.
2. In **Settings → Server**, choose the port. Stop the API before changing connection settings.
3. In **Server → Setup**, choose **Settings…** beside **Full Disk Access** to open its System Settings page. The small helper floats beside the Settings window and follows it when moved, hiding while Settings is closed or minimized. Drag its icon into the list and enable BBC. Reopen BBC if macOS asks you to quit it.
4. For full access, use **Allow…** beside **Messages Automation** and approve the request. Read-only access needs only Full Disk Access. Accessibility permission is not required.
5. In **API Keys**, create a named key and save its secret. New keys default to read-only; choose **Full access** for sending. A full key cannot override the account's read-only mode.
6. On **Server**, select **Start API**. The listener can start before keys exist; requests remain unauthorized until a valid key is provided. Enable **Start API at launch** in **Settings → Startup** for automatic startup. New keys allow local connections only. To replace a secret later, open the key and choose **Rotate key…**; the old secret stops working immediately. For other devices, open the key in **API Keys**, enable **Allow network access** and optionally set allowed client IP/CIDR ranges. Every caller still needs a key. See [access controls](api-access.md).

For separate sending and personal accounts, repeat this in separate macOS logins with independent keys and ports, such as 7861 and 7862. Keep both signed-in sessions and BBC apps running. See [operating modes](operating-modes.md).

## Check the API

Set `BBC_API_KEY` in your client's secret environment, then query your configured port:

```sh
curl http://127.0.0.1:7861/v1/status \
  -H "Authorization: Bearer $BBC_API_KEY"
```

Check `operating_mode`, `key_access` and `methods`. Read-only status can succeed with `native_bridge_ready: false`; observation does not need the bridge. For sending, use a full-access key. Save an operation UUID before dispatch and reuse that UUID/body if the response is lost. The [API guide](api.md) covers sends and receipts. Never retry an uncertain send under a fresh UUID.

## Native messaging

Only use this section for the advanced features in the table. BBC currently requires SIP disabled and system library validation disabled before it starts the embedded bridge. These changes reduce host protections and affect every user in this macOS installation. Choose a host where you accept that change. Read-only access and ordinary background sends do not require it.

BBC never changes these settings. The commands below are manual operator steps. Record the original values first, including whether the preference is absent:

```sh
csrutil status
defaults read /Library/Preferences/com.apple.security.libraryvalidation DisableLibraryValidation
```

### 1. Change SIP in Recovery

Shut down. On Apple silicon, hold the power button until startup options appear, then choose **Options → Continue**. On Intel, start while holding **Command-R**. Authenticate when prompted and open **Utilities → Terminal**. These steps follow [Apple's Recovery instructions](https://support.apple.com/en-us/102518).

Run:

```sh
csrutil disable
```

Follow the confirmation prompts and restart into normal macOS. Apple's [SIP configuration documentation](https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/ConfiguringSystemIntegrityProtection/ConfiguringSystemIntegrityProtection.html) explains why this requires Recovery. A managed Mac may prohibit the change; BBC cannot bypass that policy.

### 2. Configure library validation

In Terminal in normal macOS, run:

```sh
sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation DisableLibraryValidation -bool true
```

Restart, sign into the intended Messages login and reopen BBC. Check both values again. BBC's readiness check requires `csrutil status` to report **disabled** and the preference read to return **1**. Enabled, partial or unrecognized SIP output is unavailable. See the current [BridgeReadiness implementation](../NativeMessages/Sources/BBCMessagesActions/NativeBridge/BridgeHost.swift).

### 3. Connect the bridge

Create or edit a key with **Full access** in **API Keys**. In **Server → Setup**, click the refresh icon at the top right of Setup, then **Connect**. BBC asks this user's Messages process to quit gracefully and starts it with the library embedded in BBC. It aborts if Messages refuses to quit; it never force-kills the app or clears drafts.

Query `/v1/status` with a full-access key. `native_bridge_ready: true` and `native_bridge.capabilities` report the connected session and available methods. Read-only keys intentionally hide native write capabilities. Missing private selectors remain unavailable; a lost result after dispatch remains uncertain.

**Disconnect** disconnects BBC and clears its owned typing leases; Messages stays open. In **Server → Setup**, enable **Connect automatically at launch** only after validating the connection. App login startup and API startup have separate toggles.

### Unattended startup

For an always-on host, enable **Start at login**, **Start API at launch** and **Open Messages hidden at launch** in **Settings → Startup**, plus **Connect automatically at launch** in **Server → Setup** once the bridge is validated. With **Open Messages hidden at launch**, BBC opens Messages in the background when it launches, or hides an existing Messages process. It also hides Messages after relaunching it for the bridge. Hiding uses the app-level hide API; BBC sends no clicks or keystrokes. Choose Messages from the Dock or app switcher to show it again. If the bridge cannot connect at launch, BBC still opens Messages hidden for history and ordinary sends and does not retry the bridge. Startup only runs after this macOS user logs in.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| API will not start | Create a key, choose a free port and correct invalid IP/CIDR rules. Another BBC instance in this login may own the listener/store locks. |
| 401 | Check the key and whether it was revoked; keys belong to one macOS user. |
| 403 `client_address_denied` | Allow the direct peer IP. Behind a proxy this is the proxy's address, not a forwarded header. |
| 403 `key_readonly` | Use a key with Full access. |
| Database access fails | Recheck Full Disk Access for this signed app. Test through the app-hosted API; terminal workers can have different permission attribution. |
| Bridge unavailable | Check a full-access key, host values and whether Messages can quit. Rebuild if the embedded library is missing. |
| A native method is missing | This macOS version may lack required selectors. A connected bridge does not imply every feature is supported. |
| Operation uncertain | Retrieve `/v1/operations/<uuid>` with the same key and reconcile before another mutation. Do not generate a new retry UUID. |
| Webhooks report `database_changed` | Remove old subscriptions and register a new baseline; see [webhooks](events-and-search.md). |

Audio/image/video transfer does not need speech models. Optional transcription needs the separately staged files, sizes and hashes in [the model manifest](../NativeMessages/Sources/BBCMessagesActions/Resources/ParakeetModels.lock.json), with the ownership and directory layout enforced by [LocalModels](../NativeMessages/Sources/BBCMessagesActions/LocalModels.swift). The app does not download them; `media.transcribe` stays unavailable until they are staged.

## Restore host protections

Stop the API, turn off native-messaging startup and select **Disconnect**. Quit Messages and reopen it normally to remove the library from its process.

Restore the library-validation preference to its recorded value. If it was absent before setup, remove only that key:

```sh
sudo defaults delete /Library/Preferences/com.apple.security.libraryvalidation DisableLibraryValidation
```

If it previously existed as false (`0`), restore it with:

```sh
sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation DisableLibraryValidation -bool false
```

If it was already true, leave it true. Do not delete the whole preference file. If SIP was enabled before setup, return to Recovery Terminal and run:

```sh
csrutil enable
```

Restart and verify the original settings. Restore any pre-existing custom policy with its administrator. The native bridge becomes unavailable when its requirements no longer pass; read-only access and ordinary sending can still operate with their normal permissions.

## Activity logs

Open **Logs** from the sidebar or menu bar for timestamped app events, API lifecycle changes, HTTP result summaries, native connection changes and errors. The latest 500 entries are retained locally across launches in `~/Library/Application Support/Blue Bubble Club/activity-log.json`. **Copy logs** copies the history; **Clear logs** removes it. If storage is unavailable, session events remain visible with a warning.

Logs contain operational summaries, not token secrets, request headers or bodies, message contents, recipients or attachment data. HTTP summaries contain the request method and response status; they do not establish recipient delivery. Malformed connections rejected before routing are not included in these summaries.
