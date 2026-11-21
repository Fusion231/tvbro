# Local recordings and timeshift

TVBro's device-local DVR supports Windows, Android phones/TVs, and foreground iOS playback. It
supports manual recording, persisted scheduled recording, and an opt-in local timeshift buffer.
On iOS, backgrounding or system suspension may interrupt an active capture or scheduled start;
keep TVBro open in the foreground. Samsung Tizen, LG webOS, and cross-device/PC sharing are
outside this scope.

Startup recovery starts after the app's first frame, so scanning saved recordings does not
delay the initial screen. DVR operations still await service initialization when needed.

Direct MPEG-TS capture keeps its parser in one isolate for the lifetime of the connection.
Only one chunk is in flight: capture awaits parsed segments and their writes before reading
the next network chunk. Transferable buffers avoid per-packet copies in the parser; packet
views remain owned by the worker. Keyframe scanning starts only at a possible segment
boundary. Cancellation retains the complete packet-aligned tail and shutdown awaits the
worker's exit. HLS still streams downloaded media directly to disk.

Saved media is flushed and renamed before a segment is durably appended to `segments.jsonl`.
The journal stores local segment metadata and gap flags, never provider URLs or headers.
Full JSON/playlist checkpoints run at 128, 256, 512, ... segments and on close/recovery,
so total checkpoint serialization grows linearly rather than rewriting the entire recording
after every segment. The journal is removed only after both checkpoint files are published;
a failed periodic checkpoint leaves recording and its durable journal intact. Recovery reads
legacy JSON-only recordings, replays journal entries beyond the checkpoint, and retains the
validated prefix if the last row was torn. Final checkpoints retain the existing saved format.
Media copies and complete-file recovery validation remain in place to preserve quota,
retention and missing-media checks.

## Capture and playback

`DvrService` owns capture sessions and saved recording metadata. It writes complete media segments
inside the app's private support directory and serves them from an HTTP server bound only to the
IPv4 loopback interface. Player playback receives that local locator; recording metadata and
manifests do not persist provider stream URLs or request headers. Provider credentials remain with
the source configuration and are never copied into DVR metadata or native notifications.

On the iOS AVPlayer path, the presented native controller plays the local loopback media through
`dvrTransport` and receives current availability/playback state through `setDvrState`. The plugin
accepts local DVR playback only from a loopback URL. DVR transport and position callbacks carry
the active native-open ID and DVR playback ID so events from a prior open or capture are ignored.

Timeshift starts only after the user invokes its player control. It cannot rewind before the first
segment captured by that session. If the user starts recording with the initial capture action,
the saved recording includes the available complete buffer prefix. If a timeshift is already
running, recording begins at its next complete segment. Both uses share a capture when the source
and channel identity match. Leaving the player ends a timeshift-only capture; an explicit manual
recording continues independently of the viewer.

M3U/Xtream captures reserve one slot in the account-wide device-local stream
quota before sending any upstream request, and release it only after their HTTP
client closes. Sharing a capture for recording and local viewing costs one slot;
recording another channel while viewing is refused when the account limit is
already occupied. Recovery retains the account identity and reservation even when
a refreshed locator omits it. The limit is configurable in source settings and
cannot increase a known Xtream provider cap.

A finite HLS ENDLIST closes the capture normally: an attached recording is completed and its
complete segments remain available in the local window. While capture is still running, Go to Live
seeks to that capture's current edge. After capture ends, Go to Live resolves the provider stream
again. Android's native player translates its signed ExoPlayer position through the current HLS
window offset, so the DVR cursor stays on the local playback timeline as the manifest window moves;
if its position expires, playback moves to the oldest retained segment.

The input path supports MPEG-TS and HLS with muxed audio/video, including HLS AES-128 identity-key
encryption. It does not support separate HLS audio playlists, DRM, encrypted initialization
segments, non-identity HLS keys, or scrambled MPEG-TS. The buffer defaults to 30 minutes or 1 GiB,
whichever bound is reached first; saved recordings have a 10 GiB default quota. Saved recordings
are not removed automatically to make space. The library shows usage, limits, sizes, durations,
and each item's live/completed/interrupted/failed state.

Writes and stops settle on complete segments, not exact frames or button timestamps. The first or
last few seconds can differ from the requested start/stop time. When capture is interrupted or
fails, recovery validates the saved segment prefix and preserves playable media as an explicitly
partial item. Invalid or incomplete trailing segments are discarded. A capture with no playable
media remains visible so its metadata can be deleted.

## Scheduled recordings

One-off scheduled recordings remain free. Creating a recurring weekday schedule
requires a supporter place on this device. Each recurring occurrence checks
access before starting; expiry leaves an actionable failed schedule and stops
creating further occurrences. It does not interrupt a recording already running.
See [subscriptions.md](subscriptions.md) for device activation and offline expiry.

`DvrScheduler` persists occurrences in app-private `schedules.json`, alongside the DVR directory.
The EPG and custom channel/time dialog use the same API. Each occurrence stores only local profile,
source and channel identities, title, start/end times, padding, repeat weekdays, status and the
associated recording id. At the start boundary the app resolves the owning source/channel afresh;
provider URLs, credentials and request headers are never copied into this file. The optional
authorization callback can enforce a persistent content policy before resolution, but an expired
temporary PIN-unlock session is not a recording policy.
The saved cloud profile ID is read directly from secure storage, so this offline
ownership lookup does not construct a cloud SDK client or require its initialization.

Start and end padding extend the occupied interval. Only one recording can run at a time, and
the scheduler rejects overlaps including padding and future weekly recurrence. Adjacent intervals
are allowed. A manual recording that is already running at a due start stays running; the schedule
reports a conflict. Repeating occurrences retain local calendar time across daylight-saving changes.
Completing, missing or failing an occurrence produces the next selected weekday; cancelling the
pending occurrence also stops its recurrence. History can be removed independently of saved media.

One timer observes the nearest start/end boundary. Resume re-evaluates the persisted times, without
status polling. An occurrence whose end has passed is marked missed. A late start inside its window
is allowed and visibly warns that the beginning may be missing. An active occurrence recovered after
process death is linked to the existing recovered recording and reported interrupted. Ending capture
before the planned finish also reports an interrupted schedule, preserving any media already saved.

TVBro must remain running and the device must stay awake for a future recording to start. The current
scheduler has no OS alarm or headless Flutter engine that could relaunch a killed process. It cannot
record after force-stop, while Windows is closed/asleep, or while the device is switched off. On iOS,
backgrounding or suspension may interrupt scheduled starts and ongoing captures; keep TVBro open in
the foreground and reopen it to reconcile missed starts or partial recordings. Android foreground
protection begins once the scheduled capture starts and has the same limits described below as manual
capture. The schedule dialog and library state these requirements explicitly.

## Connection recovery

Capture retries socket failures, timeouts, incomplete downloads, HTTP 408 and temporary
500/502/503/504 responses. The default recovery budget is five retries with exponential delays from
one to eight seconds, ±20% jitter, and a two-minute period without a committed segment. A successful
complete segment resets that budget. Cancellation wakes backoff immediately. MPEG-TS live EOF is
treated as a lost connection; finite HLS ENDLIST still finishes capture normally.

An optional in-memory `resolveAgain` callback refreshes expiring stream locators on transient
failures. HTTP 401/403/429 stops capture immediately; 401/429 also pauses the provider host
through the shared `ProviderRequestGate`. HTTP 403 permits a later recording attempt without
a local host pause; HTTP 503 with a valid `Retry-After` pauses the host. Every media request and
redirect checks that pause, without imposing control-API pacing on normal HLS segments. Refusals
do not trigger a fresh authorization attempt. Other permanent HTTP errors, unsupported
encryption/media and storage failures also stop capture immediately.
Scheduled recordings supply the callback through their source lookup. Raw provider exceptions and
locators never appear in user-visible errors or diagnostics.

Recovery retains the complete recorded prefix and retries the unfinished segment. Local sequence
numbers stay monotonic and a reconnect adds an HLS discontinuity. If the provider's moving window
has skipped segments, its sequence has reset, or a direct TS connection has lost continuity, the
recording is explicitly labelled as containing gaps. Playback concatenates the available media;
missing broadcast time is not invented. Exhausted recovery keeps a playable interrupted recording.

## Android background lifetime

While a manual recording runs, Android uses a started foreground service with a wake lock. Android
TV uses the media-playback service type. Phones use the data-sync type; on Android 15+ the system
may terminate that type after six background hours in a 24-hour period. The timeout callback stops
capture cleanly and reports an interrupted recording. The notification has a Stop action and does
not include channel, provider, URL, or credential data. Android 13+ notification permission is
requested once at the first explicit recording action. If it is denied, recording remains
available with an in-app Stop button and a notice that the notification is hidden.

The service does not restart after process death, app force-stop, or a system timeout. If the app
starts again, recovery marks a still-open recording interrupted after validating its complete
segment prefix. Leaving the player alone does not stop a manual recording; destroying the owning
Flutter engine does stop native protection so capture cannot continue without its Dart owner.

## UI and navigation

The library is reachable from the live-screen app bar and from Home when no provider is set up.
It can stop a running recording or timeshift, play completed or valid partial recordings through
the existing player, and delete an item only after confirmation. On TV, Up/Down selects one list
row, Right selects its Delete action, Left returns to the row, and Enter activates it. The same
actions are available by touch and mouse.

## Runtime validation

The scheduled-recording and connection-recovery additions passed 22 focused Flutter tests on
Windows on 2026-10-22 (`dvr_scheduler_test.dart` and `dvr_recovery_test.dart`). These cover persisted
jobs, padding and recurring conflicts, missed/interrupted starts, cancellation during startup,
live TS EOF, a real truncated HLS download, moving-window gaps, authentication refresh and bounded
retry exhaustion. This is automated validation; scheduled starts have not been validated on hardware.

An earlier Flutter validation run passed 1,429 tests with 12 opt-in skips and no failures;
`flutter analyze` was clean (`build/validation/hls-epg-onboarding-test-final.log` and
`build/validation/hls-epg-onboarding-analyze-final.log`). This is historical evidence from before
the iOS DVR integration and does not validate the current iOS player path. In the DVR native
validation baseline, 120 AndroidJUnit tests passed across 13 suites, and Windows plus Android
universal and x64 debug builds succeeded.

On the Android API 36 Google TV emulator, a recording continued after leaving the player,
switching A→B→A reused the same capture, and Stop from the library ended the foreground service.
A saved recording played at 25 fps after the source server was stopped. Timeshift pause held its
position while the buffer grew; Back 10, Forward 10, resume, and Go to Live were exercised. The
Google TV Stop check used the library; notification Stop was confirmed only on the phone.

On the Android API 36.1 phone emulator, Forward 10 after Back 10 moved from 16.000 to 26.000;
resume reached 27.560 after 1.56 seconds at 25 fps. Recording continued in Home with the
data-sync foreground service active: metadata grew from 290 seconds / 30,699,648 bytes to
334 seconds / 35,350,392 bytes. Stop from the system notification completed the recording at
350 seconds / 37,057,808 bytes and left no foreground service running. With the test source
server stopped, the recording remained in the library after force-stop and app restart and played
at 25 fps.

On Windows, HLS and MPEG-TS timeshift, pause, seek, resume, and Go to Live were exercised. mpv held
06.000 while paused and resumed to 08.880 after 2.88 seconds; Back 10 moved 26.160→16.000 and
Forward 10 moved to 26.000. Saved HLS (09:22, 56.8 MB) and MPEG-TS (01:29, 9.1 MB) recordings
remained available after restart and
played at 25 fps from the library; the final build also played saved HLS with the source offline.
Separately, the black Windows HLS preview before activating timeshift was traced to creating
the video controller after opening the stream. The output-before-open fix passed Windows runtime
validation on 2026-10-22: first-open HLS displayed video before any timeshift activation, and
adopted fullscreen plus return preserved the picture. See [player.md](player.md#live-preview--seamless-handoff-android).
The user's real TVN RAW preview also showed video and EPG without DVR. Android DVR checks used
emulators and a controlled test source; physical Android devices and DVR on the user's IPTV
provider were not tested. The iOS loopback/native transport has not yet had an Xcode build or
iPhone/iPad playback validation; no iOS runtime behavior is claimed here.
