# Samsung installation

## Build the web payload

From the application checkout:

```powershell
./clients/tv/samsung_web/core_builder/build.ps1
Set-Location clients/tv/samsung_web
npm ci --ignore-scripts
npm run build
npm test
```

The generated payload is written under the ignored
`clients/tv/output/samsung-web/` directory. This workflow validates the web payload and
its contracts; it does not verify TV installation or playback.

## Cloud and relay configuration

A normal build takes the public backend URLs and public client identifier from
the application's compiled `CloudConfig` (`https://api.tvbro.online` and
`https://tvbro.online/`). To use a custom backend, place an
optional `publisher.config.local.json` in `clients/tv/samsung_web/`. It is
git-ignored. Configure both `apiUrl` and `panelUrl` as production HTTPS
origins. The optional `anonKey` is restricted to the public value
`tvbro_public_client`; do not put private keys in the app.

Set `providerRelay` to `true` only when the build should request the
metadata-only provider relay. The backend must explicitly enable Samsung
widget origins with `SAMSUNG_TV_ENABLED=true`; relay use additionally requires
`TV_PROVIDER_RELAY_ENABLED=true`. These are publisher-controlled opt-ins, not
private credentials to embed in the client.

## Local data and unpairing

Unpairing disconnects the TV's cloud pairing and clears cloud-link bookkeeping.
It preserves local profiles, source configurations, favorites, settings,
history, and resume data in TV-local storage. Provider catalogs and guide data
are fetched as needed; offline media downloads are not implemented.

Device validation must cover AVPlay media playback, KeyManager persistence,
remote-control behavior and store readiness.

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
