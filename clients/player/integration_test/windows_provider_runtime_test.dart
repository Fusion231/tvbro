// Local-only Windows qualification of the actual HWND renderer and provider IO.
// flutter test integration_test/windows_provider_runtime_test.dart -d windows
//   --dart-define=TVBRO_RUNTIME_FIXTURE=<absolute fast-start MP4 path>
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:iptvs/data/net.dart';
import 'package:iptvs/player/buffer_preset.dart';
import 'package:iptvs/player/mpv_options.dart';
import 'package:iptvs/player/playback_backend.dart';
import 'package:iptvs/player/player_screen.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  const fixture = String.fromEnvironment('TVBRO_RUNTIME_FIXTURE');

  testWidgets('Windows native playback starts promptly and refusal never retries', (
    tester,
  ) async {
    expect(Platform.isWindows, isTrue);
    expect(fixture, isNotEmpty);
    final media = File(fixture);
    final size = await media.length();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final counts = <String, int>{};
    server.listen((request) async {
      final path = request.uri.path;
      counts.update(path, (n) => n + 1, ifAbsent: () => 1);
      final response = request.response;
      try {
        if (path.startsWith('/refuse')) {
          response.statusCode = int.parse(path.split('/').last);
          await response.close();
          return;
        }
        final range = RegExp(r'bytes=(\d+)-(\d*)')
            .firstMatch(request.headers.value('range') ?? '');
        final start = range == null ? 0 : int.parse(range[1]!);
        final end = range == null || range[2]!.isEmpty
            ? size - 1
            : int.parse(range[2]!);
        response.headers.set('Content-Type', 'video/mp4');
        response.headers.set('Accept-Ranges', 'bytes');
        if (range != null) {
          response.statusCode = 206;
          response.headers.set('Content-Range', 'bytes $start-$end/$size');
        }
        response.contentLength = end - start + 1;
        await response.addStream(media.openRead(start, end + 1));
        await response.close();
      } catch (_) {
        // Stopping the player intentionally cancels its active HTTP response.
      }
    });
    addTearDown(() => server.close(force: true));
    Player? current;
    // Observe the actual production-created engine; preserve the real renderer.
    PlaybackBackend.register(
      initialize: MediaKit.ensureInitialized,
      createPlayer: (configuration) =>
          current = Player(configuration: configuration),
      ownsPlayer: (_) => false,
      buildVideo: (_, _, _) => const SizedBox.shrink(),
    );
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: const Scaffold(body: SizedBox()),
      ),
    );
    Future<void> closePlayer() async {
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
    }

    final timings = <int>[];
    for (var cycle = 0; cycle < 6; cycle++) {
      ProviderRequestGate.instance.debugReset();
      final path = '/play-$cycle.mp4', watch = Stopwatch()..start();
      unawaited(
        nav.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => PlayerScreen(
              title: 'Local Windows fixture $cycle',
              stream: StreamInfo(
                url: 'http://127.0.0.1:${server.port}$path',
                isLive: cycle.isEven,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final player = current!;
      await player.stream.position
          .firstWhere((value) => value > Duration.zero)
          .timeout(const Duration(seconds: 10));
      watch.stop();
      timings.add(watch.elapsedMilliseconds);
      final native = player.platform as NativePlayer;
      expect(await native.getProperty('current-vo'), 'gpu-next');
      expect(await native.getProperty('ytdl'), 'no');
      expect(double.parse(await native.getProperty('cache-secs')), 10);
      expect(
        watch.elapsedMilliseconds,
        lessThan(5000),
        reason: 'local startup must not wait for the cache to fill',
      );
      final before = counts[path];
      for (final preset in [
        BufferPreset.high,
        BufferPreset.max,
        BufferPreset.normal,
      ]) {
        await applyMpvOptions(native, mpvBufferOptions(preset));
        expect(
          double.parse(await native.getProperty('cache-secs')),
          double.parse(mpvBufferOptions(preset)['cache-secs']!),
        );
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(
        counts[path],
        before,
        reason: 'buffer changes must not reopen HTTP',
      );
      await closePlayer();
    }
    for (final live in [true, false]) {
      for (final status in [401, 403, 429]) {
        ProviderRequestGate.instance.debugReset();
        final path = '/refuse/${live ? 'live' : 'vod'}/$status';
        unawaited(
          nav.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => PlayerScreen(
                title: 'Local refusal $status',
                stream: StreamInfo(
                  url: 'http://127.0.0.1:${server.port}$path',
                  isLive: live,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        // Observe beyond the 8-second reconnect watchdog using real wall time.
        await Future<void>.delayed(const Duration(seconds: 10));
        expect(
          counts[path],
          1,
          reason: 'HTTP $status must stop without a watchdog reopen',
        );
        expect(
          () => ProviderRequestGate.instance.check(
            Uri.parse('http://127.0.0.1:${server.port}/next'),
          ),
          throwsA(isA<ProviderRequestBlocked>()),
        );
        await closePlayer();
      }
    }
    // ignore: avoid_print
    print(
      'WINDOWS_RUNTIME_RESULT startupMs=$timings requests=$counts renderer=gpu-next',
    );
    ProviderRequestGate.instance.debugReset();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
