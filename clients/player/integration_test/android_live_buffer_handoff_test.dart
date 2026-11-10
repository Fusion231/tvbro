// Opt-in native playback regression. Supply a synthetic, finite MPEG-TS fixture
// from a local host server, never provider data. With adb reverse tcp:8768 tcp:8768:
// --dart-define=LIVE_HANDOFF_FIXTURE_URL=http://127.0.0.1:8768/fixture.ts
// Debug mode checks native resource counters and automatically exits. In profile
// mode a host observer sends Back twice after TVBRO_HANDOFF_CLOSE_NOW; this keeps
// measurements on the real native player without adding a production test API.
// LIVE_HANDOFF_DIRECT_VOD=true checks a fresh native open with episode metadata.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:iptvs/data/diagnostics_log.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/player/buffer_preset.dart';
import 'package:iptvs/player/player_screen.dart';
import 'package:iptvs/player/resource_counters.dart';
import 'package:iptvs/screens/live_preview_controller.dart';
import 'package:iptvs/sources/m3u_source.dart';
import 'package:iptvs/sources/source.dart';

const _fixtureUrl = String.fromEnvironment('LIVE_HANDOFF_FIXTURE_URL');
const _directVod = bool.fromEnvironment('LIVE_HANDOFF_DIRECT_VOD');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    _directVod
        ? 'a fresh native episode open retains controls and playback'
        : 'a different fullscreen buffer retains the live preview',
    (tester) async {
      final fixture = Uri.parse(_fixtureUrl);
      expect(fixture.scheme, 'http');
      expect(fixture.host, isIn(['10.0.2.2', '127.0.0.1', 'localhost']));
      final http = HttpClient();
      final bytes = <int>[];
      try {
        final response = await (await http.getUrl(fixture)).close();
        expect(response.statusCode, 200);
        await for (final chunk in response) {
          bytes.addAll(chunk);
          expect(bytes.length, lessThan(8 * 1024 * 1024));
        }
      } finally {
        http.close(force: true);
      }

      var transportStarts = 0;
      var playlistRequests = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = server.listen((request) async {
        if (request.uri.path == '/playlist.m3u') {
          playlistRequests++;
          request.response.write(
            '#EXTM3U\n'
            '#EXTINF:-1 tvg-id="handoff-fixture",Synthetic live handoff\n'
            'http://127.0.0.1:${server.port}/live.ts\n',
          );
          await request.response.close();
          return;
        }
        final range = request.headers.value(HttpHeaders.rangeHeader);
        final start = range == null
            ? 0
            : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        if (start == 0) transportStarts++;
        request.response.headers.contentType = ContentType('video', 'mp2t');
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        if (range != null) {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-${bytes.length - 1}/${bytes.length}',
          );
        }
        request.response.contentLength = bytes.length - start;
        request.response.add(bytes.sublist(start));
        await request.response.close();
      });
      final source = M3uSource(
        sourceId: 'handoff-fixture',
        playlistUrl: 'http://127.0.0.1:${server.port}/playlist.m3u',
      );
      final preview = LivePreviewController(repo: _Repository(source));
      final log = DiagnosticsLog.instance..clear();
      const native = MethodChannel('iptvs/native_hdr_player');
      Future<dynamic> recordDiagnostic(MethodCall call) async {
        if (call.method == 'nativeDiagnostic') {
          log.add('player', (call.arguments as Map)['note'] as String);
        }
        return null;
      }

      native.setMethodCallHandler(recordDiagnostic);
      PlayerScreen.debugSoakAutoCloseMs = 5000;
      addTearDown(() async {
        PlayerScreen.debugSoakAutoCloseMs = null;
        preview.adoptedByFullscreen = false;
        await preview.stop(clearSelection: true);
        preview.dispose();
        native.setMethodCallHandler(null);
        await source.dispose();
        await server.close(force: true);
        await requests.cancel();
      });

      final navigator = GlobalKey<NavigatorState>();
      final channel = (await source.channels()).single;
      if (!_directVod) {
        await preview.start(channel, bufferPreset: BufferPreset.normal);
        expect(preview.nativeActive, isTrue);
      }
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 180,
                child: _directVod
                    ? const SizedBox.shrink()
                    : PreviewVideo(preview: preview),
              ),
            ),
          ),
        ),
      );
      if (!_directVod) await _waitForNote('preview first frame');
      final resolved = _directVod
          ? await source.resolve(channel)
          : preview.stream!;
      final stream = _directVod
          ? StreamInfo(url: resolved.url, isLive: false)
          : resolved;
      expect(playlistRequests, 1);
      final startsBefore = transportStarts;
      final countersBefore = await ResourceCounters.snapshot();
      if (kDebugMode) {
        expect(countersBefore['exoEngines'], _directVod ? 0 : 1);
        expect(countersBefore['sharedEngineLive'], _directVod ? 0 : 1);
      }

      log.clear();
      preview.adoptedByFullscreen = !_directVod;
      final opening = Stopwatch()..start();
      int? loaderPaintMs;
      binding.addPostFrameCallback((_) {
        if (find
            .byKey(const ValueKey('native-player-startup'))
            .evaluate()
            .isNotEmpty) {
          loaderPaintMs = opening.elapsedMilliseconds;
        }
      });
      PageRouteBuilder<void> playerRoute() => PageRouteBuilder<void>(
        opaque: false,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => PlayerScreen(
          title: 'Synthetic live handoff',
          stream: stream,
          adoptNativePreview: !_directVod,
          providerStreamOwner: _directVod ? null : preview.providerStreamOwner,
          bufferPreset: BufferPreset.high,
          episodes: [
            if (_directVod)
              for (var i = 1; i <= 30; i++)
                MediaItem(
                  id: 'episode-$i',
                  title: 'Synthetic S01E$i',
                  kind: ContentKind.episode,
                  seasonNumber: 1,
                  episodeNumber: i,
                ),
          ],
        ),
      );
      final closed = navigator.currentState!.push(playerRoute());
      await tester.pump();
      final placeholder = find.byKey(const ValueKey('native-player-startup'));
      expect(placeholder, findsOneWidget);
      expect(loaderPaintMs, isNotNull);
      expect(
        tester.getSize(placeholder),
        tester.view.physicalSize / tester.view.devicePixelRatio,
      );
      expect(
        await _waitForNote('native fullscreen adoptShared=${!_directVod}'),
        contains('adopted=${!_directVod}'),
      );
      final frameNote = await _waitForNote('native first frame');
      opening.stop();
      if (!_directVod) {
        await tester.pump();
        expect(placeholder, findsNothing);
      }
      final countersAfter = await ResourceCounters.snapshot();
      if (kDebugMode) {
        expect(countersAfter['exoEngines'], 1);
        expect(countersAfter['sharedEngineLive'], _directVod ? 0 : 1);
      }
      expect(ResourceCounters.mediaKitPlayers, 0);
      if (_directVod) {
        expect(startsBefore, 0);
        expect(transportStarts, greaterThan(0));
      } else {
        expect(
          transportStarts,
          startsBefore,
          reason: 'Handoff must not reopen HTTP',
        );
      }
      expect(playlistRequests, 1, reason: 'Handoff must not reload M3U');
      debugPrint(
        'LIVE_HANDOFF firstFrame="$frameNote" '
        'transportStarts=$startsBefore->$transportStarts counters=$countersAfter',
      );
      if (kProfileMode) {
        // Consumed only by the host-side test observer; never a player command.
        // ignore: avoid_print
        print('TVBRO_HANDOFF_CLOSE_NOW');
      }
      await closed.timeout(const Duration(seconds: 15));
      final previewReturns = <String>[];
      if (!_directVod) {
        preview.adoptedByFullscreen = false;
        await tester.pump();
        // PlayerScreen releases its channel handler when the route disposes.
        // Observe the shared engine's delayed frame sample after that release.
        native.setMethodCallHandler(recordDiagnostic);
        previewReturns.add(await _waitForPreviewFrames());
        if (kDebugMode) {
          final notesBeforeRepeat = log.entries.length;
          preview.adoptedByFullscreen = true;
          final closedAgain = navigator.currentState!.push(playerRoute());
          await tester.pump();
          expect(
            await _waitForNote(
              'native fullscreen adoptShared=true',
              after: notesBeforeRepeat,
            ),
            contains('adopted=true'),
          );
          await _waitForNote('native first frame', after: notesBeforeRepeat);
          await closedAgain.timeout(const Duration(seconds: 15));
          preview.adoptedByFullscreen = false;
          await tester.pump();
          native.setMethodCallHandler(recordDiagnostic);
          previewReturns.add(
            await _waitForPreviewFrames(after: notesBeforeRepeat),
          );
        }
        expect(
          transportStarts,
          startsBefore,
          reason: 'Returning to preview must keep the existing HTTP transport',
        );
        expect(playlistRequests, 1, reason: 'Returning must not reload M3U');
        expect(ResourceCounters.mediaKitPlayers, 0);
        if (kDebugMode) {
          final countersReturned = await ResourceCounters.snapshot();
          expect(countersReturned['exoEngines'], 1);
          expect(countersReturned['sharedEngineLive'], 1);
        }
      }
      binding.reportData = {
        'native_handoff': {
          'buildMode': kProfileMode ? 'profile' : 'debug',
          'directVod': _directVod,
          'routeToLoaderPaintMs': loaderPaintMs,
          'routeToFrameMs': opening.elapsedMilliseconds,
          'transportStartsBefore': startsBefore,
          'transportStartsAfter': transportStarts,
          'playlistRequests': playlistRequests,
          'firstFrame': frameNote,
          'previewReturns': previewReturns,
          'notes': [for (final entry in log.entries) entry.message],
        },
      };
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !Platform.isAndroid || _fixtureUrl.isEmpty,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<String> _waitForPreviewFrames({int after = 0}) async {
  await _waitForNote('preview first frame sinceReattachMs=', after: after);
  final sample = await _waitForNote(
    'preview reattach sample renderedDelta=',
    after: after,
  );
  final rendered = RegExp(r'renderedDelta=(-?\d+)').firstMatch(sample);
  expect(rendered, isNotNull);
  expect(
    int.parse(rendered!.group(1)!),
    greaterThan(1),
    reason:
        'Preview must render continuing frames after fullscreen returns: $sample',
  );
  debugPrint('LIVE_HANDOFF return="$sample"');
  return sample;
}

Future<String> _waitForNote(String text, {int after = 0}) {
  final log = DiagnosticsLog.instance;
  final result = Completer<String>();
  void changed() {
    for (final entry in log.entries.skip(after)) {
      if (entry.message.contains(text) && !result.isCompleted) {
        result.complete(entry.message);
      }
    }
  }

  log.addListener(changed);
  changed();
  return result.future
      .timeout(const Duration(seconds: 20))
      .whenComplete(() => log.removeListener(changed));
}

class _Repository implements LibraryRepository {
  _Repository(this.source);
  @override
  final Source source;
  @override
  Future<StreamInfo> resolve(Channel channel) async {
    await source.connect();
    return source.resolve(channel);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
