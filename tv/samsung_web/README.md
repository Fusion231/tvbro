# Samsung Tizen Web client

This is a browser-based Samsung TV client targeting Tizen 3.0 (including the
2017 UE43M5672) and later. The TV runs the web UI and Samsung AVPlay; it does not
run the original Flutter widgets or require Flutter on the television.

## Implemented client paths

The web client includes local profiles and profile PIN gates, source management,
live and on-demand browsing, guide data, favorites, playback history and resume,
player controls, and cloud pairing/profile selection with pull and push. TV-local
profiles, source configurations, favorites, settings, history, and resume state
are stored through Tizen KeyManager; there is no plaintext `localStorage`
fallback.

Series details show the completed-episode count, last watched episode and next
episode or resume action, including after returning from playback. Selection
uses the original Dart series-progress logic shared with Flutter and LG. Saved
progress is isolated by profile/source; incomplete catalogue pages cannot imply
that the entire series is watched. Resume still uses the existing access checks.

Source settings now include channel names, ordering, hidden channels/categories,
custom groups, additional EPG feeds, catch-up settings and provider expiry details.
Editors mount at most forty rows. Manual XMLTV channel mappings and time offsets
are stored per profile/source; programme search uses the guide already loaded on
the TV. Audio/subtitle choices and aspect mode are remembered per content item.
The optional Stable AVPlay buffer uses eight seconds where native support exists.

Automatic cloud sync is off by default and requires an unlocked paired profile.
When enabled, lifecycle events and local edits merge favorite/settings deltas and
supporter playback positions; source credentials are not sent by automatic delta
pushes. Manual full sync remains available. Metadata comes from the provider or
existing cached data; no new external metadata lookup is started.

Encrypted `.tvbro` backups use Android's v1 AES-256-GCM/PBKDF2-SHA256 envelope.
The file picker uses real mounted Tizen storage, including supported USB devices,
and never overwrites an existing file. Import adds local recovery profiles with
new IDs and keeps current profiles/settings. Pairing sessions are excluded;
source credentials remain inside the encrypted backup. Backup controls require
native file access and WebCrypto, and files are limited to 32 MiB.

Version 0.1.35 downloads XMLTV to `wgt-private/tvbro_epg_v1` through the native
Tizen Download API and reads at most 64 KiB at a time. The existing Dart parser
consumes those reads; the worker's pinned pako inflater processes gzip without
retaining its full decoded output. Limits match Android: 512 MiB downloaded and
4 GiB of decoded work. Completed raw files survive restart, with at most eight
cached feeds and a 768 MiB cache budget. Refreshing may temporarily retain the
previous file and a new download together; disk-full failures retain the old one.
Only a complete XMLTV document with valid gzip CRC/size can commit a replacement.
Readers keep their previous file until they release it. Header inspection and
native downloading retain provider admission, refusal handling and deadlines.

If native download/filesystem APIs are unavailable, the existing browser fallback
keeps its 32 MiB memory limit (48/64 MiB only with verified PMS headroom).
Native disk IO requires the public download and filesystem privileges in the
manifest. Physical-device qualification remains required; browser/SDK boundary
tests do not establish native storage behavior or the TV's available space.

The selected profile is saved in TV-private storage. With the startup picker
set to Never, an unlocked remembered profile opens directly; a locked profile
is selected automatically and opens the standard PIN prompt. Cancelling leaves
the profile chooser available. The PIN gate and explicit Auto/Always modes
retain their existing behavior.

The presentation follows the current Android TV layout: compact Home tiles,
global actions on Home, and a local Home control in each browsing section.
Live TV has categories on the left and a horizontal preview above an embedded
EPG grid on the right. The guide is the default, including clickable
"No programme information" cells for channels without guide data. Its toolbar
toggles the guide and ordinary channel list in place. All filtered channels
share one continuous scroll range; only the nearby rows are mounted, and there
are no channel-page controls in EPG. Current programmes and
empty cells use the same first-OK preview / second-OK fullscreen action as
channel names; past/future programme details remain available.
The guide retains a forty-row overscan window and reuses unchanged rows,
programme cells, logos and time headings. Pixel scrolling within that window
does not rebuild it. Programme grouping uses one pass; only missing visible
channels request guide data. The ordinary channel list is mounted when selected,
rather than building its eighty hidden rows behind EPG. Its now/next requests
also cover only visible rows (at most twelve), with short-lived per-channel
reuse and debounced updates when scrolling.
Movies and series use the same compact category rail,
poster proportions, Inter typography, colours and remote focus treatment.
The series catalogue loads its next provider page near the bottom of the
scroller, with no pagination controls. Appending preserves existing cards,
focus and scroll; large search results are revealed in batches. Category and
search changes reset the list and reject obsolete responses. Failed reads
retain loaded cards and offer an explicit retry.
Movie, series and episode details use a DTO built from the original Dart
`MediaInfo` and shared trailer helpers. The cinematic header and information
sections show available provider or already cached metadata, including genres,
directors, creators, countries, release dates and cast. They do not start fresh
TMDB lookups. A single details scroller hides the underlying catalogue and its
category scrollbar. Seasons start collapsed and load episodes on expansion;
the horizontal episode rail mounts at most twelve cards, with artwork,
description and saved playback progress. Back restores the episode cursor and
details scroll, then the original catalogue position. Trailer links open only
after explicit selection and when the TV supports native URL launching.
The presentation scales from a 1280×720 logical canvas, including dialogs and
player controls; a 1920×1080 TV uses a 1.5× scale. Native video stays outside
that layer and receives the rendered preview coordinates.

As on Android TV, the first OK on a channel starts its preview and keeps focus
in the channel list. A second OK on the same channel opens fullscreen using
the existing stream. A ready preview also opens fullscreen after 30 seconds
without remote or pointer activity. Leaving Live, opening a dialog, searching
or backgrounding cancels that timeout. There is no separate fullscreen button.
Failed EPG reads keep the channel grid available and show a fixed `EPG:`
category instead of provider URLs or raw exception text. A guide failure is
distinct from a valid channel with no programme data.
HTTP 404/410, including their saved retry causes, explicitly report a missing
guide address and suggest checking EPG settings; they are not described as a
channel download or authentication refusal. Channels remain playable. An M3U
playlist without an explicit/header guide can infer a sibling `xmltv.php`, but
that convention does not prove the provider serves EPG. It does not authorize
automatic Xtream API discovery or conversion.
For Xtream, an unavailable or oversized full XMLTV feed can fall back to the
canonical Source's short channel guide for at most twelve visible rows. Calls
are serial, spaced one second apart, cached for ten minutes across restarts,
and stop for fifteen minutes after failure, except HTTP 403 permits a new request.
Authentication/rate-limit refusals
never trigger fallback. Provider limits on the short schedule still apply.

Live AVPlay opens request a four-second startup buffer in IDLE before
`prepareAsync`, the minimum documented by Samsung. The native recovery buffer
and buffering timeout remain unchanged. Unsupported tuning falls back to the
firmware defaults. This is media duration, not a guaranteed wall-clock start
time; bandwidth, manifest/segment timing and decoder preparation still matter.
VOD retains the native buffering policy. No mpv options are used by this client.
Native readiness is returned without waiting for history persistence; stop,
dispose and history reads await the queued write. Artwork starts only near the
viewport, with at most two transfers and no artificial delay between healthy starts. Three
consecutive image failures pause that artwork host for a minute; repeated failed
URLs are suppressed for a minute. Playback/API admission is independent. Direct
`<img>` events do not expose HTTP status, so this is a generic failure guard.
Deferred reads preserve the first failure category and its original retry
deadline across guide windows and restarts; a deferred read does not extend
that wait. Older snapshots without a recorded cause retain their existing
deadline and report an unknown cause until a new allowed download completes.
EPG downloads use binary XHR responses, preserving gzip files even when the
server does not send HTTP `Content-Encoding`. The canonical XMLTV parser
receives the original bytes; the existing size limits still apply.
The worker transport transfers the ArrayBuffer without base64/JSON body copies
on the UI thread; JSON conversion happens inside the worker at the Dart boundary.
Gzip stream binding yields the decoded bytes through the existing bounded chunk
helper, so XML events are not materialized for an entire inflated guide at once.
These 0.1.31 behaviors are retained in the 0.1.32 catalogue-crash fix.
Successful responses advertising a `Content-Length` above the applicable limit
are rejected at the headers, before downloading a known oversized guide.
Compressed lengths retain separate transferred/decoded limits; HTTP refusals
retain their original classification and cooldown.

Complete channel and guide results are displayed before large cache snapshots
are exported and written. Those writes coalesce after one second and are drained
by cache flush, source changes and disposal before the source worker closes.
Reopening the already selected source avoids rewriting the profile preference;
changing the selected source still persists that preference atomically.

Catalogue export projects only reversible model fields, not `MediaInfo`, trailer
links or other UI-derived fields for every unvisited M3U season/episode. Those
fields are still computed when items are requested by the UI. Typed media lists
are encoded item by item rather than building a second full DTO tree. Payload,
schema-1 envelope and the RPC string wrapper use chunked UTF-8 encoding; both
payload and saved envelope are capped at 32 MiB, including Unicode and escaping
(the RPC wrapper has a separate 64 MiB + 2 byte bound). This bounds serialization,
not the total memory of arbitrarily large source catalogues. Existing schema-1
snapshots remain readable. Durable M3U writes may fall back to complete live
roots with explicitly deferred media; VOD is then loaded from the original
playlist on first use. Runtime transfer and rollback still require a complete
snapshot. An export that cannot fit retains the loaded catalogue and does not
replace the previous disk generation. Manual
details refresh refuses to invalidate a catalogue it cannot first snapshot for
rollback; this preserves its children if a provider refresh would fail.

Catalogue snapshots use the existing canonical 24-hour policy. Raw XMLTV bytes
and their original failure deadlines survive a complete process restart, so a
different guide window can reuse a fresh saved feed.
Saved EPG remains visible after its freshness expires while a replacement downloads
in the background; completion updates the visible guide and a failure retains it.
Details and episode lists are invalidated with a successful catalogue refresh even when the series root
has not changed. **Refresh details** requests current provider data immediately;
a failed refresh restores the previous complete catalogue and children.

Version 0.1.34 prepares the daily catalogue in a separate source instance and
publishes it after active reads finish. Playback, the selected screen, channel
focus and guide/list position remain in place; an open movie/series list picks
up new catalogue data on the next navigation. Failed refreshes retain the old
catalogue and retry after one hour. Started live playback can recover a native
InvalidState error, including a session already stopped by the firmware;
thirty seconds of continuously observed healthy progress restores its retry
budget. Consecutive failures remain bounded, and provider refusals still gate
reconnection. These paths are contract-tested, not physical-TV qualified.

The 0.1.35 disk adapter removes the old 32 MiB ceiling on native-capable Samsung
TVs, including automatic M3U guides. Plain/gzip guides larger than 40 MiB, invalid
XML/HTML responses, CRC errors, truncation, restart reuse and failed refresh
rollback are covered by tests. See [the platform comparison](PARITY-20261107.md).

Fullscreen live playback accepts Samsung Channel Up/Down and Page Up/Down even
when controls are visible. With controls hidden, Up selects the next channel
and Down the previous one. A burst of channel keys commits only its final
selection after 600 ms. Left opens a paged quick channel list (21 rows mounted),
Right recalls the last successfully opened channel, and digits choose a channel
in the source's full list after 1.2 seconds or OK. Guide/Channel List,
Previous Channel and Info keys are also supported. Dialogs, Back, stop and
leaving playback cancel pending channel selections. Navigation wraps at either
end and identifies channels by provider ID, including entries opened from
history. The player uses an Android-style top title/live/clock row and bottom
transport, direct audio/subtitle actions and a finite VOD progress bar. Left
and Right reach every action even when translated labels wrap. Unsupported
live seeking is hidden; DVR and PiP are not supplied by this adapter.
Loading and live buffering preserve hidden controls so consecutive arrow keys
keep changing channels. Explicit OK/Info during a channel start remains effective
after readiness; playback errors, a real pause and VOD completion can still
reveal the controls.
Fullscreen presents the native object's full size before opening or resizing
AVPlay and reapplies its rectangle after paint. The display area is also
restored at native lifecycle changes, with opaque presentation panes covering
the screen outside the embedded preview.
Opening a live channel from Home history first opens its source's TV list, so
leaving fullscreen returns to TV with focus inside that list.

Live playback checks the native clock after 30 seconds without progress. A
stalled stream can reopen at most twice per user open, retaining its request
headers and current rectangle and checking the provider's refusal cooldown
before reconnecting. Progress, pause, stop and completion cancel obsolete
recovery work. VOD is excluded. A missing native seek callback times out after
ten seconds so it cannot indefinitely block stop or replacement playback;
rectangle changes made during seeking are retained until seeking settles.
These safeguards cover a stalled native session, not a hung TV/browser process.

While playing, controls hide after five seconds without interaction. The
Hide controls action and remote Back hide them immediately; OK shows them again.
A rejected seek does not become a persistent playback failure when the movie
continues playing, and repeated paused-state updates preserve manual hiding.

Finite seek keys accumulate their intended position and coalesce after 120 ms.
Holding Rewind/Fast Forward, a hidden player's Left/Right arrow, or OK on
the −10/+10 second buttons repeats until key release. Changing playback,
opening a dialog, leaving the app or rejecting a seek cancels the hold.
Native seek positions stay inside the media boundaries because AVPlay can
reject the exact beginning and end.
Only one native seek runs at a time; later keys retain the latest target, and
Play/Pause waits for the active seek. Replacing or stopping playback cancels
obsolete intent. Previous/Next episode and the Episodes selector keep the
fullscreen player open while replacing its stream. Automatic continuation uses
only a genuine completion from the current native session and stops at the last
episode of the current season. Errors, replacement and seek completion do not
advance episodes. Saved catalogue context restores episode controls when an
episode is opened from history after restart.

For M3U sources with an empty primary EPG field, the guide address comes from
the playlist's `url-tvg`/`x-tvg-url` header, or from the sibling `xmltv.php`
endpoint for credentialed `get.php` playlists without a guide header. HTTP
404 means that address is unavailable even when channel playback works. Set
a working provider XMLTV address in Source settings → Primary EPG address;
the application does not invent programme information or probe the Xtream API
for an M3U source.

Cloud pairing shares overlapping requests, honors `Retry-After`, and backs off
after failures, including code renewal. These gates and the single AVPlay
instance apply within this application process; they cannot coordinate one
provider account across separate Windows, Android and Samsung applications.

Provider parsing and shared source behavior come from the original Dart core
compiled for this client, and field validation uses the application's panel
validator. The DOM UI and Samsung player, storage, transport, and cloud bindings
are TV-specific code. Stalker metadata requests that need the relay require an
explicit publisher opt-in; media playback is sent to the TV player/provider
path.
Portals that bind their session or stream link to the caller IP require a
separate relay qualification: the backend's metadata connection and the TV's
direct media connection have different egress addresses.

These are implemented software paths, not full qualification on a physical TV.
A Samsung-signed baseline WGT was installed and launch was accepted on a
Samsung UE43M5672 (Tizen 3.0); the user confirmed that the UI was visible. The
proof is `tv/output/tizen-builder/20261024/samsung-device-20261025/signed-20261025T095346440940Z/result.json`.
AVPlay media playback, KeyManager persistence, remote-control behavior, and
full runtime parity remain unverified. The onboarding/language-selection
update 0.1.1 (`payload-20261025T105610538Z`) passed browser QA, was signed and
installed, and its launch was accepted. Its device receipt is
`tv/output/tizen-builder/20261024/samsung-device-20261025/signed-20261025T105706658115Z/result.json`.
The user reported an operation error on the TV. Diagnostic update 0.1.2 was
installed and launch-accepted to identify its safe error class. Correct runtime
startup and cloud pairing are not yet qualified.

## Reuse boundaries

The build selects original pure Dart declarations and statements using the
installed analyzer, records their source ranges and hashes, then compiles the
generated bindings with the existing Dart 3.13.5 SDK. The original M3U,
Xtream, Stalker, and Demo source classes and `SourceConfig.build` execute in
that core. The original Flutter widgets, `LibraryRepository`, SQLite database,
and native IO-cache stack are not run by this web client. Provider catalogs
and guide data are fetched as needed; this client does not provide offline
media downloads.

Unpairing disconnects the cloud device and clears cloud-link bookkeeping. It
does not delete TV-local profiles, sources, favorites, settings, history, or
resume data.

## Cloud configuration

By default, the build uses `https://api.tvbro.online`, `https://tvbro.online/`,
and the public client identifier from the application's compiled `CloudConfig`.
An optional
`tv/samsung_web/publisher.config.local.json` file overrides those values for a
custom backend. The file is git-ignored. Configure both HTTPS origins together;
`anonKey`, if supplied, must be the public identifier `tvbro_public_client`.
Never put a private server key in this file.

Cloud onboarding automatically downloads the complete profile, including source
settings, favorites and saved playback positions, before opening the library.
A sole profile is selected automatically, with its PIN gate still enforced;
multiple profiles require a choice. Opening the account screen on an unpaired
device with no playlists uses the same onboarding flow. Already paired devices
and local setups with playlists retain manual download/upload management.

Example for an opted-in custom relay build (replace the origins with the
operator's production HTTPS origins):

```json
{
  "apiUrl": "https://api.your-domain",
  "panelUrl": "https://panel.your-domain",
  "anonKey": "tvbro_public_client",
  "providerRelay": true
}
```

Relay requests are disabled unless `providerRelay` is `true`. The deployed
backend has `SAMSUNG_TV_ENABLED=true`; its health endpoint, `Origin: null`
preflight, and unauthenticated profile rejection were checked. Cloud pairing
has not been verified end to end on the TV. Relay use additionally requires
`TV_PROVIDER_RELAY_ENABLED=true`; the relay remains disabled and undeployed.

## Build and validate

From the application checkout, using the installed host Flutter/Dart SDK:

```powershell
./tv/samsung_web/core_builder/build.ps1
Set-Location tv/samsung_web
npm ci --ignore-scripts
npm run build
npm test
```

`core_builder/test_catalog_memory.cjs <core-output-or-payload>` checks compact
schema-1 roundtrips (including playback headers and old UI-enriched snapshots),
20,000 distinct series in a 192 MiB Node heap, and oversized Unicode refusal.
`npm test` also runs it against the packaged core. For isolated validation without
resolving the Flutter/native project, `build_core.dart` accepts an optional fifth
argument pointing to an owner dependency `package_config.json`. Use the owner's
pinned pure dependency versions; this is not permission to upgrade them. The
2026-11-01 check used Dart 3.13.5, analyzer 10.1.0, the seven owner dependencies
listed by the builder, and its tooling dependency archive 3.6.1. Default builds
still read the owner's `.dart_tool/package_config.json`.

The build creates a fresh web payload under ignored `tv/output/samsung-web/`.
Babel targets the legacy browser, core-js supplies standard-library
polyfills, every packaged script must parse as ES5, and the stylesheet rejects
CSS variables, Grid, and `gap`. Contract tests and browser fixtures exercise
software boundaries; they do not qualify media playback, KeyManager, signing,
installation, or the app on a Samsung TV.

The signed install evidence covers the earlier baseline only; local build
output by itself does not establish that a later payload was signed or
installed. See [Samsung testing status](INSTALL.md).



