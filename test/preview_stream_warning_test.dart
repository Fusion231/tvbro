import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/net.dart';
import 'package:iptvs/data/provider_stream_gate.dart';
import 'package:iptvs/player/buffer_preset.dart';
import 'package:iptvs/player/playback_backend.dart';
import 'package:iptvs/screens/live_preview_controller.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

const _account = ProviderStreamAccount(id: 'busy-account');
const _stream = StreamInfo(
  url: 'https://warning.test/live.m3u8',
  providerAccount: _account,
);

class _Repository implements LibraryRepository {
  @override
  final Source source = DemoSource();

  @override
  Future<StreamInfo> resolve(Channel channel) async => _stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PreviewPlayer extends PlatformPlayer {
  _PreviewPlayer() : super(configuration: const PlayerConfiguration());
  int opens = 0;
  int disposals = 0;

  void refuse() => logController.add(
    PlayerLog(prefix: 'curl', level: 'error', text: 'HTTP error 403'),
  );

  @override
  Future<void> open(Playable playable, {bool play = true}) async => opens++;
  @override
  Future<void> stop() async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> dispose() async {
    disposals++;
    errorController.add('Failed to open the previous stream');
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final gate = ProviderStreamGate.instance;
  late List<_PreviewPlayer> players;

  setUp(() {
    gate.debugReset();
    ProviderRequestGate.instance.debugReset();
    gate.reserve(_stream, owner: Object());
    players = [];
    PlaybackBackend.register(
      initialize: () {},
      createPlayer: (_) {
        final engine = _PreviewPlayer();
        players.add(engine);
        return Player(platformPlayer: engine);
      },
      ownsPlayer: (_) => true,
      buildVideo: (_, _, _) => const SizedBox.shrink(),
    );
  });

  tearDown(() {
    gate.debugReset();
    ProviderRequestGate.instance.debugReset();
  });

  for (final accepted in [false, true]) {
    test(
      'preview opens only after the warning is accepted=$accepted',
      () async {
        final decision = Completer<bool>();
        final warned = Completer<void>();
        final preview = LivePreviewController(
          repo: _Repository(),
          onStreamLimit: (limit) {
            expect(limit.limit, 1);
            warned.complete();
            return decision.future;
          },
        );
        addTearDown(preview.dispose);
        final opening = preview.start(
          const Channel(id: 'one', name: 'One'),
          bufferPreset: BufferPreset.normal,
        );
        await warned.future;
        expect(players, isEmpty);
        expect(gate.activeStreams(_account.id), 1);
        decision.complete(accepted);
        await opening;
        expect(
          players.fold(0, (count, player) => count + player.opens),
          accepted ? 1 : 0,
        );
        expect(preview.stream, accepted ? same(_stream) : isNull);
        expect(preview.error, isNull);
        expect(preview.loading, isFalse);
        expect(gate.activeStreams(_account.id), accepted ? 2 : 1);
        await preview.stop(clearSelection: true);
        expect(gate.activeStreams(_account.id), 1);
      },
    );
  }

  test(
    'stopping while warning is pending prevents a late approved open',
    () async {
      final decision = Completer<bool>();
      final warned = Completer<void>();
      final preview = LivePreviewController(
        repo: _Repository(),
        onStreamLimit: (_) {
          warned.complete();
          return decision.future;
        },
      );
      addTearDown(preview.dispose);
      final opening = preview.start(
        const Channel(id: 'one', name: 'One'),
        bufferPreset: BufferPreset.normal,
      );
      await warned.future;
      await preview.stop(clearSelection: true);
      decision.complete(true);
      await opening;
      expect(players, isEmpty);
      expect(preview.channelId, isNull);
      expect(preview.stream, isNull);
      expect(gate.activeStreams(_account.id), 1);
    },
  );

  test('watch anyway does not override a provider HTTP refusal', () async {
    final preview = LivePreviewController(
      repo: _Repository(),
      onStreamLimit: (_) async {
        ProviderRequestGate.instance.recordResponse(
          Uri.parse(_stream.url),
          401,
        );
        return true;
      },
    );
    addTearDown(preview.dispose);
    await preview.start(
      const Channel(id: 'one', name: 'One'),
      bufferPreset: BufferPreset.normal,
    );
    expect(players, isEmpty);
    expect(preview.error, isNotNull);
    expect(gate.activeStreams(_account.id), 1);
  });

  test('an earlier HTTP 403 does not block a manual preview open', () async {
    ProviderRequestGate.instance.recordResponse(Uri.parse(_stream.url), 403);
    final preview = LivePreviewController(
      repo: _Repository(),
      onStreamLimit: (_) async => true,
    );
    addTearDown(preview.dispose);

    await preview.start(
      const Channel(id: 'one', name: 'One'),
      bufferPreset: BufferPreset.normal,
    );

    expect(players.single.opens, 1);
    expect(preview.error, isNull);
    expect(gate.activeStreams(_account.id), 2);
  });

  for (final stopFirst in [false, true]) {
    test('manual preview retry after 403 replaces the rejected engine, stop=$stopFirst', () async {
      final preview = LivePreviewController(
        repo: _Repository(),
        onStreamLimit: (_) async => true,
      );
      addTearDown(preview.dispose);
      const channel = Channel(id: 'one', name: 'One');
      await preview.start(channel, bufferPreset: BufferPreset.normal);
      final rejected = players.single;
      final refusal = Completer<void>();
      preview.addListener(() {
        if (preview.error?.contains('HTTP 403') == true && !refusal.isCompleted) {
          refusal.complete();
        }
      });
      rejected.refuse();
      await refusal.future;
      if (stopFirst) await preview.stop();

      await preview.start(channel, bufferPreset: BufferPreset.normal);

      expect(rejected.disposals, 1);
      expect(players, hasLength(2));
      expect(players.last.opens, 1);
      expect(preview.error, isNull);
      expect(preview.stream, same(_stream));
      await preview.discardPlayer();
    });
  }
}
