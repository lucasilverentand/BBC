# Blue Bubble Club

Read [README.md](README.md) for the product and build entry point, [docs/api.md](docs/api.md) for API contracts, and [docs/development.md](docs/development.md) for native-adapter work.

- Keep BBC a standalone, self-hosted Mac app: one Swift executable, an embedded API and app-managed keys. Operators own network exposure. Keep execution local to the signed-in Mac.
- Preserve exact chat, message, attachment and reaction identities. Never recover an uncertain result by repeating a native mutation automatically.
- Keep automated tests synthetic. Live sends and reactions use only the conversation explicitly authorized in the current session; keep personal message data and live identifiers out of fixtures and public documentation.
- For the custom-picker repair, use one fixed emoji and exact message until the interaction works reliably. That reproduction case does not narrow the broader custom-emoji requirement.
- Distinguish CI, observed native state and recipient-visible acceptance. Accessibility permission alone does not establish a usable Messages window.
- Preserve the saved composition in `Assets/AppIcon.icon` and the app's stable signing identity when rebuilding or replacing the executable.
- The pinned adapter cache in `build/beeper-imessage` is generated. Persist adapter edits in `NativeMessages/beeper-bbc.patch`; follow the preparation script's patch checks.

Keep accepted project contracts and reusable native findings in these repository docs. Keep changing delivery and live acceptance in the issue tracker.
