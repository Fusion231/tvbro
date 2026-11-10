import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/player/playback_backend.dart';
import 'package:iptvs/player/player_screen.dart';
import 'package:iptvs/screens/channel_list_screen.dart';
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/theme.dart';

const _movie = MediaItem(
  id: 'windows-home-movie',
  title: 'Windows navigation movie',
  kind: ContentKind.movie,
);

void main() {
  const native = MethodChannel('iptvs/native_hdr_player');
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;
  late AppDatabase db;
  final nativeCalls = <String>[];

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('tvbro_windows_movie_home');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
    FlutterSecureStorage.setMockInitialValues({});
    nativeCalls.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
      call,
    ) async {
      nativeCalls.add(call.method);
      if (call.method == 'createSurface') return 42;
      return true;
    });
    // Keep the real Windows surface/exit channel path and Flutter routes,
    // while replacing media decoding and the HWND implementation in this test.
    PlaybackBackend.register(
      initialize: () {},
      createPlayer: (configuration) =>
          Player(platformPlayer: _MoviePlayer(configuration: configuration)),
      ownsPlayer: (_) => true,
      buildVideo: (_, _, _) => const SizedBox.shrink(),
    );
  });

  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(native, null);
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('mouse Home works after returning from a Windows movie', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = LibraryRepository(
      source: _MovieSource(),
      db: db,
      metadataProviders: const [],
      autoEnrichMetadata: false,
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: ChannelListScreen(
            repo: repo,
            config: const SourceConfig(
              id: 'demo',
              kind: SourceKind.demo,
              label: 'Demo',
              fields: {},
            ),
            store: SourceStore(),
          ),
        ),
      );
      final rootBarrierCount = find.byType(ModalBarrier).evaluate().length;
      await tester.tap(find.byKey(const ValueKey('home-movie')));
      await _pumpUntil(
        tester,
        () => find.text('More info').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('More info'));
      await _pumpUntil(
        tester,
        () => find.byType(MediaDetailsSheet).evaluate().isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('media.details.play')));
      await _pumpUntil(tester, () => nativeCalls.contains('createSurface'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(PlayerScreen), findsOneWidget);

      await binding.defaultBinaryMessenger.handlePlatformMessage(
        native.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('nativeControl', 'back'),
        ),
        (_) {},
      );
      await _pumpUntil(
        tester,
        () => find.byType(PlayerScreen).evaluate().isEmpty,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(nativeCalls, contains('prepareExit'));
      expect(find.byType(MediaDetailsSheet), findsNothing);

      final home = find.byTooltip('Home');
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(home));
      await mouse.down(tester.getCenter(home));
      await mouse.up();
      await mouse.removePointer();
      await tester.pump();

      for (final section in ['live', 'movie', 'series', 'favorites']) {
        expect(find.byKey(ValueKey('home-$section')), findsOneWidget);
      }
      expect(find.byType(ModalBarrier).evaluate().length, rootBarrierCount);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => db.epgIngest.cancelAndWait());
      await tester.pump(const Duration(seconds: 11));
    }
  }, skip: !Platform.isWindows);
}

// SQLite runs on its real isolate, so give it a turn between widget frames,
// as the existing integrated browsing tests do.
Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 80; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  fail('The movie navigation step did not complete.');
}

class _MovieSource extends DemoSource {
  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async =>
      const [];

  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async => kind == ContentKind.movie ? const [_movie] : const [];

  @override
  Future<StreamInfo> resolveMedia(MediaItem item) async => const StreamInfo(
    url: 'https://movie-navigation.test/movie.mp4',
    isLive: false,
  );
}

class _MoviePlayer extends PlatformPlayer {
  _MoviePlayer({required super.configuration});

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    state = state.copyWith(
      playing: play,
      duration: const Duration(minutes: 10),
    );
    playingController.add(play);
    durationController.add(state.duration);
  }

  @override
  Future<void> stop() async {
    state = state.copyWith(playing: false, position: Duration.zero);
  }

  @override
  Future<void> pause() async {
    state = state.copyWith(playing: false);
  }

  @override
  Future<void> setVolume(double volume) async {
    state = state.copyWith(volume: volume);
  }
}
