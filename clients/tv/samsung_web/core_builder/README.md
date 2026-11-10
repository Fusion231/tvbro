# Compiled canonical Source bridge

`build.ps1` runs the existing Dart SDK and analyzer. The generator selects
verbatim AST bodies from the current application; it does not maintain a second
provider parser or URI/authentication implementation. `reuse-proof.json` records
source hashes, declaration ranges/body hashes, compiler results, dependency
roots and the browser-port hash. Original source files are checked again after
compilation and are never edited. `OWNER` remains the repository checkout root;
Dart sources and their package configuration come from `clients/player/`, and
the proof records those paths relative to the checkout.

The generated module includes complete `SourceConfig`, `M3uSource`,
`XtreamSource`, `StalkerSource` and `DemoSource` classes; their in-memory caches,
request admission/retries, token renewal, catalogs/pages/search/details, series
hierarchies, stream/archive resolution, expiry, XMLTV event parser, EPG matching
and ordered guide merge execute the original Dart. XML, parser, crypto,
collection, meta and timezone dependencies use the owner's cached resolved
packages. The browser gzip codec uses the already installed archive package.

## Public API

The global `TVBroCanonical` retains the original standalone JSON functions.
The broader interface is:

```javascript
var source = TVBroCanonical.createSource(JSON.stringify({
  id: 'stable-source-uuid', kind: 'xtream', label: 'My source',
  fields: {host: 'https://provider.example', username: '...', password: '...'},
  settings: {}
}), physicalGet);
var categories = JSON.parse(await source.invoke('categories', '{}'));
await source.dispose();
```

`physicalGet(requestJSON)` returns a promise of response JSON. Each invocation
performs one physical GET; retry, admission and refusal decisions belong to the
compiled original source code. The descriptor contains `url`, exact `headers`,
`workload` (`playlist`, `provider-json`, `stalker-json` or `epg`),
`totalTimeoutMs`, `idleTimeoutMs`, `maximumBodyBytes`, `maximumDecodedBytes`.
Headers must be forwarded or explicitly rejected by the platform transport.
The response is `{status, body, url, headers, decoded}`. `body` is UTF-8 text;
`bodyBase64` can instead supply raw bytes. `decoded:true` removes HTTP encoding
headers before parsing a browser-decoded response. `{errorKind:'network'}`
identifies a transient connection failure; other capability failures must not
be reported as successful responses.

| `invoke` method | JSON arguments |
| --- | --- |
| `connect`, `categories`, `subscriptionExpiry`, `capabilities`, `invalidate` | `{}` |
| `channels` | `{categoryId?}` |
| `mediaCategories`, `allMediaItems` | `{kind}` |
| `mediaItems`, `mediaItemsPage` | `{kind,categoryId?,parent?,maxPages?,page?}` |
| `searchMedia` | `{kind,query,categoryId?}` |
| `mediaDetails`, `resolveMedia` | `{item}` |
| `resolve` | `{channel}` |
| `resolveArchive` | `{channel,programme}` |
| `epg` | `{channels}` |

All invocation results are promises of JSON strings. Channel/media DTOs retain
all original model fields, including `extra`. Programmes carry `channelId`,
`title`, `description`, ISO `start`/`stop`. Resolved streams include URL,
headers, liveness, subtitles and original opaque provider-account metadata.
`kind` uses `live`, `movie`, `series`, `season` or `episode`.

Additional original-policy bindings:

- `hashPin(pin) -> Promise<string>`, `verifyPin(pin,verifier) -> Promise<bool>`,
  `isPinVerifier(verifier) -> bool` call the original PIN functions.
- `parentalRules(method,argsJSON) -> JSON string` supports `channelKey`,
  `categoryKey`, `validate`, `categoryIds`, `protects`. Arguments use `sourceId`,
  `id`, `kind`, `categoryId` and `rules` in the original version-1 persisted
  schema. Invalid/future policies fail closed.
- `supporterActive(statusJSON,nowISO) -> bool` calls original
  `SupporterStatus.fromJson(...).isActiveAt(...)`; server grant verification and
  secure persistence remain the caller's responsibility.
- `resumeDecision(positionSec,durationSec) -> Promise<JSON string>` executes
  original `AppDatabase.savePlaybackPosition`/`clearPlaybackPosition` and
  captures its requested write as `{action,positionMs,durationMs}`. It executes
  no SQL.
- `seriesProgress(argsJSON) -> JSON string` executes the original
  `SeriesWatchProgress` selection over episode DTOs and saved checkpoints.
  `Source.invoke('seriesProgress', {item,positions,prepareNext:true})` scopes
  that history to a cached series, checks catalogue completeness and prepares
  only its last watched season and immediate successor when necessary. It
  returns `watchedCount`, `latestEpisode`, `latestPosition`, `nextEpisode` and
  `complete`; incomplete season/episode pages cannot imply completion or be
  skipped by the next action. Positions use seconds and millisecond checkpoint
  timestamps. This summary does not apply a resume seek or resolve a stream.
- `canCatchup(channelJSON,programmeJSON,nowISO) -> bool` executes the exact
  `isPast` and `canCatchup` statements from the original guide details action.
- `profileNormalize(profileJSON) -> JSON string` accepts one profile or a list
  and executes original `LocalProfile`/`ProfileSnapshot.fromJson` and `toJson`.
- `cloudConfig() -> JSON string` exposes original public `CloudConfig` values
  (`enabled`, `configured`, `apiUrl`, `panelUrl`, `anonKey`), without contacting
  those servers. `pairingPanelLink(panel,code,language) -> string` reuses the
  original pairing-link function.

## Platform boundaries

`web_bindings.dart.txt` is only the browser IO vocabulary needed by those
verbatim declarations. HTTP uses the supplied callback. Guide files and M3U
header metadata are held in session memory and released with their streams;
there is no native disk/conditional-download cache. Worker message channels are
asynchronous within the browser process, with the original parser's batch/ack
flow; CPU work is not offloaded to a native isolate. Large guide memory and
performance therefore need device qualification. XHR redirect hops are not
individually visible to the canonical per-hop gate; the final response host is
checked. Browser-forbidden Cookie/User-Agent headers require a genuine native
transport capability and may not be silently ignored.

No provider Source method is omitted from this compilation. The current
original Xtream Source has no `get_short_epg` method: its EPG is XMLTV;
Stalker uses its original `get_epg_info`. SQLite/LibraryRepository, cloud
sync, native file persistence and Flutter widgets are outside this module.

## Validation

```powershell
./clients/tv/samsung_web/core_builder/build.ps1
node --expose-internals ./clients/tv/samsung_web/core_builder/test_core.cjs ./clients/tv/output/samsung-web/core
node ./clients/tv/samsung_web/core_builder/test_sources.cjs ./clients/tv/output/samsung-web/core
```

The first suite retains the 13 parser/identity/URI/authentication checks. The
second runs actual compiled Source classes against synthetic physical HTTP
responses, including gzip/multiple EPG guides, VOD/series hierarchy, native
header descriptors, fresh Stalker links, refusal gating and the original policy
boundaries. It does not access a real provider, account or TV. The outer Samsung
build transpiles this module and checks packaged ES5 syntax; modern Node VM
tests do not establish Chromium M47 or physical decoder compatibility.
