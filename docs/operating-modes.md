# Operating modes

Each macOS user can run BBC in **Full API** or **Read-only · watch and receive** mode. The choice is stored in that user's app preferences. Stop the API before changing modes, then start it again to apply the selection. An HTTP client cannot change the operating mode.

Full API enables the supported sending and native messaging operations. Read-only mode watches that user's Messages database and serves history, search, message status, received attachments and local media preparation. It can register, list and remove webhooks for incoming messages and message updates. This changes BBC's local webhook configuration without sending anything through Messages.

Read-only mode rejects sends, replies, rich-link sends, Tapbacks, mark-read calls, typing indicators, availability checks, group changes, edit/unsend, uploads and scheduled-send operations with HTTP 403 and `readonly_mode`. The mode check happens before mutation receipts are created or replayed. Reading an existing operation receipt remains available for reconciliation. Status reports `operating_mode: "read-only"` and filters out unsupported methods.

The observer needs Full Disk Access to read its Messages database. It does not need Messages Automation or the native bridge. BBC does not start that bridge or a scheduled-send service in read-only mode. Existing schedules remain stored; switching back to Full API can resume due schedules under the [scheduling contract](scheduling.md).

## Two accounts on one Mac

Use separate macOS logins for different Messages accounts. Sign each login into its own Messages account, launch BBC there and create that login's API keys. BBC uses the current user's `~/Library/Messages/chat.db`, private Application Support data, preferences and keys. It does not switch Apple accounts or share API keys between logins.

Both users' processes can remain active with Fast User Switching, but their API listeners still share the Mac's network ports. For example, use port **7861** for the full sender and **7862** for the observer, and point each integration at the corresponding port and key. Choose access and network binding separately in each login. The relevant signed-in session and BBC app must stay running for its API and webhooks to operate.

SIP and library validation are settings for the whole Mac. Read-only mode does not require changing them; a Full API native bridge uses the host setup described in [native-bridge.md](native-bridge.md). Separate logins and BBC's mode guard do not provide the isolation of separate Macs or virtual machines. Read-only mode restricts BBC's operations; it does not prevent the account owner or another application from using Messages independently.
