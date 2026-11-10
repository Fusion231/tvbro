# Smart TV clients

The Samsung, LG and Titan OS variants share a TV interface and a compiled Dart
core. Platform adapters handle playback, storage, remote controls and packaging.
Android/Google TV uses the Android app.

- [Samsung Tizen Web](samsung_web/README.md) builds a Samsung WGT package,
  targeting Tizen 3.0. It uses AVPlay, KeyManager and the Samsung remote.
  [Installation and signing](samsung_web/INSTALL.md).
- [LG webOS](lg_webos/README.md) builds an IPK with the shared UI, an HTML5
  adapter, encrypted IndexedDB and a disk-backed EPG service. It targets webOS
  4.x and later; 3.x depends on the required APIs. [Installation](lg_webos/INSTALL.md).
- [Titan OS](titan_os/README.md) builds a hosted HTML5 payload with LG's playback
  and storage adapters and Titan remote bindings. It requires a stable HTTPS
  origin and DevView test access.

Local builds and tests do not confirm compatibility with a particular TV.
Before publishing, check the model and OS, playback, audio and subtitles, remote
controls, encrypted data persistence after restart, and an extended session.
Each variant documents its limits for headers, CORS/TLS, file backups and native
features. [Current capability matrix](../../docs/platform-capabilities.md).

Test signing certificates and developer accounts belong to the publisher.
Regular users install an approved app from the TV store; a local WGT/IPK or
hosted payload does not mean certification or publication.
