# Samsung testing status

## Missing EPG endpoint — device diagnosis, 2026-11-02

SDB and Web Inspector confirmed TVBro **0.1.32** on the owner's QE85QN85CATXXH
(Tizen 9.0 / Chromium 120). Unlike the earlier unsigned-package evidence below,
this is an observation of the currently installed version, not an installation
performed in this session or proof of its package provenance.

The Home → TV failure was reproduced without exporting provider URLs, response
bodies, credentials or private storage. The M3U playlist returned HTTP 200 with
803 channels and 16 categories. There was no explicit/additional EPG field or
guide URL in the playlist header. The inferred sibling `xmltv.php` returned
HTTP 404; a subsequent launch restored `[EPG:RETRY HTTP 404]` without a fresh
guide request. This is a guide-endpoint failure, not a failed channel download
or evidence of the earlier catalogue-export OOM.

With explicit owner approval, an ephemeral canonical Xtream Source was tested
on the TV using its existing configuration in memory only. Authentication and
the same 803-channel catalogue succeeded (HTTP 200); both XMLTV and the fallback
short-guide request for one channel returned HTTP 404. This does not establish
that every provider channel lacks EPG, but neither tested guide path recovered
programme data. No source conversion, cloud update, uninstall or data clear ran.
Restoring guide data requires a working provider/additional XMLTV address or a
provider-side correction; the application must not fabricate an empty success.

The local presentation fix distinguishes HTTP 404/410 from refusals, including
persisted retry causes, suggests checking the EPG address and explains that
channels can still be watched. Codes, original retry deadlines and refusal
handling are unchanged. Regression tests cover explicit and inferred addresses,
deferred reads without new requests, safe messages and playback after EPG failure.
The new 404/410 assertions failed before the fix. `npm run build` passed the
legacy ES5/CSS gates; `npm test` passed 367/369 tests, with no skips. The two
existing failures remain `avplay_contract.test.cjs` — "a pending screensaver
change is reconciled with stop and native failure", and
`platform_parity_contract.test.cjs` — "lifecycle sync stays off until explicit
setting, then flushes after stopping playback" (fixture lacks `stopPlayback`).
Payload: `payload-20261102T213935863Z`. The message fix is **not signed or
installed**; no successful real-provider EPG or physical playback validation is
claimed. A signed update still needs the owner's existing signing identity.

## 0.1.32 — unsigned derivative of the owner's 0.1.31 WGT, 2026-11-01

The owner supplied `TVBro-0.1.31-2DCI7KNSUL3M6.wgt` and its verification JSON.
The archive SHA-256 matched that receipt:
`ae16930e55afdcbf6e1ac8413aac2ba41260131b1296dfc992b9990c65321693`.
Its 28 author / 29 distributor file-reference digests and public certificate
fingerprints were independently checked. Signature cryptography was not rerun;
the supplied receipt records that earlier verification.

Unlike the checkout's former 0.1.26 manifest, this base contains a gzip stream
adapter and binary EPG transfer across the Worker boundary. Those adapter changes
were recovered into source before rebuilding, preserving the existing canonical
XMLTV parser and `_chunksOf` helper rather than hand-porting provider algorithms.
Normalized rebuilt transport/worker scripts match the supplied 0.1.31 scripts.
The reconstructed gzip regression failed with OOM before recovery and passes
afterwards (plain/gzip, bad CRC and decoded-size refusal, 128 MiB worker heap).

`config.xml` now declares 0.1.32 with unchanged application/package identity,
privileges and minimum Tizen version. The derived archive preserves **25 of 28
payload files byte-for-byte** from the supplied WGT, including polyfills, UI and
transport/worker. Only `config.xml`, `canonical-core.js` and `platform/library.js`
are replaced, adding the bounded catalogue export and rollback guard. The two
old signature XML files are removed, not reused for changed content.

Output on the owner's Desktop:
- `TVBro-0.1.32-2DCI7KNSUL3M6-unsigned.wgt` — 3,175,286 bytes;
  SHA-256 `c8cda01899649d8953bc5dd168b5665aaa1f3a1b2d31362ea64df42034f40dd6`.
- `TVBro-0.1.32-2DCI7KNSUL3M6-unsigned-verification.json` — per-file provenance,
  base checks, changed files, signing requirements and validation scope.

The exact derived payload passes the catalogue 192 MiB and EPG 128 MiB memory
regressions, a real Worker binary-message roundtrip with synthetic provider data,
and ES5 parsing for all 20 scripts. The source suite passes 364/366 tests with no
skips; the same two unchanged screensaver/lifecycle failures listed below remain.
The base receipt's larger historical test count is not claimed as rerun here.

**This WGT is unsigned and cannot yet be installed as a Samsung update.** No SDK
profile/private key was supplied; a signed package cannot reconstruct that key.
Signing must use the existing author identity and a distributor certificate for
the target TV. The DUID in the filename is lineage metadata, not authorization.
No installation, data deletion or physical test of this 0.1.32 WGT was attempted.

## Catalogue-export crash — fixed core tested in memory, not installed, 2026-11-01

SDB/Web Inspector identified the owner's current device as QE85QN85CATXXH,
Tizen 9.0 / Chromium 120, with TVBro 0.1.31 installed. At that time this checkout's
manifest was 0.1.26; it was deliberately not installed over that newer package. The former
signing environment/profile is absent from this computer. No uninstall, storage
clear, certificate replacement or persistent application-code modification ran.

The reported symptom was freezing/exiting after opening TV with "Loading guide".
Cold-load diagnostics also saw the source worker grow to 281,833,808 bytes of JS
heap after a 19,078,143-byte playlist response; the UI heap stayed near 5 MiB.
Later provider attempts timed out, so no end-to-end provider fix is claimed.
An independent, network-free fixture on the installed core isolated a failure:
one Live channel plus 20,000 distinct unnumbered series entries completed both
root reads, then lost the renderer/inspector connection during `exportCatalog`.
This does not require XMLTV, AVPlay or playback. The equivalent local regression
explicitly failed with JavaScript heap OOM under Node's 192 MiB old-space limit.

The fix avoids eagerly building UI metadata for every cached media item, encodes
models and JSON string layers through bounded UTF-8 chunks, and preserves schema
1 import. The 20,000-series fixture now exports a 30,647,711-byte snapshot under
that same Node limit; a larger Unicode variant returns null and retains Live.
Small roundtrip tests cover older enriched snapshots, unvisited seasons/episodes,
UI metadata projection and playback headers. A library regression ensures null
exports do not write over a prior generation or invalidate without rollback.

Final validation: the full packaged `npm test` run passed 362 of 364 tests, with
no skips. Two failures remain in unchanged playback/lifecycle tests:
`avplay_contract.test.cjs` — "a pending screensaver change is reconciled with stop
and native failure" (unexpected screensaver reset); `platform_parity_contract.test.cjs`
— "lifecycle sync stays off until explicit setting, then flushes after stopping
playback" (fixture missing `library.stopPlayback`). The 14 compiled Source
scenarios and the new bounded-cache regressions passed. `npm run build` passed
the ES5/CSS gates; final payload: `payload-20261101T215354642Z`.

On the physical TV, the newly compiled core was evaluated **only in an isolated
test worker's memory**, before creating its synthetic Source. The fixture finished
in 25 one-second sampling intervals, exported the same 30,647,711-byte snapshot,
and successfully read channels again. Maximum **sampled JS heap** was 59,275,544
bytes (not total process RAM or a guaranteed instantaneous peak). The worker was
terminated after the test. Core SHA-256:
`907b457099b5dba4cd778019b7325d7edb56fdd6cc8fc77e55e7f464309cee8d`.

This confirms the repaired export path on that TV, not a signed installation,
on-device filesystem roundtrip, real-provider EPG/playback, or old Tizen 3.0
qualification. Durable rollout requires the original author signing identity,
reconciling this checkout with installed 0.1.31, then a normal signed update and
a repeat of the owner's Home → TV scenario. Never uninstall to bypass signing.

## Remembered profile startup — 0.1.26, installed 2026-10-26

The owner's TV startup picker preference was changed from Auto to Never through
the existing authorized settings API after the owner unlocked the active cloud
profile on the TV. The choice is global and persisted in private KeyManager
state. For a remembered PIN-protected profile, startup now selects that profile
and opens its ordinary PIN prompt directly. Cancelling returns to the chooser;
incorrect PINs cannot open the profile. Unprotected profiles open directly.

All eight focused startup/selection contract checks passed. Browser cold-reload
QA passed six phases at 720p/1080p with no errors, including exact synthetic
KeyManager-state restoration, locked and unlocked remembered profiles,
cancellation, wrong/correct PIN and unchanged Auto/Always behavior. Logs:
`D:/tvbro/output/samsung-profile-startup-20261026.log` and
`D:/tvbro/output/final-profile-startup-browser-20261026.log`.

Concurrent unrelated source work changed generated payloads during preparation.
The installed release therefore derives from the hash-verified installed 0.1.25
payload, changing only `routeAfterLanguage` in `app.js` and the manifest version.
ES5/CSS gates and the browser journey passed on this exact isolated payload:
`payload-20261026T104945087Z-profile-startup`. Its derivation and captured hashes
are in `tv/output/samsung-web/profile-autostart-20261026/selected-build.json`;
the shared `latest-build.json` describes other ongoing work.

Signing proof:
`tv/output/tizen-builder/20261024/samsung-web/20261026T105043624520018/proof.json`.
Installation and normal launch were accepted with the same author certificate
and device profile, without uninstalling the application. Receipt:
`tv/output/tizen-builder/20261024/samsung-device-20261026/signed-20261026T105134744320Z/result.json`.
The TV's post-update bootstrap confirmed Never and the same remembered cloud
profile. Configuration receipts:
`tv/output/samsung-web/profile-autostart-20261026/set-result.json` and
`restart-result.json` in the same directory. This runtime read found the profile
already unlocked; the direct PIN startup path is covered by browser cold-reload QA.

## Continuous series catalogue — 0.1.25, installed 2026-10-26

The series catalogue has no pagination controls. Scrolling near its bottom or
moving past the last loaded row with the remote appends the next canonical
provider page. Existing cards, focus and scroll remain in place; local search
results are revealed in batches. New category/search selections reset the
list and discard obsolete reads. Failed appends keep the loaded list and offer
an explicit retry. Movie and favorite pagination are unchanged.

All 45 focused series-scroll/details/Back/player checks passed. Packaged browser
QA passed all eight phases at 720p and 1080p with 96 series across seven provider
pages, one catalogue read at a time and no browser errors. It covers remote
handoff, details Back, end-of-list, delayed category responses, local search,
loading visibility, error/retry focus and movie pagination. Logs:
`D:/tvbro/output/samsung-series-scroll-20261026/contracts.log` and
`final-browser.log` in the same directory.

Payload `payload-20261026T102404754Z` was signed with the existing
`TVBroSamsungTV` profile; staged/archive hashes matched the source payload.
Proof: `tv/output/tizen-builder/20261024/samsung-web/20261026T102522180618734/proof.json`.
The initial attempt stopped at connection: `192.168.10.53:26101` was unavailable
from both the prepared SDK and the Windows host. No install command ran in that
attempt. Receipt:
`tv/output/tizen-builder/20261024/samsung-device-20261026/signed-20261026T102631357214Z/result.json`.
After the owner confirmed that the TV was on with the same address, the update
was installed with the same author certificate and device profile, without
uninstalling the application. Installation and normal launch were accepted.
Receipt:
`tv/output/tizen-builder/20261024/samsung-device-20261026/signed-20261026T103252419600Z/result.json`.
This confirms installation and launch; physical remote behavior still needs
confirmation on the TV.

## Android-style media details — 0.1.24, installed 2026-10-26

Movie and series details now use the original Dart `MediaInfo`, trailer and
source-hint helpers. The cinematic header, provider information and cast share
one vertical scroller; the underlying catalogue and category scrollbar are
hidden without losing their positions. Seasons start collapsed and expand into
horizontal episode cards with artwork, description, runtime and saved progress.
Only twelve cards are mounted per rail. Leaving playback restores the same
season, episode cursor and scroll position. Completed episodes retain their
watched state, but reopening them starts at the beginning. Fresh TMDB lookups
are disabled, following the owner's choice to use provider data.

All 25 focused metadata, details-state and native-trailer checks passed. The
final packaged details journey passed at 720p and 1080p with no browser errors,
including a 120-episode season, remote navigation across card windows, catalogue
scroll isolation and returning from playback. The full existing browser journey
also passed all twelve phases on the preceding details candidate. The full
contract run passed 225/227 checks, with only the same two pre-existing
catalogue-store fixture failures documented below. The final resume correction
also passed the existing favorites/history/resume integration test.
Logs: `D:/tvbro/output/samsung-details-20261026/final-focused.log`,
`final-browser.log`, `browser-regression.log` and `contracts.log`.

Final payload `payload-20261026T100657433Z` was signed with `TVBroSamsungTV`;
source, staged and archived payload hashes matched. Signing proof:
`tv/output/tizen-builder/20261024/samsung-web/20261026T100837131540735/proof.json`.
The update was installed with the same author certificate and device profile,
without uninstalling the application. Installation and normal launch were
accepted. Receipt:
`tv/output/tizen-builder/20261024/samsung-device-20261026/signed-20261026T100858821945Z/result.json`.
These checks establish the software behavior and accepted installation/launch;
the new details still need physical-TV confirmation.

## Consecutive arrow channel changes — 0.1.23, installed 2026-10-26

Live loading and buffering no longer automatically show the transport controls
and redirect subsequent arrows into UI navigation. Player readiness preserves
an explicit OK/Info choice made while the next channel is loading. Real pause,
playback failure and VOD completion retain automatic control visibility.

Three new regressions fail against the previous UI and pass with the fix.
All 35 focused player/Back/guide tests passed. The packaged 720p/1080p browser
journey passed without errors, including consecutive Up/Down switches without
hiding the panel between presses, a later buffering event, and explicit OK.
Logs: `D:/tvbro/output/samsung-zap-20261026/tests.log`, `before-tests.log` and
`browser.log` in the same directory.

Signed payload `payload-20261026T092110297Z` was installed as an update with the
same author certificate and device profile; no uninstall/data-clear command
ran. Installation and normal launch were accepted. Receipt:
`tv/output/tizen-builder/20261024/samsung-device-20261026/signed-20261026T092421093581Z/result.json`.
This is installation/launch evidence; physical remote behavior still needs
confirmation on the TV.

## Channel list and EPG performance — 0.1.22, installed 2026-10-26

The guide now reuses its forty-row window, retains focus across window changes,
and groups programmes once. The ordinary list is mounted only when selected;
both views request missing visible EPG rows rather than an eighty-channel page.
Catalogue/guide snapshots are written after readiness and drained before source
disposal. Reopening the active source skips an unchanged profile write. Known
oversized successful responses are rejected at HTTP headers; provider refusal
classification, cooldowns and request spacing are preserved.

A packaged browser comparison used 10,000 channels and sixfold CPU throttling:
list readiness 633 → 336 ms, guide readiness 978 → 529 ms, 60 remote Down keys
2956 → 682 ms. A 24-pixel scroll changed 1480 created/removed rows to zero;
the same scroll workload took 5549 → 777 ms. These are host Chrome measurements
with synthetic provider/SDK boundaries, not timings from the physical TV.
Evidence: `D:/tvbro/output/samsung-guide-20261026/comparison.json`.

The full packaged 720p/1080p browser journey passed with no browser errors.
The complete contract run passed 200/202 checks, retaining only the two
pre-existing catalogue-store fixture failures documented below. Regressions
include blocked disk writes, concurrent flush/disposal, provider refusal and
size handling, 10,000-channel rendering, focus and continuous remote navigation.
Logs: `D:/tvbro/output/samsung-guide-20261026/contracts.log` and
`browser-regression.log` in the same directory. Tested payload:
`payload-20261026T090022072Z`. Its manifest was advanced to 0.1.22 and repackaged
as `payload-20261026T090631277Z`, signed with the existing `TVBroSamsungTV`
profile and installed over the existing application. The author certificate
and device profile were unchanged; no uninstall or data-clear command ran.
All packaged source hashes matched the staged build. Installation and normal
launch were accepted with exit code zero. Receipt:
`tv/output/tizen-builder/20261024/samsung-device-20261026/signed-20261026T091219322209Z/result.json`.
This confirms installation and launch, not physical-TV performance or a
playback session longer than twenty minutes.

## Player stability and remote controls — prepared 2026-10-26

The prepared player update fixes fullscreen DOM/native rectangle ordering,
retains rectangle changes during a seek, and bounds a lost seek callback to
ten seconds. Live inactivity is checked after 30 seconds against the native
clock, with at most two provider-admitted reconnects per user open. These
changes do not establish the cause or resolution of the owner's reported
20-minute hardware freeze.

The controls now follow Android TV's top title/live/clock and bottom transport
layout, with audio/subtitle shortcuts and VOD progress. Hidden Left opens the
paged channel list, Right recalls the last successfully started channel, and
digits plus OK select a channel. Channel-key bursts settle for 600 ms before
opening one stream. Pending selection is cancelled by dialogs and leaving
playback; horizontal navigation reaches wrapped translated actions.

The full packaged browser journey passed at 720p/1080p with no browser errors,
including preview/fullscreen reuse, idle handoff, channel-key bursts, numeric
selection, quick list, previous-channel and existing VOD/EPG/profile paths.
AVPlay tests include 25 minutes with a simulated clock, silent-stall recovery,
retry limits, provider refusals, pause/stop cancellation and seek races.
The contract run passed 174/176 tests; the same two pre-existing catalogue
store fixtures described below still fail. Log:
`D:/tvbro/output/samsung-player-20261026/contracts.log`.
These player changes are included in the signed and installed 0.1.22 update
above. A physical-TV playback session longer than 20 minutes remains outstanding.

## EPG recovery — 0.1.21, installed 2026-10-26

Signed payload `payload-20261026T070847044Z` was installed and launched on the
owner's Samsung. The full XMLTV response exceeded the browser memory limit;
the canonical Xtream window reader recovered through `get_short_epg`.
The physical guide showed 12 programme cells with no error. API responses were
200, maximum concurrency was one, and starts were spaced about one second apart.
Two subsequent reads for eight visible channels returned nine programmes each
with **zero additional provider requests**.
The fallback caches channels for ten minutes (including across restarts), pauses
failed XMLTV/API reads for fifteen minutes, and never falls back after 401/403/429.
Validation: eight native Dart tests, seven compiled-core fallback/cache tests,
73 regression tests, and the existing browser journey at 720p/1080p passed.
Receipt: `tv/output/tizen-builder/20261024/samsung-device-20261026/signed-20261026T070932049216Z/result.json`.
This recovers the short schedule supplied by the channel API, not a full archive
or a multi-day schedule when the provider's XMLTV is unavailable.

Prepared startup adjustment (not installed): Live AVPlay requests four seconds
of initial media instead of relying on the documented approximately ten-second
default. The recovery buffer, native timeout and HTTP-refusal guard remain in
place. Firmware that rejects the tuning retains its defaults. All 41 focused
AVPlay/facade/transport checks passed, including HTTP-refusal behavior. This is
a source/configuration fix, not a measured improvement on the physical TV.
The staged browser flow confirmed that Live sends `PLAYER_BUFFER_FOR_PLAY=4`
before preparation and preview/fullscreen reuse one native open, with no browser
errors. The current staged payload is `payload-20261025T213933591Z`; it is not
a newly signed or installed TV release.

The subsequent history fix returns native playback readiness immediately and
flushes pending history on stop/dispose or history reads. The packaged browser
fixture now reveals fullscreen while KeyManager is deliberately held, retains
one native open, and persists history after release. Artwork has a two-transfer
limit, one start per host per second, and a one-minute pause after three image
failures. Direct image events cannot distinguish 403 from other failures.
These changes are staged and browser-tested, not installed or timed on the TV.
Evidence: `D:/tvbro/validation/samsung-startup-20261025/remaining-ui.log`.

Update 0.1.18 opens the TV list before playing a live Home-history entry, so
leaving fullscreen returns to TV and restores focus there. EPG XHR now reads
binary bytes rather than `responseText`; gzip XMLTV files without HTTP
`Content-Encoding` reach the canonical decompressor intact. Plain XML,
HTTP refusal classification and the existing size limit remain covered.

The gzip regression failed before the transport change. All 14 transport
checks and four focused EPG error checks passed after it. The complete
packaged browser journey passed with a real gzip HTTP fixture, rendered
programmes and the history-to-TV Back/focus assertions, without browser errors.
The complete contract run passed 128/130 checks; the two existing catalogue
store fixtures described under 0.1.13 still fail and are outside this change.
Evidence: `D:/tvbro/validation/samsung-history-epg-20261025/`.
The signed 0.1.18 package was installed and normal launch was accepted on the
same Samsung; receipt:
`tv/output/tizen-builder/20261024/samsung-device-20261025/signed-20261025T212320378251Z/result.json`.
The user's specific provider guide has not yet been confirmed on hardware.

Update 0.1.17 adds dedicated Samsung Channel Up/Down and Page Up/Down navigation
while fullscreen controls are visible, stable-ID channel lookup for history
entries, Android arrow order with hidden controls and end-to-start wrapping.
EPG now has one continuous scroll range for every filtered channel, with a
40-row render window and no channel paging buttons. AVPlay restores both DOM
and native display rectangles at preparation/playback/metadata changes, and
four opaque panes mask the native surface outside the embedded preview.

EPG retry state retains its fixed cause and original deadline across windows
and restarts. Deferred attempts do not restart the wait; the shared feed's
deadline remains recent in the bounded failure cache when scrolling through
many windows. The regression failed before the LRU correction and passed
after it. Local browser QA passed continuous scrolling to channel 161,
fullscreen channel keys/history, preview masks and the prior complete UI
flow. AVPlay checks passed 13/13; focused EPG checks passed 5/5.
Evidence: `D:/tvbro/validation/samsung-0.1.17-ui.log` and
`D:/tvbro/validation/samsung-0.1.17-avplay.log`.

The final LRU-corrected 0.1.17 package was Samsung-signed, installed and
normal-launch-accepted on the same TV after reconnecting its stale SDB session.
Receipt:
`tv/output/tizen-builder/20261024/samsung-device-20261025/signed-20261025T204544189560Z-retry-210057236339/result.json`.
A temporary one-shot EPG diagnostic received no guide event before expiry;
the ordinary package was then restored. No provider failure cause or actual
programme data was confirmed on hardware. Physical remote/preview behavior
and the displayed EPG result still require user confirmation. Debug launch
returned `closed`; normal launch succeeded.

Update 0.1.16 makes EPG the default embedded Live view, below the preview and
beside the category rail. Channel names, current programmes and empty guide
cells share preview-first activation. The guide/list control toggles in place.
Channels remain available when guide data is absent or cannot be fetched.
Guide errors now preserve a fixed failure category across the Dart/Worker
boundary and show a safe EPG code for timeout, network, size, invalid data,
HTTP refusal, deferred retry or unavailable functionality. Provider addresses,
credentials, XML and raw exception text are excluded. This improves diagnosis;
the cause of the user's physical-TV guide failure has not yet been confirmed.
The existing retry deadlines and memory limits are preserved.
The packaged UI scenario passed in 720p and Full HD, including the default
guide, empty EPG cells, preview/fullscreen handoff and catch-up. The four
focused error checks passed for malformed XML, HTTP 404, deferred retry and
transport size limits without disclosing provider credentials. The signed
update was installed and launch-accepted on the TV:
`tv/output/tizen-builder/20261024/samsung-device-20261025/signed-20261025T201828509028Z/result.json`.
Browser evidence: `D:/tvbro/validation/samsung-0.1.16-ui.log`.

Update 0.1.14 corrects the physical-TV scale reported on 0.1.13. All presentation
surfaces use a 1280×720 logical canvas with a 1.5× scale at 1920×1080; the native
AVPlay object remains outside the scaled UI. Preview coordinates are measured
after scaling. The separate fullscreen button is removed. As on Android TV,
the first OK starts preview without moving focus off the channel; a second OK
on that channel opens fullscreen, or a ready preview opens after 30 idle
seconds. Remote, focus and pointer activity restart the timeout; leaving Live,
dialogs, search, backgrounding and unavailable playback cancel it.
Browser QA passed scaling, native/DOM preview geometry, double-OK and idle
handoff without reopening the playing stream, activity reset and Home
cancellation, plus the existing complete UI flow at 720p and Full HD.
The 11 AVPlay contract tests also passed. Evidence:
`D:/tvbro/validation/samsung-0.1.14-ui.log`.
The signed update was installed and launch-accepted on the same Samsung TV:
`tv/output/tizen-builder/20261024/samsung-device-20261025/signed-20261025T195758801322Z/result.json`.
Rendered appearance and the idle transition on hardware await user confirmation.

Update 0.1.13 aligns the presentation with the current Android TV design:
compact Home tiles and icons, global actions on Home, a section Home control,
categories on the left, and a horizontal preview above the channel list.
Movie/series posters retain 2:3 proportions. Browser QA passed the Home,
Live and media layout checks at 1280×720 and 1920×1080, remote navigation,
preview/fullscreen handoff and the existing end-to-end UI flow without browser
runtime errors. The full contract suite returned 116/118 passes; the two
existing catalogue-store fixtures omit the byte-stream APIs now required by
the store and fail independently of the UI changes.
This update was Samsung-signed, installed and launch-accepted on the same TV;
receipt: `tv/output/tizen-builder/20261024/samsung-device-20261025/signed-20261025T194550731852Z/result.json`.
The launch receipt does not verify the rendered screen or playback on hardware.

Update 0.1.12 completes persistent guide caching alongside the 0.1.11 catalogue.
It uses the canonical six-hour EPG freshness and fifteen-minute failure retry
delay, retaining both raw guides and retry deadlines across app restarts.
Raw guide storage is bounded to eight feeds / 16 MiB per source within the
existing 64 MiB store budget. Cached metadata is flushed before source disposal,
app exit and on backgrounding; repeated reads share delayed catalogue writes.
Profile/source keys and snapshot checksums isolate and validate restored data.
An offline refresh keeps the previous guide; incomplete disk writes preserve the
previous complete generation. This release was Samsung-signed, installed and
launch-accepted on the same TV; receipt:
`tv/output/tizen-builder/20261024/samsung-device-20261025/signed-20261025T191014821438Z/result.json`.
Physical-TV restart persistence and full Android feature parity remain unverified.

All 118 automated tests pass. Validation covers cold runtimes with zero provider requests for cached channels,
media details and different EPG windows, persisted retry backoff, source changes,
corrupt snapshots and failed filesystem writes. Browser QA exercises the actual
packaged Worker/UI with synthetic Samsung SDK and provider HTTP. A 10,000-channel
fixture downloads once; 20 warm catalogue reads and 60 warm detail reads add no
provider requests. Host-browser timings are not TV performance measurements.
Local evidence: `D:/tvbro/validation/samsung-completion-tests.log`,
`samsung-completion-worker-cache.log`, `samsung-completion-ui.log` and
`samsung-completion-performance.log` in that same validation directory.

On 25 October 2026, a Samsung-signed baseline WGT was installed and launch was
accepted on a Samsung UE43M5672 (Tizen 3.0); the user confirmed that the UI was
visible. Evidence is in
`tv/output/tizen-builder/20261024/samsung-device-20261025/signed-20261025T095346440940Z/result.json`.
The WGT SHA-256 is
`f592d0bcc1882e4accce5f164ec0ecbaab9628ddc44b94a465d4d4021633b2de`.
This verifies install, launch, and initial UI visibility only. Runtime playback
and full runtime parity remain unverified. The onboarding/language-selection
update 0.1.1 (`payload-20261025T105610538Z`) has also passed browser QA, been
Samsung-signed, installed, and launch-accepted. Its device receipt is
`tv/output/tizen-builder/20261024/samsung-device-20261025/signed-20261025T105706658115Z/result.json`.
The user reported a generic operation error on 0.1.1. Diagnostic update 0.1.2
was installed and launch-accepted; it displays only a safe error class on boot
failure. The cause and end-to-end cloud pairing are not yet qualified.

Update 0.1.6 was Samsung-signed, installed, and launch-accepted on the same TV.
It adds the original QR encoder and automatic claim-to-profile selection.
Its device receipt is
`tv/output/tizen-builder/20261024/samsung-device-20261025/signed-20261025T122225849406Z/result.json`.
The user confirmed profile selection in 0.1.6 and reported freezing after
selection in 0.1.7. Update 0.1.8 was installed and launch-accepted; its receipt is
`tv/output/tizen-builder/20261024/samsung-device-20261025/signed-20261025T125744470193Z/result.json`.
It reuses saved cloud profiles and restores their active source, while Source
and PIN processing use a browser Worker. The user confirmed that 0.1.8 opens
the saved source and responds to the remote. No new test suites were written
or run for these updates.

Update 0.1.9 was Samsung-signed, installed, and launch-accepted after the TV at
192.168.10.53 became available. Its device receipt is
`tv/output/tizen-builder/20261024/samsung-device-20261025/signed-20261025T132940352802Z-retry-180409428337/result.json`.
Physical responsiveness remains pending user confirmation. Its release and one-off local browser measurements
are recorded in `tv/output/samsung-web/release-0.1.9.json` and
`tv/output/samsung-web/performance-0.1.9.json`. These measurements are not a TV
frame-rate or memory benchmark.

Update 0.1.10 was installed and launch-accepted on the same TV; its receipt is
`tv/output/tizen-builder/20261024/samsung-device-20261025/signed-20261025T181637735171Z-retry-181905773535/result.json`.
Profile selection reuses the already loaded cloud listing and the saved source,
falling back to the first source when an older snapshot has no valid active ID,
as native SourceStore does. Home shows loading instead of the source picker.
Player time updates reuse the event snapshot and notify the UI once per second;
fullscreen hides the shell only after playback and its display rectangle succeed.
One-off local browser inspection reached Home from a legacy snapshot and moved
preview to fullscreen and back with one stream open. These are fixture results;
physical responsiveness remains pending user confirmation. Evidence is in
`tv/output/samsung-web/release-0.1.10.json` and `performance-0.1.10.json`.

Update 0.1.11 adds a persistent catalogue in `wgt-private/tvbro_catalog_v1`
using the Tizen 1.0 Filesystem API (read/write privileges). It was signed,
installed and launch-accepted; receipt:
`tv/output/tizen-builder/20261024/samsung-device-20261025/signed-20261025T183849303370Z/result.json`.
The original Dart `LibrarySnapshot`, Source classes/DTO codecs and 24-hour
catalogue policy are reused. A complete saved catalogue is restored before
provider connection, including M3U guide/catch-up hints. Authentication happens
when playback, EPG or an uncached media read actually needs it. Due refresh runs
in the background; a failed refresh retains the saved list without a retry loop.
Keys include the profile owner and full source configuration; editing/removing
a source discards its former snapshot. Immutable generations and a completion
marker preserve the previous copy across interrupted writes; integrity/DTO
validation runs in the Source Worker. Files are limited to 32 MiB, with a 64 MiB
store budget. Storage failure keeps browsing usable and displays a warning.
One-off local checks used actual file bytes and SourceWorker messaging: fresh
M3U and Xtream runtimes with the synthetic provider offline returned their saved
channels with zero provider requests; corrupt latest data fell back to the prior
generation. These are local adapter checks, not physical-TV persistence proof.
Evidence: `tv/output/samsung-web/persistent-cache-worker-0.1.11.json` and
`persistent-cache-xtream-0.1.11.json`. No test files or suites were added or run.
Device data survives normal app/TV restarts; uninstalling removes private data
([Samsung file operations](https://developer.samsung.com/smarttv/develop/guides/data-handling/managing-file-operations.html)).

Artwork update 0.1.10 was signed, installed, and launch-accepted on the same TV.
It uses w342 thumbnails for large public TMDB posters, shares their URL between
cards and details, and falls back once to the original image on failure.
The device receipt is
`tv/output/tizen-builder/20261024/samsung-device-20261025/signed-20261025T181717427366Z/result.json`.
The artwork browser check passed; physical loading times remain unmeasured.
Release evidence is `tv/output/samsung-web/release-0.1.10-artwork.json`.

The browser XMLTV adapter has a 32 MiB body/decoded ceiling and retains one
download for the original six-hour EPG lifetime, committing only after parsing
succeeds. Oversized guides fail instead of using the native
disk-oriented 4 GiB ceiling in RAM. This is a guide limit, not a total app
memory guarantee.

Provider control traffic uses the original app-wide `ProviderRequestGate`,
including its one-second start gap, concurrency ceiling, refusal cooldown and
Retry-After policy. Only native host hashes/status/deadlines are persisted;
worker replacement does not clear that protection. Catalog freshness and EPG
failure deferral reuse the original 24-hour and 15-minute values. Artwork is
loaded near the viewport rather than eagerly for all rows.

## Build the web payload

From the application checkout:

```powershell
./tv/samsung_web/core_builder/build.ps1
Set-Location tv/samsung_web
npm ci --ignore-scripts
npm run build
npm test
```

The generated payload is written under the ignored
`tv/output/samsung-web/` directory. This workflow validates the web payload and
its contracts; it does not verify TV installation or playback.

## Cloud and relay configuration

A normal build takes the public backend URLs and public client identifier from
the application's compiled `CloudConfig` (`https://api.tvbro.online` and
`https://tvbro.online/`). To use a custom backend, place an
optional `publisher.config.local.json` in `tv/samsung_web/`. It is
git-ignored. Configure both `apiUrl` and `panelUrl` as production HTTPS
origins. The optional `anonKey` is restricted to the public value
`tvbro_public_client`; do not put private keys in the app.

Set `providerRelay` to `true` only when the build should request the
metadata-only provider relay. The deployed backend has
`SAMSUNG_TV_ENABLED=true`. Its health endpoint, local-widget preflights
(`Origin: null` and `Origin: file://`), and unauthenticated profile rejection
were checked. The user confirmed pairing-code generation on the TV; profile
download remains unverified. Relay use additionally requires
`TV_PROVIDER_RELAY_ENABLED=true`; the relay remains disabled and undeployed.

The isolated API release is pinned in Coolify to branch
`codex/samsung-cloud-origin-20261025`, commit `e265097f9cdaa76748f70dd0f9f1e37a2a3ead39`.
Future backend releases must deliberately update that source revision.

## Local data and unpairing

Unpairing disconnects the TV's cloud pairing and clears cloud-link bookkeeping.
It preserves local profiles, source configurations, favorites, settings,
history, and resume data in TV-local storage. Provider catalogs and guide data
are fetched as needed; offline media downloads are not implemented.

The signed baseline has not qualified AVPlay media playback, KeyManager
persistence, remote-control behavior, or store readiness.

## Samsung certificate and installation

For a test install, the publisher creates a Samsung TV certificate profile with
the Samsung Certificate Extension and a Samsung Developer account. Its
distributor certificate must include the target TV's DUID. Keep the profile,
private keys and passwords private. The generic local Tizen qualification
profile does not grant permission to install on a Samsung TV.

Read the TV IP from Settings > General > Network > Network Status > IP Settings
(menu names vary by model). The PC and TV must share the local network. In the
TV's Apps screen, enter 12345, enable Developer Mode, enter the **PC's** IP in
Host PC IP, and restart the TV. Add the **TV's** IP in Tizen Studio's Remote
Device Manager, connect, and obtain its DUID for the certificate profile.

After provisioning that real profile in the prepared SDK, package the locked
payload with `tools/package-wgt.sh --profile <profile-name>
--expected-manifest-sha <latest-build.json-SHA256>`. `--unsigned` instead creates
an explicitly unsigned archive; it cannot be installed as a Samsung test app.
The SDK and archive verification do not substitute for device installation.

For later builds, a network development session can install and launch the app
and inspect JavaScript/network errors and available player state through
Samsung's Web Inspector. Picture, sound, physical remote behavior, and storage
across real TV restarts still need qualification on the television.
[Samsung Web Inspector](https://developer.samsung.com/smarttv/develop/getting-started/using-sdk/web-inspector.html)
describes that debugging workflow.

For ordinary users, distribution is through Samsung Apps TV after Seller
Office approval and certification; they need no developer account. A raw WGT
on USB is not the general consumer installation route. Regional publishing
eligibility must be confirmed with Samsung.

- [Samsung TV connection](https://developer.samsung.com/tizen/blog/en/2019/07/16/connecting-smart-tv-and-visual-studio)
- [Samsung certificate profiles](https://developer.samsung.com/smarttv/develop/getting-started/setting-up-sdk/creating-certificates.html)
- [Installation FAQ](https://developer.samsung.com/smarttv/develop/faq/application-installation.html)
- [Seller Office membership](https://developer.samsung.com/tv-seller-office/guides/membership/becoming-seller-office-member.html)



