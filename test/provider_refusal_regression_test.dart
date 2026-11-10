import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/net.dart';
import 'package:iptvs/data/provider_stream_gate.dart';
import 'package:iptvs/data/secret_locator_vault.dart';
import 'package:iptvs/player/buffer_preset.dart';
import 'package:iptvs/player/mpv_options.dart';
import 'package:iptvs/player/playback_backend.dart';
import 'package:iptvs/screens/live_preview_controller.dart';
import 'package:iptvs/sources/m3u_source.dart';
import 'package:iptvs/sources/m3u_upgrade.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/sources/stalker_source.dart';

class _Repository implements LibraryRepository {
  _Repository(this.source, this.locator);
  @override
  final Source source;
  final StreamInfo locator;
  @override
  Future<StreamInfo> resolve(Channel channel) async => locator;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    ProviderRequestGate.instance.debugReset();
    ProviderStreamGate.instance.debugReset();
  });
  tearDown(() {
    ProviderRequestGate.instance.debugReset();
    ProviderStreamGate.instance.debugReset();
  });

  test('M3U startup and expiry never probe an unadvertised API', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final paths = <String>[];
    server.listen((request) async {
      paths.add(request.uri.path);
      if (request.uri.path == '/player_api.php') {
        request.response.statusCode = 403;
      } else {
        request.response.write(
          '#EXTM3U\n#EXTINF:-1,One\nhttps://media.test/one.ts',
        );
      }
      await request.response.close();
    });
    final url =
        'http://127.0.0.1:${server.port}/get.php?username=fixture&password=fixture';
    final source = M3uSource(sourceId: 'm3u', playlistUrl: url);
    addTearDown(source.dispose);
    expect(await source.channels(), hasLength(1));
    expect(
      await upgradeM3uToXtream(
        SourceConfig(
          id: 'm3u',
          kind: SourceKind.m3u,
          label: 'Fixture',
          fields: {'playlistUrl': url},
        ),
        automatic: true,
      ),
      isNull,
    );
    expect(
      (await source.subscriptionExpiry()).kind,
      SubscriptionExpiryKind.unknown,
    );
    ProviderRequestGate.instance.check(Uri.parse(url));
    expect(paths, ['/get.php']);
  });

  test('required M3U headers survive encrypted cache and do not leak to the next channel', () async {
    final parsed = parseM3uPlaylist(
      '#EXTM3U\n#EXTINF:-1 catchup-source="https://media.test/archive?start={start}",One\n'
      '#EXTVLCOPT:http-user-agent=RequiredAgent\n'
      '#EXTVLCOPT:http-referrer=https://provider.test/?token=fixture\n'
      'https://media.test/one.ts\n#EXTINF:-1,Two\nhttps://media.test/two.ts',
    );
    final vault = SecretLocatorVault();
    final sealed = await protectSecretLocators(
      parsed.channels.first.extra,
      vault,
    );
    expect(sealed.toString(), isNot(contains('RequiredAgent')));
    expect(sealed.toString(), isNot(contains('token=fixture')));
    final revealed = await restoreSecretLocators(sealed, vault);
    final source = M3uSource(
      sourceId: 'headers',
      playlistUrl: 'https://provider.test/list',
      userAgent: 'Default',
    );
    addTearDown(source.dispose);
    final first = Channel(id: 'one', name: 'One', extra: revealed);
    final stream = await source.resolve(first);
    expect(stream.headers, {
      'User-Agent': 'RequiredAgent',
      'Referer': 'https://provider.test/?token=fixture',
    });
    expect((await source.resolve(parsed.channels.last)).headers, {
      'User-Agent': 'Default',
    });
    final archive = await source.resolveArchive(
      first,
      Programme(
        channelId: 'one',
        title: 'Old',
        start: DateTime.utc(2026),
        stop: DateTime.utc(2026, 1, 1, 1),
      ),
    );
    expect(archive.headers, stream.headers);
  });

  test('Stalker aliases share one default account connection', () async {
    final one = StalkerSource(
      sourceId: 'one',
      portal: 'https://portal.test/c/',
      mac: '00:1a:79:12:34:56',
    );
    final two = StalkerSource(
      sourceId: 'two',
      portal: 'https://portal.test/stalker_portal/',
      mac: '00:1A:79:12:34:56',
    );
    addTearDown(one.dispose);
    addTearDown(two.dispose);
    expect(one.streamAccount.id, two.streamAccount.id);
    expect(one.streamAccount.maximumStreams, 1);
    ProviderStreamGate.instance.reserve(
      StreamInfo(
        url: 'https://media.test/one',
        providerAccount: one.streamAccount,
      ),
      owner: Object(),
    );
    expect(
      () => ProviderStreamGate.instance.reserve(
        StreamInfo(
          url: 'https://media.test/two',
          providerAccount: two.streamAccount,
        ),
        owner: Object(),
      ),
      throwsA(isA<ProviderStreamLimitReached>()),
    );
  });

  final dll = Platform.environment['TVBRO_AUDIT_LIBMPV'];
  final segmentPath = Platform.environment['TVBRO_AUDIT_HLS_SEGMENT'];
  for (final live in [false, true]) {
    for (final status in [200, 401, 403, 429]) {
      test(
        'real libmpv HLS live=$live segment $status is fetched once',
        () async {
          MediaKit.ensureInitialized(libmpv: dll);
          final segment = await File(segmentPath!).readAsBytes();
          final requests = <String>[];
          final finalSegment = Completer<void>();
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            final path = request.uri.path;
            requests.add(path);
            if (path.endsWith('.m3u8')) {
              request.response.headers.contentType = ContentType(
                'application',
                'vnd.apple.mpegurl',
              );
              request.response.write(
                '#EXTM3U\n#EXT-X-TARGETDURATION:2\n'
                '#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n'
                '${List.generate(5, (i) => '#EXTINF:2.0,\nsegment$i.ts\n').join()}'
                '#EXT-X-ENDLIST\n',
              );
            } else if (path == '/segment1.ts' && status != 200) {
              request.response.statusCode = status;
            } else {
              request.response.headers.contentType = ContentType(
                'video',
                'mp2t',
              );
              request.response.add(segment);
            }
            await request.response.close();
            if (path == '/segment4.ts' && !finalSegment.isCompleted) {
              finalSegment.complete();
            }
          });
          final player = Player(
            configuration: const PlayerConfiguration(vo: 'null'),
          );
          addTearDown(player.dispose);
          final native = player.platform as NativePlayer;
          await applyMpvOptions(native, {
            if (live) ...kLiveMpvOptions,
            if (!live) 'demuxer-lavf-o': kProviderMpvDemuxerOptions,
            'ao': 'null',
            'cache-on-disk': 'no',
          });
          // Deliberately omit the app's log-stop guard: the demuxer itself must
          // not burst retries before that asynchronous guard receives the error.
          await player.open(Media('http://127.0.0.1:${server.port}/list.m3u8'));
          await finalSegment.future.timeout(const Duration(seconds: 15));
          await player.stop();
          expect(
            requests.where((path) => path == '/segment1.ts'),
            hasLength(1),
          );
          expect(requests.where((path) => path == '/list.m3u8'), hasLength(1));
          // Format probing may reopen the first, successful chunked segment.
          expect(requests, containsAll(['/segment0.ts', '/segment4.ts']));
        },
        skip: !Platform.isWindows || dll == null || segmentPath == null
            ? 'Set TVBRO_AUDIT_LIBMPV and TVBRO_AUDIT_HLS_SEGMENT for the native fixture'
            : false,
      );
    }
  }
  for (final status in [401, 403, 429]) {
    test(
      'real libmpv $status stops preview and ${status == 403 ? 'allows' : 'blocks'} a manual retry',
      () async {
        MediaKit.ensureInitialized(libmpv: dll);
        PlaybackBackend.register(
          initialize: () {},
          createPlayer: (configuration) => Player(configuration: configuration),
          ownsPlayer: (_) => true,
          buildVideo: (_, _, _) => const SizedBox.shrink(),
        );
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        var requests = 0;
        final secondRequest = Completer<void>();
        server.listen((request) async {
          requests++;
          request.response.statusCode = status;
          await request.response.close();
          if (requests == 2 && !secondRequest.isCompleted) {
            secondRequest.complete();
          }
        });
        final url = 'http://127.0.0.1:${server.port}/live.ts';
        final source = M3uSource(sourceId: 'native', playlistUrl: url);
        addTearDown(source.dispose);
        final preview = LivePreviewController(
          repo: _Repository(
            source,
            StreamInfo(url: url, providerAccount: source.streamAccount),
          ),
        );
        addTearDown(preview.dispose);
        final refused = Completer<void>();
        preview.addListener(() {
          if (preview.error?.contains('HTTP $status') == true &&
              !refused.isCompleted) {
            refused.complete();
          }
        });
        const channel = Channel(id: 'one', name: 'One');
        await preview.start(channel, bufferPreset: BufferPreset.normal);
        await refused.future.timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw StateError(
            'Initial HTTP $status refusal sent $requests requests; error=${preview.error}',
          ),
        );
        await preview.stop();
        expect(requests, 1);
        expect(
          () => ProviderRequestGate.instance.check(Uri.parse(url)),
          status == 403 ? returnsNormally : throwsA(isA<ProviderRequestBlocked>()),
        );
        await preview.start(channel, bufferPreset: BufferPreset.normal);
        if (status == 403) {
          await secondRequest.future.timeout(
            const Duration(seconds: 5),
            onTimeout: () => throw StateError(
              'Manual retry sent $requests requests; error=${preview.error}',
            ),
          );
        } else {
          expect(preview.error, contains('HTTP $status'));
        }
        expect(requests, status == 403 ? 2 : 1);
        await preview.discardPlayer();
        expect(
          ProviderStreamGate.instance.activeStreams(source.streamAccount.id),
          0,
        );
      },
      skip: !Platform.isWindows || dll == null
          ? 'Set TVBRO_AUDIT_LIBMPV to the packaged Windows DLL'
          : false,
    );
  }
}
