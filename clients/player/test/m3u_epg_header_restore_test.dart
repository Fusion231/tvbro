import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// The storage plugin exposes platform injection through this interface.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/net.dart';
import 'package:iptvs/sources/m3u_source.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a delayed saved header cannot overwrite a freshly parsed playlist guide',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final previousStorage = FlutterSecureStoragePlatform.instance;
      final storage = _DelayedHeaderStorage();
      FlutterSecureStoragePlatform.instance = storage;
      ProviderRequestGate.instance.debugReset();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final playlistUrl = 'http://127.0.0.1:${server.port}/playlist.m3u';
      final guideUrl = 'http://127.0.0.1:${server.port}/guide.xml';
      final playlist =
          '#EXTM3U url-tvg="$guideUrl"\n'
          '#EXTINF:-1 tvg-id="guide-one",Guide One HD\n'
          'http://stream.example.invalid/one.ts\n';
      final now = DateTime.now().toUtc();
      var playlistRequests = 0;
      var guideRequests = 0;
      server.listen((request) async {
        switch (request.uri.path) {
          case '/playlist.m3u':
            playlistRequests++;
            request.response.write(playlist);
          case '/guide.xml':
            guideRequests++;
            request.response.write(
              '<tv><channel id="guide-one"><display-name>Guide One</display-name>'
              '</channel><programme channel="guide-one" '
              'start="${_stamp(now.subtract(const Duration(hours: 1)))} +0000" '
              'stop="${_stamp(now.add(const Duration(hours: 1)))} +0000">'
              '<title>Current playlist guide</title></programme></tv>',
            );
          default:
            request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });
      final source = M3uSource(
        sourceId: 'header-restore',
        playlistUrl: playlistUrl,
      );
      addTearDown(() async {
        if (!storage.releaseRead.isCompleted) storage.releaseRead.complete();
        await source.dispose();
        await server.close(force: true);
        FlutterSecureStoragePlatform.instance = previousStorage;
        ProviderRequestGate.instance.debugReset();
      });

      // SQLite can supply these channels before the new source parses its
      // playlist. Header discovery therefore begins with a secure-storage read.
      final channels = parseM3uPlaylist(playlist).channels;
      final guide = source.epg(channels);
      await storage.readStarted.future.timeout(const Duration(seconds: 5));

      // A concurrent catalog load obtains a current header while the older
      // device-local value (which has no guide URL) is still in flight.
      await source.channels().timeout(const Duration(seconds: 5));
      expect(source.sourceCapabilities.epg, CapabilityAvailability.supported);
      expect(playlistRequests, 1);
      storage.releaseRead.complete();

      final programmes = await guide.timeout(const Duration(seconds: 5));
      expect(guideRequests, 1);
      expect(programmes.single.channelId, channels.single.id);
      expect(programmes.single.title, 'Current playlist guide');
      expect(source.sourceCapabilities.epg, CapabilityAvailability.supported);
    }, _RealHttpOverrides()),
  );

  test(
    'a legacy empty header cache is rediscovered once and the new header survives restart',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final previousStorage = FlutterSecureStoragePlatform.instance;
      FlutterSecureStoragePlatform.instance = _LegacyEmptyHeaderStorage();
      ProviderRequestGate.instance.debugReset();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final playlistUrl = 'http://127.0.0.1:${server.port}/playlist.m3u';
      final guideUrl = 'http://127.0.0.1:${server.port}/guide.xml';
      final playlist =
          "#EXTM3U tvg-url = '$guideUrl'\n"
          '#EXTINF:-1 tvg-id="guide-one",Guide One HD\n'
          'http://stream.example.invalid/one.ts\n';
      final now = DateTime.now().toUtc();
      var playlistRequests = 0;
      var guideRequests = 0;
      server.listen((request) async {
        switch (request.uri.path) {
          case '/playlist.m3u':
            playlistRequests++;
            request.response.write(playlist);
          case '/guide.xml':
            guideRequests++;
            request.response.write(
              '<tv><programme channel="guide-one" '
              'start="${_stamp(now.subtract(const Duration(hours: 1)))} +0000" '
              'stop="${_stamp(now.add(const Duration(hours: 1)))} +0000">'
              '<title>Rediscovered guide</title></programme></tv>',
            );
          default:
            request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });
      final first = M3uSource(
        sourceId: 'legacy-header',
        playlistUrl: playlistUrl,
      );
      final restarted = M3uSource(
        sourceId: 'legacy-header',
        playlistUrl: playlistUrl,
      );
      addTearDown(() async {
        await first.dispose();
        await restarted.dispose();
        await server.close(force: true);
        FlutterSecureStoragePlatform.instance = previousStorage;
        ProviderRequestGate.instance.debugReset();
      });

      final channels = parseM3uPlaylist(playlist).channels;
      final programmes = await first.epg(channels);
      expect(playlistRequests, 1);
      expect(programmes.single.title, 'Rediscovered guide');

      final refreshed = await restarted.epg(channels);
      expect(refreshed.single.title, 'Rediscovered guide');
      expect(playlistRequests, 1);
      expect(guideRequests, 2);
    }, _RealHttpOverrides()),
  );
}

class _LegacyEmptyHeaderStorage extends TestFlutterSecureStoragePlatform {
  _LegacyEmptyHeaderStorage() : super({});
  bool _legacyRead = false;

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    if (key.startsWith('m3u_guide_header_') && !_legacyRead) {
      _legacyRead = true;
      return jsonEncode({'url': null, 'at': DateTime.now().toIso8601String()});
    }
    return super.read(key: key, options: options);
  }
}

class _DelayedHeaderStorage extends TestFlutterSecureStoragePlatform {
  _DelayedHeaderStorage() : super({});

  final readStarted = Completer<void>();
  final releaseRead = Completer<void>();

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    if (key.startsWith('m3u_guide_header_') && !readStarted.isCompleted) {
      final saved = jsonEncode({
        'url': null,
        'at': DateTime.now().toIso8601String(),
      });
      readStarted.complete();
      await releaseRead.future;
      return saved;
    }
    return super.read(key: key, options: options);
  }
}

class _RealHttpOverrides extends HttpOverrides {}

String _stamp(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}'
    '${value.month.toString().padLeft(2, '0')}'
    '${value.day.toString().padLeft(2, '0')}'
    '${value.hour.toString().padLeft(2, '0')}'
    '${value.minute.toString().padLeft(2, '0')}'
    '${value.second.toString().padLeft(2, '0')}';
