# Tizen playback adapter

This package connects TVBro's existing MediaKit `Player` contracts to the
official `video_player_avplay` **0.8.22** plugin. It injects a public
`PlatformPlayer`; it never creates mpv, rewrites source resolution or reconnect
logic, or replaces the existing player/preview UI.

Register `createTizenPlayer`, `buildTizenVideo` and `isTizenPlayer` through the
app's playback registry in the Tizen bootstrap only. The generated TV wrapper
depends on this package by path and retains the owner's MediaKit git override
`c533e446755f51cf53c7e57aea873f2aa5355f81`. Do not add AVPlay to the owner's
root pubspec. The package does not require a MediaKit `VideoController`.

The real SDK `VideoPlayer` places native video under its transparent Flutter
hole; the adapter reuses the SDK's text/picture caption widget. TVBro controls
remain above that surface. Media and a single-entry Playlist, play/pause,
seek, volume/rate and available embedded tracks are supported. Subtitles off
hides the SDK captions. Unsupported operations and unsupported HTTP header
names fail explicitly; no credentials are silently dropped. Cookie/User-Agent
are forwarded both as HTTP headers and as the corresponding SDK streaming
properties. SDK position/duration retain their timebase for live progress.

For the current target, use `api-version="6.0"` and the internet privilege.
The plugin packages API-specific native libraries: its API 6.0 artifact is for
Tizen OS 6.0, not a universal artifact for every newer TV. Local files need the
appropriate storage privilege; this adapter adds no DRM configuration or
partner privilege. Native playback is unavailable on the TV emulator.

CPU tests validate state/control mapping and ownership during replacement or
dispose. They use SDK-controller doubles and do not demonstrate device playback.
A successful TPK build likewise requires a Samsung TV playback check before
claiming rendered video, codec coverage or runtime compatibility.

Primary sources:
- [Published AVPlay package](https://pub.dev/packages/video_player_avplay)
- [SDK source used for the adapter](https://github.com/flutter-tizen/plugins/tree/a16990269f9f9631412661c4fe7696ef8bca558d/packages/video_player_avplay)
- [Public MediaKit platform injection](https://github.com/media-kit/media-kit/blob/c533e446755f51cf53c7e57aea873f2aa5355f81/media_kit/lib/src/player/player.dart)
