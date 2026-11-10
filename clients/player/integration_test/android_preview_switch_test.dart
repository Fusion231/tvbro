import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/player/buffer_preset.dart';
import 'package:iptvs/player/player_screen.dart' show reconnectMinGapMs;
import 'package:iptvs/screens/live_preview_controller.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

typedef _ResolveRequest = ({Channel channel, Completer<StreamInfo> result});

class _PreviewRepository implements LibraryRepository {
  @override
  final Source source = DemoSource();

  final requests = <_ResolveRequest>[];
  final _requested = StreamController<_ResolveRequest>.broadcast(sync: true);

  Future<_ResolveRequest> nextResolution({
    Duration timeout = const Duration(seconds: 5),
  }) => _requested.stream.first.timeout(timeout);

  @override
  Future<StreamInfo> resolve(Channel channel) {
    final request = (channel: channel, result: Completer<StreamInfo>());
    requests.add(request);
    _requested.add(request);
    return request.result.future;
  }

  Future<void> close() => _requested.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  const channel = MethodChannel('iptvs/native_preview');
  const channelA = Channel(id: 'a', name: 'Channel A');
  const channelB = Channel(id: 'b', name: 'Channel B');
  const channelC = Channel(id: 'c', name: 'Channel C');
  late _PreviewRepository repo;
  late LivePreviewController preview;
  late List<MethodCall> nativeCalls;
  late List<String> errors;

  List<MethodCall> getOpens() => nativeCalls
      .where((call) => call.method == 'open')
      .toList(growable: false);

  int requestIdOf(MethodCall call) =>
      (call.arguments as Map)['requestId'] as int;

  Future<void> sendEvent(String event, int requestId, {String? reason}) =>
      messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          MethodCall('previewEvent', {
            'event': event,
            'requestId': requestId,
            'reason': ?reason,
            if (event == 'error') 'message': 'stream interrupted',
          }),
        ),
        (_) {},
      );

  setUp(() {
    repo = _PreviewRepository();
    nativeCalls = [];
    errors = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      return call.method == 'open' ? true : null;
    });
    preview = LivePreviewController(repo: repo, onError: errors.add);
  });

  tearDown(() async {
    await preview.stop(clearSelection: true);
    preview.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    await repo.close();
  });

  testWidgets(
    'native switching retains its engine and ignores old channel events',
    (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final firstResolution = repo.nextResolution();
      final firstStart = preview.start(
        channelA,
        muted: false,
        bufferPreset: BufferPreset.normal,
      );
      final firstRequest = await firstResolution;
      firstRequest.result.complete(
        const StreamInfo(url: 'https://example.test/channel-a.m3u8'),
      );
      await firstStart;
      expect(preview.nativeActive, isTrue);
      expect(preview.hasEmbeddedPlayer, isFalse);
      expect(getOpens(), hasLength(1));
      final tokenA = requestIdOf(getOpens().single);

      final nextResolution = repo.nextResolution();
      final nextStart = preview.start(
        channelB,
        muted: false,
        bufferPreset: BufferPreset.normal,
      );
      final nextRequest = await nextResolution;
      expect(nextRequest.channel.id, 'b');
      expect(preview.nativeActive, isTrue);
      expect(preview.loading, isTrue);
      expect(preview.stream, isNull);
      expect(preview.hasEmbeddedPlayer, isFalse);
      expect(nativeCalls.last.method, 'stopForChannelSwitch');

      for (final event in ['unsupported', 'error', 'recover']) {
        await sendEvent(event, tokenA, reason: 'ended');
      }
      expect(preview.nativeActive, isTrue);
      expect(preview.loading, isTrue);
      expect(preview.error, isNull);
      expect(preview.channelId, 'b');
      expect(preview.hasEmbeddedPlayer, isFalse);
      expect(repo.requests, hasLength(2));

      nextRequest.result.complete(
        const StreamInfo(url: 'https://example.test/channel-b.m3u8'),
      );
      await nextStart;
      expect(getOpens(), hasLength(2));
      final tokenB = requestIdOf(getOpens().last);
      expect(tokenB, greaterThan(tokenA));
      expect(preview.nativeActive, isTrue);
      expect(preview.stream?.url, 'https://example.test/channel-b.m3u8');
      expect(preview.error, isNull);
      expect(preview.hasEmbeddedPlayer, isFalse);

      final stoppedResolution = repo.nextResolution();
      final stoppedStart = preview.start(
        channelC,
        bufferPreset: BufferPreset.normal,
      );
      final stoppedRequest = await stoppedResolution;
      await preview.stop(clearSelection: true);
      stoppedRequest.result.complete(
        const StreamInfo(url: 'https://example.test/channel-c.m3u8'),
      );
      await stoppedStart;

      expect(getOpens(), hasLength(2));
      expect(preview.nativeActive, isFalse);
      expect(preview.channelId, isNull);
      expect(preview.stream, isNull);
      expect(preview.loading, isFalse);
      expect(preview.error, isNull);
      expect(preview.hasEmbeddedPlayer, isFalse);
      expect(errors, isEmpty);
    },
    skip: !Platform.isAndroid,
  );

  testWidgets(
    'native recovery re-resolves once and stop cancels its queued retry',
    (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final firstResolution = repo.nextResolution();
      final firstStart = preview.start(
        channelA,
        bufferPreset: BufferPreset.normal,
      );
      final firstRequest = await firstResolution;
      firstRequest.result.complete(
        const StreamInfo(url: 'https://example.test/channel-a.m3u8'),
      );
      await firstStart;
      final tokenA = requestIdOf(getOpens().single);

      final retryResolution = repo.nextResolution();
      await sendEvent('recover', tokenA, reason: 'error');
      await sendEvent('recover', tokenA, reason: 'ended');
      final retryRequest = await retryResolution;
      expect(repo.requests, hasLength(2));
      expect(retryRequest.channel.id, 'a');
      expect(preview.nativeActive, isTrue);
      expect(preview.hasEmbeddedPlayer, isFalse);

      final retryStart = preview.pendingStart;
      retryRequest.result.complete(
        const StreamInfo(url: 'https://example.test/channel-a-fresh.m3u8'),
      );
      await retryStart;
      expect(getOpens(), hasLength(2));
      final retryToken = requestIdOf(getOpens().last);
      expect(retryToken, greaterThan(tokenA));

      // A second failure inside the reconnect backoff queues one retry.
      // Observe requests through that entire window so stop cannot pass by
      // merely clearing the current UI state while a delayed start survives.
      await sendEvent('recover', retryToken, reason: 'ended');
      expect(repo.requests, hasLength(2));
      final unexpectedRetry = repo.nextResolution(
        timeout: Duration(
          milliseconds: reconnectMinGapMs(priorAttempts: 1, force: false) + 250,
        ),
      );
      await preview.stop(clearSelection: true);
      await expectLater(unexpectedRetry, throwsA(isA<TimeoutException>()));

      expect(repo.requests, hasLength(2));
      expect(getOpens(), hasLength(2));
      expect(preview.nativeActive, isFalse);
      expect(preview.channelId, isNull);
      expect(preview.stream, isNull);
      expect(preview.loading, isFalse);
      expect(preview.error, isNull);
      expect(preview.hasEmbeddedPlayer, isFalse);
      expect(errors, isEmpty);
    },
    skip: !Platform.isAndroid,
  );
}
