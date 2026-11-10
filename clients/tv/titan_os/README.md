# TVBro — Titan OS

A hosted HTML5 variant built directly from the Samsung Web client. Each build
reads the current `../samsung_web/ui/`, shared platform modules, the original Dart
core and the panel's existing validation/cryptography modules. It does not copy
screens, parsers or rules for profiles, sources, EPG, favourites, history and sync.
The source hash and `reuse-proof.json` must match the compiled core.

The Titan layer adds HTML5 playback, remote bindings and app exit handling.
Playback uses the LG variant's existing HTML5 engine without duplicating its
lifecycle. Encrypted IndexedDB storage, catalogue caching, the conservative
32 MiB XMLTV limit and file backup restrictions also use the same modules.
The payload contains no Samsung AVPlay, Tizen manifest, webOSTV.js or APK/WGT/IPK
packages. It does not need to download an external SDK at startup.

## Building

From the repository root, using the existing tools:

```powershell
./clients/tv/samsung_web/core_builder/build.ps1
node clients/tv/titan_os/tools/build.cjs
node --test clients/tv/titan_os/test/*.test.cjs
```

You can skip compiling the core if its reuse proof is still current.
The builder rejects changed sources or an inconsistent core. Build dependencies
are the existing `samsung_web` dependencies; a fresh checkout requires
`npm ci --ignore-scripts` there, with no separate Titan dependency tree.

Output: `clients/tv/output/titan-os/payload-<timestamp>/`.
`clients/tv/output/titan-os/latest-build.json` identifies the current directory,
input and output hashes, and the unconfirmed physical TV test status.
JavaScript passes the existing ES5 gate and retains the CSS restrictions.
`hosting.json` is our release metadata, not an official Titan manifest.

## Hosting and test installation

Copy the entire contents of `payload-<timestamp>` to a static server, preserving
subdirectories. The app URL points to `index.html`. Do not publish the repository,
publisher configuration files or `latest-build.json`.
The payload contains only public client configuration from the shared builder;
never add private backend keys.

Use a dedicated, stable HTTPS origin for Titan. WebCrypto requires a secure
context, and changing the origin creates a different data store. Shared modules
retain the LG variant's existing IndexedDB database names; do not host independent
LG and Titan clients on the same origin. Serve JavaScript with the correct MIME
type, including the worker; all asset paths are relative. During updates, avoid
mixing files from different builds through HTTP caching.

The hosted client is subject to CORS and mixed content policies. The API server
and playlist, EPG and metadata providers must allow the app's origin, and their
HTTP URLs may be blocked from HTTPS. We do not automatically enable a proxy or
send provider data through another server. The existing relay still requires
separate configuration and explicit activation.

Add the test URL in Titan Partner Portal/DevView. Store publication requires a
separate submission and QA. This local build is neither an installation nor a
publication. Vendor instructions: [HTML5 and URLs](https://docs.titanos.tv/introduction),
[DevView](https://docs.titanos.tv/devviewinstall),
[app submission](https://docs.titanos.tv/publishing).

Direct HTTP source, EPG and playback URLs are rejected locally before a request.
This also applies to saved sources and movie/channel URLs returned by an HTTPS
API. Help in Settings explains this limitation. If a provider supports only HTTP,
this hosted Titan version cannot connect without a separately deployed, trusted
transport solution; the app does not enable one itself. Native Android, Windows,
Samsung and LG paths retain their own HTTP handling.

## Behaviour and qualification

- Philips Back `8` and JVC Back `461` use shared navigation; Play/Pause `179`
  uses the shared player controls. Back on the home screen opens an exit
  confirmation with cancel selected by default. Exiting saves the cache and
  stops playback, then uses `SmartTvA_API.exit()` or a confirmed window close.
- Startup checks for a persistent, non-exportable AES-GCM key in IndexedDB.
  Missing APIs or a write failure stop startup; there is no plaintext storage
  fallback. API availability and persistence need checking on the target TV model.
- Playback uses native `<video>` and the TV's codecs. HLS/DASH, audio, subtitles
  and seeking must be checked on a physical TV. We do not add DRM licence
  acquisition. Available controls depend on detected capabilities.
- HTML5 cannot send arbitrary stream headers. Only the existing narrow exception
  for the default VLC User-Agent in trusted Xtream movie/episode playback is
  retained. Other required headers and native buffer tuning produce an explicit
  error instead of pretending playback is supported.
- File backup import/export and launching external trailers remain unavailable.
  Titan App Control requires an SDK and permission to launch apps; we do not
  replace it by redirecting the current page.

Host tests check code reuse, parsers/worker, the player contract, remote mapping,
data persistence and exiting. The browser test `test/browser_qa.js` runs with
the existing `../samsung_web/test/ui_browser_server.cjs <payload-path>` through
`playwright-cli run-code --filename`. It uses a synthetic local provider.
None of these results confirms decoder operation, storage persistence after
powering off the TV, or Titan certification.

## Local results — 27 October 2026

The build produced 30 files. Titan tests: 16/16; regression tests for the LG
player, storage and platform, plus shared UI navigation, startup and focus: 48/48.
The Chrome check passed without page or console errors: 161 M3U channels,
restored profile and favourites, the same persistent AES-GCM key after reloading,
no playlist refetch, correct Back handling, and exit cancellation/confirmation.
The only stubbed native boundary was the final `SmartTvA_API.exit()` call.

The `tvbro-titan-os-20261027T202721901Z.zip` archive in the generated
`clients/tv/output/titan-os/` directory contains the 30 verified payload files
(3 211 754 B).
SHA-256: `8e0eceb3c6065c3100e6f973fbee9737ab84893847bba39ee8ed4f4b0af410fc`.
This release was not run on a physical TV or published.
