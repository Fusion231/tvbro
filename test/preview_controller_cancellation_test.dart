import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:iptvs/data/provider_stream_gate.dart';

import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/net.dart';
import 'package:iptvs/player/buffer_preset.dart';
import 'package:iptvs/player/player_screen.dart';
import 'package:iptvs/screens/live_preview_controller.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

class _PendingPreviewRepository implements LibraryRepository {
  @override
  final Source source = DemoSource();

  final resolution = Completer<StreamInfo>();
  var resolveCalls = 0;

  @override
  Future<StreamInfo> resolve(Channel channel) {
    resolveCalls++;
    return resolution.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    ProviderStreamGate.instance.debugReset();
    ProviderRequestGate.instance.debugReset();
  });
  tearDown(() {
    ProviderStreamGate.instance.debugReset();
    ProviderRequestGate.instance.debugReset();
  });

  test('failed provider resolution clears loading and explains the connection failure', () async {
    final repo = _PendingPreviewRepository();
    final errors = <String>[];
    final preview = LivePreviewController(repo: repo, onError: errors.add);
    addTearDown(preview.dispose);
    final opening = preview.start(
      const Channel(id: 'a', name: 'Channel A'),
      bufferPreset: BufferPreset.normal,
    );
    const error = SocketException('Failed host lookup: private-provider.test');
    repo.resolution.completeError(error);
    await opening;

    expect(preview.loading, isFalse);
    expect(preview.hasEmbeddedPlayer, isFalse);
    expect(preview.error, sourceLoadErrorMessage(error));
    expect(preview.error, isNot(contains('private-provider.test')));
    expect(errors, hasLength(1));
  });

  test('a full account prevents preview engine creation before any stream opens', () async {
    const account = ProviderStreamAccount(id: 'limited');
    const stream = StreamInfo(url: 'https://provider.test/live', providerAccount: account);
    ProviderStreamGate.instance.reserve(stream, owner: Object());
    final repo = _PendingPreviewRepository();
    final preview = LivePreviewController(repo: repo);
    addTearDown(preview.dispose);
    final opening = preview.start(const Channel(id: 'a', name: 'A'), bufferPreset: BufferPreset.normal);
    repo.resolution.complete(stream);
    await opening;
    expect(preview.hasEmbeddedPlayer, isFalse);
    expect(preview.loading, isFalse);
    expect(preview.error, contains('limit'));
    expect(ProviderStreamGate.instance.activeStreams(account.id), 1);
  });

  test('late native teardown releases its physical owner instead of a replacement', () async {
    const channel = MethodChannel('iptvs/native_preview');
    final stopped = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'stop') await stopped.future;
          return null;
        });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final preview = LivePreviewController(repo: _PendingPreviewRepository());
    addTearDown(preview.dispose);
    const account = ProviderStreamAccount(id: 'physical', maximumStreams: 2);
    const stream = StreamInfo(url: 'https://provider.test/live', providerAccount: account);
    final oldOwner = preview.providerStreamOwner;
    ProviderStreamGate.instance.reserve(stream, owner: oldOwner);
    preview.nativeActive = true;
    final teardown = preview.discardPlayer();
    expect(preview.providerStreamOwner, isNot(same(oldOwner)));
    ProviderStreamGate.instance.reserve(stream, owner: preview.providerStreamOwner);
    expect(ProviderStreamGate.instance.activeStreams(account.id), 2);
    stopped.complete();
    await teardown;
    expect(ProviderStreamGate.instance.activeStreams(account.id), 1);
  });

  test('a paused stream host prevents preview engine creation after resolving', () async {
    const blockedUrl = 'https://preview-refusal.example.test/live.m3u8';
    ProviderRequestGate.instance.recordResponse(Uri.parse(blockedUrl), 401);
    final repo = _PendingPreviewRepository();
    final errors = <String>[];
    final preview = LivePreviewController(repo: repo, onError: errors.add);
    addTearDown(preview.dispose);

    final opening = preview.start(
      const Channel(id: 'a', name: 'Channel A'),
      bufferPreset: BufferPreset.normal,
    );
    repo.resolution.complete(const StreamInfo(url: blockedUrl));
    await opening;

    expect(repo.resolveCalls, 1);
    expect(preview.loading, isFalse);
    expect(preview.hasEmbeddedPlayer, isFalse);
    expect(preview.nativeActive, isFalse);
    expect(preview.stream, isNull);
    expect(preview.error, contains('HTTP 401'));
    expect(errors, hasLength(1));

    expect(
      () => checkPlaybackProviderRequest(const StreamInfo(url: blockedUrl)),
      throwsA(isA<ProviderRequestBlocked>()),
    );
    const differentProvider = StreamInfo(url: 'https://preview-allowed.example.test/live.m3u8');
    expect(checkPlaybackProviderRequest(differentProvider), same(differentProvider));
  });

  for (final discard in [false, true]) {
    test(
      '${discard ? 'discarding' : 'stopping'} a pending preview prevents a late open',
      () async {
        final repo = _PendingPreviewRepository();
        final errors = <String>[];
        final preview = LivePreviewController(repo: repo, onError: errors.add);
        addTearDown(preview.dispose);

        final opening = preview.start(
          const Channel(id: 'a', name: 'Channel A'),
          bufferPreset: BufferPreset.normal,
        );
        expect(repo.resolveCalls, 1);
        expect(preview.loading, isTrue);

        if (discard) {
          await preview.discardPlayer();
        } else {
          await preview.stop(clearSelection: true);
        }
        repo.resolution.complete(
          const StreamInfo(url: 'https://example.test/channel-a.m3u8'),
        );
        await opening;

        expect(preview.channelId, isNull);
        expect(preview.stream, isNull);
        expect(preview.loading, isFalse);
        expect(preview.error, isNull);
        expect(preview.nativeActive, isFalse);
        expect(preview.hasEmbeddedPlayer, isFalse);
        expect(errors, isEmpty);
      },
    );
  }
}
