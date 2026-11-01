# API access controls

The Mac app has a native sidebar with Overview, API Server, API Keys, Permissions, Native Messaging and Startup pages. Configuration belongs to the current macOS login.

## Allowed clients

In **API Server → Allowed clients**, enter numeric IPv4/IPv6 addresses or CIDR network ranges, one per line. Commas and whitespace also separate rules. For example:

```text
127.0.0.1
::1
192.168.1.0/24
fd00::/8
```

Stop the API before changing connection settings. Invalid rules prevent startup. An empty list permits any peer that can reach the configured listener; loopback binding still restricts access to this Mac. Rules are shared by all keys in this login. At most128 rules fit within8KiB.

BBC checks the TCP connection's peer address before authentication. Rejected peers receive403 `client_address_denied`. `Forwarded` and `X-Forwarded-For` headers are ignored. Behind a reverse proxy, allow the proxy's address and enforce original-client restrictions at that proxy. Address rules supplement API keys; they never replace authentication.

## Key permissions

In **API Keys**, create a key with **Read-only** or **Full access**, or edit an existing key's access level. The create dialog defaults to read-only. Existing keys created before access levels were introduced retain full access. Unknown stored access values are treated as read-only.

Read-only keys permit message history/search/status, attachment downloads, local media preparation and webhook subscription management. They cannot send, upload, react, mark read, type, change groups/messages, query native availability or manage scheduled sends. Rejected calls return403 `key_readonly`, before creating or replaying mutation receipts. Existing operation receipts can still be read for reconciliation. Status includes `key_access` and filters methods for both the key and the account mode.

The account's read-only mode is an upper limit: a full-access key cannot bypass it. Permission edits keep the same secret and take effect for new calls immediately. A downgrade cancels active typing tasks and prevents pending scheduled sends from dispatching; already dispatched effects may finish. Webhook subscriptions remain allowed. Revocation prevents new authenticated calls.

Key secrets are shown once and saved only as hashes. Keys and connection settings remain private to each macOS user; no HTTP route can grant itself more access or change address rules.
