# Native API research provenance

BBC implements its own native library and authenticated local protocol. It has no BlueBubbles source, binary, runtime service or build dependency.

The initial private-API investigation used these architectural references:

- [BlueBubbles Server](https://github.com/BlueBubblesApp/bluebubbles-server), revision `76d2b2e786c04d7516de089f31be978a68da8083`.
- [BlueBubbles helper](https://github.com/BlueBubblesApp/bluebubbles-helper), revision `1ee57f3fde63f8cc5769d60cfabfe9a06fcc1069`.

These citations preserve the investigation's history. Neither project is an installation prerequisite or defines BBC's configuration. [BBC's setup guide](../setup.md) and current source define its host checks and connection lifecycle. Required third-party notices remain in [NOTICE](../../NOTICE) and [LICENSES](../../LICENSES).
