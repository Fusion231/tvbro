# LG webOS installation and qualification

A genuine `.ipk` can be built with the installed official LG CLI. The package
workflow checks the web app and JavaScript service files against captured
source hashes and verifies both sets in the IPK. Installation and television
testing remain deferred. No LG model is currently confirmed.
`latest-package.json` under `app/tv/output/lg-webos/` identifies the current
package and SHA-256; rebuild if the UI, adapters, service, core, or publisher
configuration change.

For later device testing, use LG's [Developer Mode workflow](https://webostv.developer.lge.com/develop/getting-started/developer-mode-app)
and [CLI guide](https://webostv.developer.lge.com/develop/tools/cli-dev-guide):

1. Put the TV and development PC on the same network. Install LG's Developer
   Mode app from LG Apps, sign in with an LG developer account, enable Dev Mode,
   and allow the TV to restart.
2. Run `ares-setup-device` and add the TV IP, port `9922`, user `prisoner`, and a
   chosen device name such as `lg-tv`. Enable Key Server on the television.
3. Run `ares-novacom --device lg-tv --getkey` and enter the passphrase displayed
   by Developer Mode. Keep the SSH key and passphrase private.
4. Install the actual verified package with
   `ares-install --device lg-tv <absolute-ipk-path>`, then launch it with
   `ares-launch --device lg-tv online.tvbro.webos`.
5. Use `ares-inspect --device lg-tv --app online.tvbro.webos` for browser
   diagnostics and `ares-inspect --device lg-tv --service
   online.tvbro.webos.epg` for service diagnostics. Older TV engines may need a
   matching older inspector browser; follow LG's guidance for the specific
   platform.

Developer Mode sessions expire; LG's app provides an Extend control. LG states
that disabling Developer Mode removes its installed development apps, so local
storage must not be treated as a permanent account backup. Ordinary consumer
distribution requires the LG store submission and certification workflow;
a development IPK is not evidence of store approval.

The initial device target is webOS TV 4.x and later. The ES5/Chromium 38 build
floor permits investigation of webOS 3.x, but persistent non-extractable keys,
WebCrypto operations, decoding, TLS and memory still require actual checks.
webOS 1.x/2.x are not included. Record the full model, webOS version, firmware,
IPK hash and results before calling a model supported.

The EPG cache is separate from encrypted IndexedDB records: provider XMLTV and
gzip files live as raw bytes in the JavaScript service's own jail under
`/media/internal/online.tvbro.webos.epg/`. The app reads bounded chunks over the
webOS service API; it cannot open the service's files directly. Confirm service
startup, cache writes/reads, quota handling and retention across app/TV
restarts on each model.

The later device pass must cover cold start and remote Back/OK/arrows, pairing
and cloud restore, PIN-gated profiles, loading representative real provider
catalogues and guides, preview/fullscreen transitions, long playback, resume,
track selection where available, suspend/resume, and encrypted storage after
app/TV restart. Check supported stream formats and the adapter's explicit
custom-header limitation. Xtream films/episodes now use direct native playback
with the TV's User-Agent in place of TVBro's default VLC User-Agent; verify
the real provider accepts it. Provider-specific headers are not silently dropped.
Local backup file controls are
intentionally unavailable. No TV connection, installation, launch, or hardware
measurement is performed by the build/package tools.
