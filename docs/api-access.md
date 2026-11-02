# API access controls

The Mac app has a native sidebar with Server, API Keys, Logs and Settings pages. Server contains permissions and the native connection, including its automatic startup toggle; Settings contains the port, login and API startup options. Configuration belongs to the current macOS login.

## Network access

Network access is configured per key. New keys are **Local only**. Open a key and enable **Allow network access** to allow other devices to use it. Existing keys inherit the former app-wide network setting on upgrade. Changes apply to new requests immediately.

The app listens on all IPv4 interfaces; token authorization restricts local-only keys to loopback peers. Client IP/CIDR rules apply in addition to that restriction. Forwarded headers never grant network access. A proxy on the same Mac appears as a local connection, so restrict access at that proxy as needed.

## Allowed clients

In **API Keys**, create or edit a key and under **Allowed clients**, enter numeric IPv4/IPv6 addresses or CIDR network ranges, one per line. Commas and whitespace also separate rules. For example:

```text
127.0.0.1
::1
192.168.1.0/24
fd00::/8
```

Rules can be edited while the API runs and apply to new requests immediately. Invalid rules prevent saving the key. An empty list permits any peer eligible under the key’s network setting. Each key has its own rules. Existing keys inherit the previous app-wide rules on upgrade; new keys start with an empty list. At most128 rules fit within8KiB.

BBC checks the TCP connection's peer address after authenticating the token, before dispatching any request. Rejected peers receive 403 `client_address_denied`. `Forwarded` and `X-Forwarded-For` headers are ignored. Behind a reverse proxy, allow the proxy's address and enforce original-client restrictions at that proxy. Address rules supplement API keys; they never replace authentication.

## Key permissions

In **API Keys**, create a key with **Read-only** or **Full access**, or click an existing key to edit its name, access and network settings. The create dialog defaults to read-only. Existing keys created before access levels were introduced retain full access. Unknown stored access values are treated as read-only.

Read-only keys permit message history/search/status, attachment downloads, local media preparation and webhook subscription management. They cannot send, upload, react, mark read, type, change groups/messages, query native availability or manage scheduled sends. Rejected calls return403 `key_readonly`, before creating or replaying mutation receipts. Existing operation receipts can still be read for reconciliation. Status includes `key_access` and filters methods for the key.

Permission edits keep the same secret and take effect for new calls immediately. A downgrade cancels active typing tasks and prevents pending scheduled sends from dispatching; already dispatched effects may finish. Webhook subscriptions remain allowed. Revocation prevents new authenticated calls.

Key secrets are shown once and saved only as hashes. Keys and connection settings remain private to each macOS user; no HTTP route can grant itself more access or change address rules.

To revoke a key, open its settings, choose **Revoke key…** and confirm. Its integrations lose access to new requests; already dispatched operations may finish. New secrets are shown only once, with a copy action before dismissal.

## Key rotation

Open a key and choose **Rotate key…**. Save any pending settings changes first. Confirm to replace its secret immediately, then copy the new secret and update your integrations. It is shown once, and the old secret stops authenticating new requests as soon as the replacement is saved. No API restart is needed.

Rotation preserves the key ID, name, creation date, access, network rules, operation receipts, webhook ownership and scheduled-send ownership. Already dispatched operations can finish. Only the new secret’s hash is saved; secrets are not logged. Rotation has no overlap period, so integrations need the replacement secret before they can resume calls.
