import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/update_installer.dart';
import 'package:iptvs/data/update_manifest.dart';

const _artifact = ReleaseArtifact(
  platform: 'android',
  filename: 'iptvs-1.4.2-android.apk',
  byteSize: 5,
  sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('accepts the signed byte size and digest', () {
    expect(
      () => validateDownloadedArtifact(
        artifact: _artifact,
        receivedBytes: 5,
        sha256Digest: _artifact.sha256,
      ),
      returnsNormally,
    );
  });

  test('rejects a truncated or extended artifact', () {
    for (final size in [4, 6]) {
      expect(
        () => validateDownloadedArtifact(
          artifact: _artifact,
          receivedBytes: size,
          sha256Digest: _artifact.sha256,
        ),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('rejects an artifact with a different digest', () {
    expect(
      () => validateDownloadedArtifact(
        artifact: _artifact,
        receivedBytes: 5,
        sha256Digest:
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  group('cached Android update', () {
    late Directory cache;
    late File apk;
    late ReleaseArtifact artifact;

    setUp(() async {
      cache = await Directory.systemTemp.createTemp('iptvs-update-test-');
      apk = File('${cache.path}/iptvs-1.4.2-android.apk');
      final bytes = [1, 2, 3, 4, 5];
      await apk.writeAsBytes(bytes);
      artifact = ReleaseArtifact(
        platform: 'android',
        filename: 'iptvs-1.4.2-android.apk',
        byteSize: bytes.length,
        sha256: sha256.convert(bytes).toString(),
      );
    });

    tearDown(() => cache.delete(recursive: true));

    test('revalidates an unchanged cache-owned APK', () async {
      await validateCachedArtifact(apk, artifact, tempDirectory: cache);
    });

    test('rejects bytes changed during a settings detour', () async {
      await apk.writeAsBytes([5, 4, 3, 2, 1]);
      await expectLater(
        validateCachedArtifact(apk, artifact, tempDirectory: cache),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a matching file outside the owned cache', () async {
      final outside = await Directory.systemTemp.createTemp('iptvs-outside-');
      addTearDown(() => outside.delete(recursive: true));
      final file = await apk.copy('${outside.path}/${artifact.filename}');
      await expectLater(
        validateCachedArtifact(file, artifact, tempDirectory: cache),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  test(
    'a truncated download leaves no cache file and can be retried',
    () async {
      final cache = await Directory.systemTemp.createTemp(
        'tvbro-download-test-',
      );
      addTearDown(() => cache.delete(recursive: true));
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(paths, (_) async => cache.path);
      addTearDown(() => messenger.setMockMethodCallHandler(paths, null));

      const bytes = [1, 2, 3, 4, 5];
      final artifact = ReleaseArtifact(
        platform: 'android',
        filename: _artifact.filename,
        byteSize: bytes.length,
        sha256: sha256.convert(bytes).toString(),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var truncated = true;
      server.listen((request) async {
        request.response.add(truncated ? bytes.take(2).toList() : bytes);
        await request.response.close();
      });
      final local = Uri.http('127.0.0.1:${server.port}');
      final installer = UpdateInstaller(http: _LocalUpdateHttp(local));
      addTearDown(installer.close);
      final release = Uri.https(
        'github.com',
        '/Fusion231/tvbro/releases/download/v1.4.2/${artifact.filename}',
      );

      await expectLater(
        installer.download(release, artifact),
        throwsA(isA<FormatException>()),
      );
      expect(await cache.list().toList(), isEmpty);

      truncated = false;
      final downloaded = await installer.download(release, artifact);
      expect(await downloaded.readAsBytes(), bytes);
      await validateCachedArtifact(downloaded, artifact, tempDirectory: cache);
    },
  );

  for (final granted in [true, false]) {
    testWidgets('reads install permission on return (granted: $granted)', (
      tester,
    ) async {
      const channel = MethodChannel('iptvs/updates');
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            if (call.method == 'canInstallApks') return granted;
            // Android Settings opens a page without a permission result.
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final installer = UpdateInstaller();
      addTearDown(installer.close);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final permission = installer.requestInstallPermission();
      await tester.pump();
      expect(calls, ['openInstallPermissionSettings']);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(await permission, granted);
      expect(calls, ['openInstallPermissionSettings', 'canInstallApks']);
    });
  }

  test('reports an unavailable browser as a failed release handoff', () async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => false);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final installer = UpdateInstaller();
    addTearDown(installer.close);

    await expectLater(
      installer.openReleasePage(
        Uri.parse('https://github.com/Fusion231/tvbro/releases/tag/v1.5.0'),
      ),
      throwsStateError,
    );
  });

  group('Windows update script', () {
    final script = windowsUpdateScript(
      pid: 42,
      zipPath: r"C:\Users\O'Brien\update.zip",
      installDir: r'C:\Apps\IPTVS Player',
      exeName: 'iptvs.exe',
    );

    test('quotes user-controlled paths as PowerShell literals', () {
      expect(script, contains(r"$zipPath = 'C:\Users\O''Brien\update.zip'"));
      expect(script, contains(r"$installDir = 'C:\Apps\IPTVS Player'"));
      expect(script, contains('Wait-Process -Id 42'));
    });

    test('validates archive paths and links before extraction', () {
      expect(script, contains('[System.IO.Compression.ZipFile]::OpenRead'));
      expect(script, contains('[System.IO.Path]::IsPathRooted'));
      expect(script, contains(r'$entry.ExternalAttributes'));
      expect(script, contains('Update archive path escapes'));
      expect(script, contains('Update archive contains a symbolic link'));
    });

    test('extracts to staging and contains swap and rollback steps', () {
      expect(
        script,
        contains(
          r'Expand-Archive -LiteralPath $zipPath -DestinationPath $stageDir',
        ),
      );
      expect(script, isNot(contains(r'-DestinationPath $installDir -Force')));
      expect(
        script,
        contains(r'Move-Item -LiteralPath $installDir -Destination $backupDir'),
      );
      expect(
        script,
        contains(r'Move-Item -LiteralPath $backupDir -Destination $installDir'),
      );
      expect(script, contains('Updated application exited during startup'));
    });

    test('records a transcript so a failed helper is diagnosable', () {
      expect(script, contains('Start-Transcript'));
      expect(script, contains("'iptvs_update.log'"));
    });
  });

  group('Windows updater launch', () {
    // Regression: the helper's first act is Wait-Process on the GUI app's PID,
    // so it is blocked when the app exits. Launched as a bare detached console
    // child it was torn down at that moment — no staging folder was ever made
    // and the update silently no-opped. It must be spawned via `cmd /c start`
    // so it owns a console and outlives the app.
    final launch = windowsUpdaterLaunch(r'C:\Temp\iptvs_update.ps1');

    test('routes through cmd /c start, not a bare powershell', () {
      expect(launch.executable, 'cmd.exe');
      expect(launch.arguments.first, '/c');
      expect(launch.arguments[1], 'start');
    });

    test('runs the helper script hidden without a profile', () {
      expect(launch.arguments, containsAllInOrder(<String>['start', '/min']));
      expect(launch.arguments, contains('powershell.exe'));
      expect(
        launch.arguments,
        containsAllInOrder(<String>['-File', r'C:\Temp\iptvs_update.ps1']),
      );
      expect(
        launch.arguments,
        containsAllInOrder(<String>['-WindowStyle', 'Hidden']),
      );
      expect(launch.arguments, contains('-NoProfile'));
    });
  });

  group('Linux AppImage update script', () {
    test('waits for the app and swaps whole files', () {
      expect(linuxUpdateScript, contains('kill -0 "\$old_pid"'));
      expect(linuxUpdateScript, contains('mv "\$target" "\$backup"'));
      expect(linuxUpdateScript, contains('mv "\$stage" "\$target"'));
      expect(linuxUpdateScript, contains('chmod 0755 "\$target"'));
    });

    test('restores and relaunches the previous AppImage on failure', () {
      expect(linuxUpdateScript, contains('rm -f "\$target"'));
      expect(linuxUpdateScript, contains('mv "\$backup" "\$target"'));
      expect(linuxUpdateScript, contains('"\$target" >/dev/null 2>&1 &'));
    });
  });
}

class _LocalUpdateHttp extends Fake implements HttpClient {
  _LocalUpdateHttp(this.destination);

  final Uri destination;
  final _client = _LocalNetworkOverrides().createHttpClient(null);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _client.getUrl(destination);

  @override
  void close({bool force = false}) => _client.close(force: force);
}

class _LocalNetworkOverrides extends HttpOverrides {}
