# Samsung TV test deployment

This note covers the generated Flutter-on-Tizen C#/.NET TV package and the existing Windows + WSL toolchain. It does not claim that the current qualification package runs on a Samsung TV.

## What the current evidence says

- Samsung's Flutter-for-Tizen guide says Smart TVs support Flutter from Tizen 6.0 and shows the TV-profile `.tpk` build command. Samsung's .NET TV Q&A says actual-device testing is supported on 2019 and later TVs. The generic Application Testing FAQ separately says TVs do not support native `.tpk` packages. These official pages conflict; the Flutter/.NET-specific guidance fits this C# Flutter wrapper, but only a device install can resolve acceptance for this package.
- The existing local TPK was signed with a generic Tizen test author/distributor chain. Samsung's Flutter-Tizen install troubleshooting calls for a Samsung certificate profile and the target DUID, so the local generic-signed package is not the TV test package. Its archive, manifest and signatures are summarized in `../output/tizen-app/20261024/final-audit/proof.json`.
- Samsung certificate creation requires the Samsung Certificate Extension, a Samsung Developer Portal account, and the target TV's DUID. The profile contains author and distributor certificates; create the distributor certificate with the target DUID. For a first development install, the shortest candidate is a Samsung **Public** TV profile scoped to that DUID; partner-level APIs require a partner certificate, and partner-group membership is needed to publish apps using partner-level privileges.
- A separate ambiguity remains for native libraries: Samsung's .NET TV Q&A says a .NET app may `DllImport` signed native `.so` files in its package, but building or signing those native libraries requires Seller Office partner-group membership. This does not explicitly say that a public-signed Flutter TPK containing the prebuilt Flutter `.so` files cannot install. Samsung's public docs do not settle whether that rule applies to this Flutter package, so do not treat partner membership as either confirmed-required or confirmed-unneeded for the first install.
- The qualified package targets Tizen API 6.0 and uses the Tizen 6 GCC 9.2 toolchain. Samsung says 2026 TV products use GCC 14.2 and GCC 9.2-built libraries are not guaranteed compatible there. Confirm the TV model/year; this package's native-engine compatibility is not established for 2026 models.

## Shortest path using Windows and the existing WSL SDK

1. On the TV, open Apps, enter `12345` with the remote, switch Developer Mode on, enter the Windows PC's LAN IP, and reboot. Read the TV's DUID from Menu > Support > Contact Samsung > Unique Device ID. Do not share the Samsung account password or private certificate files in the repository.
2. On Windows, use Tizen Studio's Package Manager to install Samsung TV Extensions and Samsung Certificate Extension (current Samsung instructions note that versions before 2.0.73 cannot create certificates after September 2025). In Certificate Manager, use an existing Samsung Developer Portal account to create a Samsung TV **Public** profile containing this TV's DUID. If that account does not exist, stop here; this process does not create an account. Keep the author/distributor PKCS#12 files and passwords private.
3. Register that Samsung profile in the existing WSL Tizen SDK using the exported certificates. Build the current generated wrapper in WSL, explicitly targeting the TV ARM device and Samsung profile:

   ```bash
   flutter-tizen build tpk --device-profile tv --target-arch arm --security-profile <samsung-profile>
   ```

4. Use the Windows Tizen `sdb`/CLI from the Windows host IP configured on the TV. After the user supplies the TV IP, connect and install the newly signed TPK:

   ```powershell
   sdb connect <tv-ip>
   sdb devices
   tizen install -n <path-to-tpk> -t <device-id>
   ```

   The WSL `flutter-tizen install` path is also available if its SDB connection reaches the TV; do not scan the LAN to discover the address.

## Inputs needed before a TV attempt

- TV model/year, Tizen version, TV IP, and DUID.
- An existing Samsung Developer Portal account and a Samsung TV Public author/distributor profile scoped to that DUID. If the first install reports a native-library/authorization restriction, ask Samsung whether the app's packaged Flutter `.so` files require Seller Office partner-group access before pursuing a partner profile.

## Remote-control check

Samsung lists D-pad arrows, Enter, and Back as mandatory remote keys. Flutter-Tizen's TV guidance says firmware can report OK as `select` or `enter`, and Back as `goBack` or `escape`. The shared player now binds both Back keys on the custom TV backend, and the channel-list root maps TV `goBack` into its existing Back ladder. These mappings are source-covered; whether this firmware delivers the expected Flutter logical keys remains unverified. Check OK, D-pad, and Back from both the player and channel list on the device.

## References

- [Samsung Flutter for Tizen](https://developer.samsung.com/smarttv/develop/native/flutter.html)
- [Samsung Creating Certificates](https://developer.samsung.com/smarttv/develop/getting-started/setting-up-sdk/creating-certificates.html)
- [Samsung Installing TV SDK](https://developer.samsung.com/smarttv/develop/getting-started/setting-up-sdk/installing-tv-sdk.html)
- [Samsung TV Device and Developer Mode](https://developer.samsung.com/smarttv/develop/getting-started/using-sdk/tv-device.html)
- [Samsung Tizen .NET TV Q&A: native libraries](https://developer.samsung.com/smarttv/develop/faq/tizen-net-tv.html)
- [Samsung TV privilege Q&A](https://developer.samsung.com/smarttv/develop/faq/privileges.html)
- [Samsung .NET TV package deployment](https://developer.samsung.com/smarttv/develop/tizen-net-tv/getting-started/creating-net-tv-applications.html)
- [Samsung generic Application Testing FAQ](https://developer.samsung.com/smarttv/develop/faq/application-testing.html) (contains the conflicting WGT-only statement)
- [Flutter-Tizen TV package and install guidance](https://github.com/flutter-tizen/flutter-tizen/blob/main/doc/publish-app.md)
- [Flutter-Tizen TPK installation troubleshooting](https://github.com/flutter-tizen/flutter-tizen/wiki/TPK-installation-troubleshooting) (Samsung profile/DUID errors)
- [Samsung TV remote key mapping](https://developer.samsung.com/smarttv/develop/guides/user-interaction/remote-control.html?device=htv)
- [Flutter-Tizen remote-input guidance](https://github.com/flutter-tizen/skills/blob/main/skills/flutter-tizen-tv-remote-input/SKILL.md)
