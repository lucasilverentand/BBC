# API key access

Each API key has **Read-only** or **Full access** permissions, configured in **API Keys**. There is no app-wide account mode. Changes apply to new requests immediately without restarting the API. Existing keys from a read-only installation are migrated to read-only access, preserving their restrictions.

Read-only keys support history, search, status, attachments, local media preparation and webhook management. Sending, uploads, reactions, typing, message changes, native availability checks and scheduled-send operations return HTTP 403 `key_readonly` before creating or replaying mutation receipts. Existing receipts remain readable. Status reports the key’s effective access in `key_access` and `operating_mode`, with filtered methods.

Full-access keys enable supported message actions, subject to the Mac’s permissions and native capabilities. A login with only read-only keys needs Full Disk Access; it does not need Automation or the native bridge. Native connection controls appear when a full-access key exists. Scheduled sends check the owning key’s access before dispatch.

## Two accounts on one Mac

Use separate macOS logins for different Messages accounts. Sign each login into its own Messages account, launch BBC there and create that login's API keys. BBC uses the current user's `~/Library/Messages/chat.db`, private Application Support data, preferences and keys. It does not switch Apple accounts or share API keys between logins.

Both users' processes can remain active with Fast User Switching, but their API listeners still share the Mac's network ports. For example, use port **7861** for the full sender and **7862** for the observer, and point each integration at the corresponding port and key. Choose access and network permissions separately for each key. The relevant signed-in session and BBC app must stay running for its API and webhooks to operate.

SIP and library validation are settings for the whole Mac. Read-only access does not require changing them; the native bridge uses [BBC's host setup](setup.md#native-messaging). Separate logins and API key permissions do not provide the isolation of separate Macs or virtual machines. Read-only keys restrict API operations; it does not prevent the account owner or another application from using Messages independently.
