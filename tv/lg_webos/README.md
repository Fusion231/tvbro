# LG webOS TV client

This build uses the same TVBro UI and canonical Dart core as the Samsung web
client. The intended initial qualification target is webOS TV 4.x and later.
JavaScript is downlevelled for Chromium 38 and checked as ES5 so webOS TV 3.x
can be evaluated as a compatibility candidate. LG lists Chromium 38 for 3.x
and Chromium 53 for 4.x in its [engine specifications](https://webostv.developer.lge.com/develop/specifications/web-api-and-web-engine).
No LG television has been tested for this build; syntax checks and a generated
IPK do not confirm model compatibility. webOS 1.x and 2.x are outside this target.

The build reads `../samsung_web/ui/` on every run. It reuses the compiled core
and verifies its original source hashes and `reuse-proof.json`. Profiles, PINs,
source parsing, M3U/Xtream/Stalker catalogues, guide handling, organization,
favorites, history, resume, cloud pairing and cloud sync use the shared modules.
The HTML is generated from the shared page, with an HTML video element, the
LG player and storage bindings, and the official webOSTV.js library. It contains
no Samsung WebAPI script, AVPlay adapter, or Tizen manifest. The shared UI is
not copied into this source directory.

Series details include the shared watched count, last watched episode and
next/resume action. The canonical Dart selection uses this TV's protected
profile history and cached catalogue, and refreshes when playback returns.
Incomplete season/episode pages cannot imply that the entire series is watched.

LG adapters provide HTML media playback and encrypted IndexedDB storage.
Initialization verifies a persisted non-extractable AES-GCM key before the UI
starts. Missing WebCrypto, IndexedDB, or persistent CryptoKey support stops
initialization; there is no plaintext source/profile fallback. Whether a
particular TV preserves these keys and encrypted data across app/TV restarts
still requires device qualification. Browser storage deletion also deletes
TV-local data. This provides software protection within the app origin, not a hardware
keystore. Catalogue snapshots use the same encryption provider, with 64 MiB
total ciphertext and 128 metadata entries. Complete live, movie and series
catalogues use atomic generations of at most 128 parts, each bounded to 1 MiB
stored and decoded. Profitable parts use gzip with bounded decode and CRC checks;
a failed or oversized replacement leaves the previous generation intact.
Primary catalogues take precedence over derived guide and metadata snapshots:
writing derived data must not force another provider download at the next launch.
When both cannot fit, the optional guide snapshot is skipped; the raw guide file
remains available in the separate service cache. Legacy 32 MiB snapshots remain
readable; complete M3U media hints are promoted without another playlist request.
XMLTV files use a separate LG
JavaScript-service cache under the service's private
`/media/internal/online.tvbro.webos.epg/` directory. The cache is limited to
512 MiB per guide, 768 MiB total and 8 records; guide reads are served in
bounded 64 KiB chunks through the webOS service API because service files are
not directly accessible from web apps. Cached XMLTV/gzip bytes are not
AES-GCM-encrypted; their boundary is the webOS service jail. Source/profile
and catalogue records remain in the encrypted IndexedDB store. Disk-mode
download accepts up to 512 MiB of raw guide data and streams decompression and
parsing with the shared 4 GiB decoded-workload limit. The 32 MiB limit applies
to in-memory fallback data and legacy catalogue items, not chunked catalogues
or the disk guide path. The
service uses webOS TV's Node.js runtime (0.12.2 on webOS TV 3.x/4.x), so its
APIs and storage persistence still need qualification on real TVs. Existing
paged catalogues, bounded guide rows, worker parsing and artwork scheduling
are retained. See LG's [JavaScript service guide](https://webostv.developer.lge.com/develop/guides/js-service-usage)
and [service FAQ](https://webostv.developer.lge.com/develop/guides/js-service-faq).

First use prepares live TV, movies, series and an EPG attempt before returning;
failed sections leave successful content available with a warning. Later starts
show saved content first and refresh due sections in the background. Catalogues
use Android's 24-hour policy; EPG uses six hours from the actual feed download,
with failed requests deferred rather than retried on every navigation.
Movie and series metadata reuse the original Android provider clients, merge
rules, configuration and language, with a separate encrypted cache. The bundled
service supplies bounded HTTPS metadata requests to the exact supported API
routes for TMDB, TVDB, MDBList and TVmaze, avoiding browser CORS restrictions.
Visited Source details and child pages stay with the primary generation under
the existing optional text-size and 128-read limits. Large optional reads are split
into bounded segments before encryption; complete roots remain separate.

Playback depends on the TV's native codecs, transport and track APIs. Xtream
films and episodes use the canonical resolved URL directly in the LG player,
without a relay or extra server. The library identifies this source/content
path and allows the single default VLC User-Agent added by TVBro to be replaced
by the native browser User-Agent. The exact default value, non-live stream,
and trusted playback context must all match; source URLs and header objects
remain unchanged. Other/custom headers (including M3U and Stalker headers)
are still rejected when the native player cannot send them. A provider that
actually requires a particular User-Agent still needs device/provider qualification;
this change does not emulate Samsung's arbitrary header support. LG documents
the [fixed browser User-Agent](https://forum.webostv.developer.lge.com/t/how-i-can-set-custom-user-agent-for-my-webos-app/1131).
Audio and
subtitle controls are exposed only when the platform reports support. The
Samsung AVPlay buffer setting has no equivalent tuning in the LG video API.
Local encrypted backup import/export is unavailable: LG TV web apps do not
provide the native file access used by the Samsung implementation. Those
controls stay disabled; shared backup encryption and cloud recovery logic are
reused. These platform gaps prevent a claim of full playback/file parity.

Cloud configuration is read from the same compiled `CloudConfig` and optional
`../samsung_web/publisher.config.local.json` as the Samsung client. The public
API/panel origins, client identifier, encryption protocol and opt-in provider
relay policy are reused. Never package private backend keys. LG cloud pairing
and provider behavior require later end-to-end qualification.

## Build

From the repository root, with the existing Flutter/Dart SDK and Samsung build
dependencies installed:

```powershell
./app/tv/samsung_web/core_builder/build.ps1
node app/tv/lg_webos/tools/build.cjs
node --test app/tv/lg_webos/test/*.test.cjs
node app/tv/lg_webos/tools/package-ipk.cjs
```

For a fresh checkout, install only the existing locked dependencies with
`npm ci --ignore-scripts` from `app/tv/samsung_web`; no separate LG dependency
tree or dependency upgrade is needed. The existing SDK/tooling locations are:

- `evaluation/tooling/webos-cli/node_modules/@webos-tools/cli/bin/ares-package.js`
- The SDK's `files/templates/tv-sdk-templates/bootplate-web/webOSTVjs-1.2.13/webOSTV.js`

Other official installations can be selected with `TVBRO_WEBOS_PACKAGE_CLI`
(the absolute path to `ares-package.js`) and `TVBRO_WEBOSTV_JS` (the absolute
path to `webOSTV.js`). The package script runs the real LG tool with
`--no-minify`, using local CLI state under the ignored output directory.

Generated files live under `app/tv/output/lg-webos/`. `latest-build.json`
records current application and service source hashes, the canonical core
proof, and the unconfirmed physical-test status. All packaged web-app
JavaScript, including the SDK library, must parse as ES5; CSS uses the shared
legacy layout gate. The package script rechecks the source and payload hashes
before and after packaging and verifies every web-app and service file, plus
the service ID, inside the actual IPK archive. Web-app and service JavaScript
must both parse as ES5. `latest-package.json` records
the IPK path/hash and explicitly keeps installation and certification false.
`--expected-manifest-sha <sha256>` can lock packaging to a captured build manifest.
The LG Store metadata requires an 80×80 `icon.png` and a 130×130 `largeIcon.png`;
the tracked copies in `assets/` are verified and copied into each staged package.

Storage contract tests use actual Node WebCrypto and structured CryptoKey
cloning with a transactional IndexedDB boundary fake. They do not establish
persistence support or performance on a television.

See [INSTALL.md](INSTALL.md) for the later Developer Mode installation workflow.
