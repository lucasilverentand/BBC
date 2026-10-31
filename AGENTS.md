# Agent guide

## Project knowledge

Start at [project guidance](docs/project-guidance.md) and read only the relevant linked topic. Keep accepted project requirements, decisions, reusable technical knowledge and agent instructions with the source. Use Notion for global/cross-project guidance and planning, and Linear for delivery and acceptance. Preserve proposal status, historical dates and outstanding acceptance gates. Do not treat a migration or past authorization as permission for new runtime operations.

This repository is public. Exclude personal account identities, private messaging data, credentials and operator infrastructure details from committed guidance.

## Native messaging

- Keep BBC one local Mac app with its Swift API and app-managed keys. A separately installed BlueBubbles Server is not part of the product.
- Runtime messaging must not click, navigate a picker, type into a composer or take over the mouse/keyboard. Use a native bridge; unavailable capabilities must fail without a UI fallback.
- Write BBC's own implementation. BlueBubbles is an architectural/API reference, not code or a binary to copy into BBC.
- Preserve exact chat/message/attachment identities and durable operation receipts. Never retry an uncertain native mutation automatically.
- Changes to SIP, library validation, signing policy or other host protections require explicit authorization. Status and builds must not change them.
- Preserve the accepted Icon Composer source and stable app signing identity.
