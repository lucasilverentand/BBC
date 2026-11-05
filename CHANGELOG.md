# Changelog

## 0.1.0 — unreleased

The first downloadable release is being prepared. No notarized binary has been published yet.

- One Mac menu bar app with an embedded HTTP API, revocable keys and per-key access controls.
- Direct-chat threaded replies and Tapbacks, typing, read-state observations, media, webhooks, search and scheduled sends.
- Native group operations, message changes and multipart messages where the connected host supports them.
- Stronger reply-target loading, exact acknowledged-message confirmation and consistent thread-root metadata.
- An optional startup setting that opens Messages hidden and hides it after native bridge relaunches.
- Synthetic worker, bridge, receipt and HTTP regression suites that do not require an iMessage account.
- A separate optimized, Developer ID-signed and notarized packaging path with source-commit metadata and checksums.

### Platform and setup

The initial downloadable app targets Apple Silicon and macOS 26 or later. Source builds also require the toolchain and signing setup in [setup](docs/setup.md).

Advanced native features currently require the manual SIP and library-validation setup described in that guide. BBC does not change host protections. A notarized app does not establish live private-API compatibility or recipient delivery.

When replacing an Apple Development-signed source build with a Developer ID distribution build, macOS permission grants may need to be confirmed again. Keep local configuration and API secrets private; do not remove your stores merely to upgrade.
