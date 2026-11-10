import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:iptvs/data/provider_request_gate.dart';
import 'package:iptvs/data/provider_stream_gate.dart';
import 'package:iptvs/l10n/app_localizations.dart';
import 'package:iptvs/player/buffer_preset.dart';
import 'package:iptvs/player/live_zap_controller.dart';
import 'package:iptvs/player/player_screen.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/theme.dart';

class _WarningPlayer extends PlatformPlayer {
  _WarningPlayer() : super(configuration: const PlayerConfiguration());

  int plays = 0;
  int opens = 0;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opens++;
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> play() async {
    plays++;
  }

  @override
  Future<void> pause() async {}
}

class _WarningZapCatalog implements ZapCatalog {
  _WarningZapCatalog(this.next);
  final StreamInfo next;

  @override
  Future<StreamInfo> resolve(ZapEntry entry) async => next;
  @override
  ({Programme? now, Programme? next}) epgFor(ZapEntry entry) =>
      (now: null, next: null);
  @override
  bool isFavorite(ZapEntry entry) => false;
  @override
  String? aspectLabelFor(ZapEntry entry) => null;
  @override
  BufferPreset bufferPresetFor(ZapEntry entry) => BufferPreset.normal;
  @override
  void log(String note) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const native = MethodChannel('iptvs/native_hdr_player');
  const account = ProviderStreamAccount(id: 'warning-account');
  const stream = StreamInfo(
    url: 'https://stream-warning.test/movie/fixture.mkv',
    isLive: false,
    providerAccount: account,
  );
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final gate = ProviderStreamGate.instance;
  var surfaceRequests = 0;
  final nativeCalls = <MethodCall>[];

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    gate.debugReset();
    ProviderRequestGate.instance.debugReset();
    AppLanguageController.instance.preview(AppLanguage.english);
    surfaceRequests = 0;
    nativeCalls.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
      call,
    ) async {
      nativeCalls.add(call);
      if (call.method == 'createSurface') {
        surfaceRequests++;
        return 42;
      }
      return true;
    });
  });

  tearDown(() {
    gate.debugReset();
    ProviderRequestGate.instance.debugReset();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(native, null);
  });

  Future<_WarningPlayer> open(WidgetTester tester) async {
    gate.reserve(stream, owner: Object());
    final engine = _WarningPlayer();
    final player = Player(platformPlayer: engine);
    addTearDown(player.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PlayerScreen(
                    title: 'Fixture',
                    stream: stream,
                    existingPlayer: player,
                  ),
                ),
              ),
              child: const Text('Open player'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open player'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(find.text('Provider stream limit'), findsOneWidget);
    expect(engine.plays, 0);
    expect(surfaceRequests, 0);
    expect(gate.activeStreams(account.id), 1);
    return engine;
  }

  testWidgets('fullscreen opens only after Watch anyway is selected', (
    tester,
  ) async {
    final engine = await open(tester);
    await tester.tap(find.text('Watch anyway'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    expect(find.text('Provider stream limit'), findsNothing);
    expect(gate.activeStreams(account.id), 2);
    expect(surfaceRequests, 1);
    expect(engine.plays, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows);

  testWidgets('cancelling fullscreen warning returns to the channel list', (
    tester,
  ) async {
    final engine = await open(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 3),
    );

    expect(find.byType(PlayerScreen), findsNothing);
    expect(find.text('Open player'), findsOneWidget);
    expect(gate.activeStreams(account.id), 1);
    expect(surfaceRequests, 0);
    expect(engine.plays, 0);
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows);

  testWidgets(
    'disposing fullscreen while warning is open cannot start playback',
    (tester) async {
      final engine = await open(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(gate.activeStreams(account.id), 1);
      expect(surfaceRequests, 0);
      expect(engine.plays, 0);
      expect(tester.takeException(), isNull);
    },
    skip: !Platform.isWindows,
  );

  for (final accepted in [false, true]) {
    testWidgets(
      'native-surface cross-account zap warning is accepted=$accepted',
      (tester) async {
        const first = StreamInfo(
          url: 'https://stream-warning.test/first.ts',
          providerAccount: ProviderStreamAccount(id: 'first-account'),
        );
        const next = StreamInfo(
          url: 'https://stream-warning.test/next.ts',
          providerAccount: ProviderStreamAccount(id: 'next-account'),
        );
        gate.reserve(next, owner: Object());
        final zap = LiveZapController(
          entries: [
            for (final id in ['first', 'next'])
              ZapEntry(
                channel: Channel(id: id, name: id),
                config: SourceConfig(
                  id: id,
                  kind: SourceKind.demo,
                  label: id,
                  fields: const {},
                ),
                sourceName: id,
              ),
          ],
          initialIndex: 0,
          catalog: _WarningZapCatalog(next),
          settleDelay: const Duration(milliseconds: 1),
        );
        addTearDown(zap.dispose);
        final engine = _WarningPlayer();
        final player = Player(platformPlayer: engine);
        addTearDown(player.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => PlayerScreen(
                        title: 'first',
                        stream: first,
                        existingPlayer: player,
                        zap: zap,
                      ),
                    ),
                  ),
                  child: const Text('Open player'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open player'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();
        expect(surfaceRequests, 1);
        expect(gate.activeStreams('first-account'), 1);
        expect(engine.opens, 0);
        nativeCalls.clear();

        zap.channelUp();
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();
        expect(find.text('Provider stream limit'), findsOneWidget);
        expect(
          nativeCalls
              .where((call) => call.method == 'setSurfaceVisible')
              .map((call) => call.arguments),
          [false],
        );
        expect(gate.activeStreams('next-account'), 1);
        expect(engine.opens, 0);
        await tester.pump(const Duration(seconds: 35));
        expect(find.text('Provider stream limit'), findsOneWidget);
        expect(engine.opens, 0);

        await tester.tap(find.text(accepted ? 'Watch anyway' : 'Cancel'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();
        if (!accepted) {
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 3),
          );
        }
        expect(find.text('Provider stream limit'), findsNothing);
        expect(
          nativeCalls
              .where((call) => call.method == 'setSurfaceVisible')
              .map((call) => call.arguments),
          [false, true],
        );
        expect(engine.opens, accepted ? 1 : 0);
        expect(gate.activeStreams('next-account'), accepted ? 2 : 1);
        expect(
          find.byType(PlayerScreen),
          accepted ? findsOneWidget : findsNothing,
        );
        expect(surfaceRequests, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
      skip: !Platform.isWindows,
    );
  }
}
