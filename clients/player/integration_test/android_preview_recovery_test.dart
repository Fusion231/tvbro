import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:iptvs/data/diagnostics_log.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/player/buffer_preset.dart';
import 'package:iptvs/player/resource_counters.dart';
import 'package:iptvs/screens/live_preview_controller.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native preview re-resolves when a live segment stays buffering',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final segmentRequested = Completer<void>();
      final stalledResponses = <HttpResponse, Timer>{};
      final subscription = server.listen((request) async {
        final response = request.response;
        if (request.uri.path == '/live.m3u8') {
          response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          response.write('''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:2
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:2.0,
segment0.ts
#EXTINF:2.0,
segment1.ts
#EXTINF:2.0,
segment2.ts
''');
          await response.close();
        } else if (request.uri.path.endsWith('.ts')) {
          response.headers.contentType = ContentType('video', 'mp2t');
          // Never supply enough data for even one TS packet. A byte per second
          // keeps the HTTP read timeout from racing the buffering deadline:
          // only the native preview's 8s stall recovery can restart this feed.
          final timer = Timer.periodic(const Duration(seconds: 1), (timer) {
            try {
              response.add(const [0x47]);
              unawaited(
                response.flush().catchError((Object _) => timer.cancel()),
              );
            } catch (_) {
              timer.cancel();
            }
          });
          stalledResponses[response] = timer;
          if (!segmentRequested.isCompleted) segmentRequested.complete();
        } else {
          response.statusCode = HttpStatus.notFound;
          await response.close();
        }
      });
      final stream = StreamInfo(
        url: 'http://127.0.0.1:${server.port}/live.m3u8',
      );
      final repo = _RetryRepository(stream);
      final preview = LivePreviewController(repo: repo);
      const channel = Channel(id: 'stall-test', name: 'Native stall fixture');
      DiagnosticsLog.instance.clear();
      final playersBefore = ResourceCounters.mediaKitPlayers;

      addTearDown(() async {
        await preview.stop(clearSelection: true);
        if (!repo.retryResult.isCompleted) repo.retryResult.complete(stream);
        await preview.pendingStart;
        preview.dispose();
        for (final entry in stalledResponses.entries) {
          entry.value.cancel();
          unawaited(entry.key.close().catchError((Object _) {}));
        }
        await server.close(force: true);
        await subscription.cancel();
      });

      await preview.start(channel, bufferPreset: BufferPreset.normal);
      expect(preview.nativeActive, isTrue);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 180,
              child: PreviewVideo(preview: preview),
            ),
          ),
        ),
      );
      await segmentRequested.future.timeout(const Duration(seconds: 10));
      await repo.retryStarted.future.timeout(const Duration(seconds: 20));

      expect(repo.resolves, 2);
      expect(preview.hasEmbeddedPlayer, isFalse);
      expect(ResourceCounters.mediaKitPlayers, playersBefore);
      expect(
        DiagnosticsLog.instance.entries.any(
          (entry) => entry.message.contains(
            'preview stall restart channel=Native stall fixture',
          ),
        ),
        isTrue,
        reason: 'The native buffering deadline must trigger the retry.',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(seconds: 25)),
  );
}

class _RetryRepository implements LibraryRepository {
  _RetryRepository(this.stream);

  final StreamInfo stream;
  final retryStarted = Completer<void>();
  final retryResult = Completer<StreamInfo>();
  int resolves = 0;

  @override
  final Source source = DemoSource();

  @override
  Future<StreamInfo> resolve(Channel channel) {
    resolves++;
    if (resolves == 1) return Future.value(stream);
    if (!retryStarted.isCompleted) retryStarted.complete();
    return retryResult.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
