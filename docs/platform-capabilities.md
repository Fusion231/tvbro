# TVBro platform capabilities

This table describes implemented paths, not device certification. Provider support,
the device model/OS, configured services and access requirements still apply.
Build, installation and device-validation requirements are documented with the
[TV clients](../clients/tv/README.md).

| Capability | Android phone / Android TV | Windows | Samsung Tizen Web | LG webOS | Philips Titan OS |
|---|---|---|---|---|---|
| M3U, Xtream, Stalker; Live, EPG, movies and series | Implemented | Implemented | Implemented | Implemented | Implemented; hosted browser transport restrictions apply |
| Remote navigation | Android TV D-pad | Keyboard | Samsung remote | Remote / pointer | Remote |
| Touch navigation | Phone/tablet UI | Pointer UI | TV UI | TV UI | TV UI |
| Profile PIN, parental controls, favorites and viewing progress | Implemented | Implemented | Implemented | Shared TV implementation | Shared TV implementation |
| Local recording, schedules and timeshift | Implemented | Implemented | Not supplied | Not supplied | Not supplied |
| Encrypted backup file import/export | Implemented | Implemented | Requires supported native file APIs | Not supplied by the TV adapter | Not supplied by the hosted adapter |
| External movie/series metadata | Configured clients | Configured clients | Provider data / existing cache; no fresh external lookup | Native metadata service | No native LG metadata service |
| Player | Media3 / libmpv fallback | libmpv / D3D11 | Samsung AVPlay | HTML5 / native TV capabilities | HTML5 / native TV capabilities |
| Custom playback headers | Native transport capabilities apply | Native transport capabilities apply | AVPlay capabilities apply | Arbitrary custom headers unavailable | Arbitrary custom headers unavailable |
| Cloud pairing and profile sync | Optional configured service | Optional configured service | Manual and optional automatic sync | Shared TV implementation; device qualification pending | Shared TV implementation; device qualification pending |

Saved VOD resume and automatic synchronization can have access requirements; see
[Supporter details](https://tvbro.online/). Basic playback is not gated by these conveniences.
An EPG URL, matching channel IDs and provider archive support determine which guide
and catch-up functions can work; an app cannot create missing provider data.

Philips Android/Google TV uses the Android app. Titan OS is a separate hosted
client. SAPHI, Whale and ZEASN models are not automatically covered by either
target. Identify the OS before choosing an installation package.

Titan requires a stable HTTPS app origin for encrypted storage. Provider endpoints
must be reachable under the browser's HTTPS/mixed-content and CORS policies. The
current app does not silently route provider credentials through another server.
See [Titan installation and transport](../clients/tv/titan_os/README.md).

Scheduled recording currently needs TVBro to remain running and the device awake;
it is not an always-on recorder. Local recording media is separate from profile
backups and from downloading VOD for offline use. See [dvr.md](dvr.md).

Changing an OS capability label does not implement that capability. A platform is
qualified only after the actual model passes import/cache, remote navigation,
playback/recovery, audio/subtitles and long-session checks. The Samsung installation
receipt alone confirms updating and starting the app, not every playback scenario.
