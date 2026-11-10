import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/channel_organization.dart';
import 'package:iptvs/data/parental_controls.dart';
import 'package:iptvs/data/profile_pin.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/channel_list_screen.dart';
import 'package:iptvs/screens/global_search_view.dart';
import 'package:iptvs/screens/live_tab_view.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/widgets/tv_text_field.dart';
import 'package:iptvs/widgets/routed_focus_node.dart';

void main() {
  late Directory tempDir;
  late AppDatabase db;
  var mediaKitAvailable = false;

  setUpAll(() {
    debugDisableNetworkChannelLogos = true;
    try {
      MediaKit.ensureInitialized();
      mediaKitAvailable = true;
    } catch (_) {
      // The wide live screen creates a headless preview player.
    }
  });

  tearDownAll(() => debugDisableNetworkChannelLogos = false);

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('iptvs_search_test');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('search combines all content and survives tab changes', (
    tester,
  ) async {
    if (!mediaKitAvailable) {
      markTestSkipped('libmpv not available in this environment');
      return;
    }

    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const config = SourceConfig(
      id: 'demo',
      kind: SourceKind.demo,
      label: 'Demo',
      fields: {},
    );
    final repo = LibraryRepository(source: _SearchDemoSource(), db: db);

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: ChannelListScreen(
            repo: repo,
            config: config,
            store: SourceStore(),
          ),
        ),
      );
      await _pumpUntil(tester, find.text('Channel groups'));
      expect(find.textContaining('synced'), findsNothing);

      // The selected group must not limit global search.
      await tester.tap(find.text('Other channels'));
      await tester.pump();

      await tester.tap(find.byType(TvTextField));
      await tester.pump();
      final searchField = find.byType(TextField);
      await tester.enterText(searchField, 'Bunny');
      await tester.pump();

      Future<void> expectCombinedResults() async {
        final scroll = tester
            .widget<CustomScrollView>(
              find.descendant(
                of: find.byType(GlobalSearchView),
                matching: find.byType(CustomScrollView),
              ),
            )
            .controller!;
        scroll.jumpTo(0);
        await tester.pump();
        expect(find.text('Bunny TV'), findsOneWidget);
        expect(find.text('Big Buck Bunny'), findsOneWidget);
        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pump();
        expect(find.text('Bunny Series'), findsOneWidget);
        scroll.jumpTo(0);
        await tester.pump();
      }

      await _pumpUntil(tester, find.text('Big Buck Bunny'));
      await expectCombinedResults();
      expect(tester.widget<TextField>(searchField).controller!.text, 'Bunny');

      await tester.tap(find.text('Movies').first);
      await tester.pump();
      await expectCombinedResults();
      await tester.tap(find.text('Series').first);
      await tester.pump();
      await expectCombinedResults();
      expect(tester.widget<TextField>(searchField).controller!.text, 'Bunny');

      // Remote Down reaches results; Back returns to search, then closes it.
      tester
          .widget<TvTextField>(find.byType(TvTextField))
          .cellFocusNode!
          .requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        focusRouteKey(FocusManager.instance.primaryFocus),
        startsWith('search.'),
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(
        focusRouteKey(FocusManager.instance.primaryFocus),
        'live.search.cell',
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(GlobalSearchView), findsNothing);
      expect(
        tester.widget<TvTextField>(find.byType(TvTextField)).controller.text,
        isEmpty,
      );
      await _pumpUntil(tester, find.text('Bunny Series'));
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => db.epgIngest.cancelAndWait());
      await tester.pump(const Duration(seconds: 11));
    }
  });
  testWidgets(
    'parental locks remove results immediately and aliases remain user-owned',
    (tester) async {
      if (!mediaKitAvailable) {
        markTestSkipped('libmpv not available in this environment');
        return;
      }
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controls = ParentalControlService.instance;
      final verifier = hashProfilePin(
        '4821',
        salt: List.filled(16, 7),
        iterations: 1,
      );
      await controls.ensureInitialized();
      await controls.save(
        ParentalRules(
          verifier: verifier,
          channels: {ParentalRules.channelKey('demo', 'bunny-channel')},
          categories: {
            ParentalRules.categoryKey('demo', ContentKind.movie, 'restricted'),
          },
        ),
      );
      final config =
          const SourceConfig(
            id: 'demo',
            kind: SourceKind.demo,
            label: 'Demo',
            fields: {},
          ).withChannelOrganization(
            const ChannelOrganization(names: {'bunny-channel': 'My Bunny TV'}),
          );
      final repo = LibraryRepository(source: _SearchDemoSource(), db: db);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: ChannelListScreen(
              repo: repo,
              config: config,
              store: SourceStore(),
            ),
          ),
        );
        await _pumpUntil(tester, find.text('Channel groups'));
        await tester.tap(find.byType(TvTextField));
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'Bunny');
        await tester.pump();
        await _pumpUntil(tester, find.text('Bunny Series'));
        expect(find.text('My Bunny TV'), findsNothing);
        expect(find.text('Big Buck Bunny'), findsNothing);
        controls.unlock(verifier);
        await tester.pump();
        await _pumpUntil(tester, find.text('Big Buck Bunny'));
        expect(find.text('My Bunny TV'), findsOneWidget);
        controls.lock();
        await tester.pump();
        await _pumpUntil(tester, find.text('Bunny Series'));
        expect(find.text('My Bunny TV'), findsNothing);
        expect(find.text('Big Buck Bunny'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => db.epgIngest.cancelAndWait());
        await tester.pump(const Duration(seconds: 11));
        await controls.save(const ParentalRules());
      }
    },
  );
}

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 80; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(finder, findsOneWidget);
}

class _SearchDemoSource extends DemoSource {
  @override
  Future<List<Category>> categories() async => const [
    Category(id: 'other', title: 'Other channels'),
    Category(id: 'bunny', title: 'Bunny channels'),
  ];

  @override
  Future<List<Channel>> channels({String? categoryId}) async => const [
    Channel(id: 'other-channel', name: 'Other TV', categoryId: 'other'),
    Channel(id: 'bunny-channel', name: 'Bunny TV', categoryId: 'bunny'),
  ];

  @override
  Future<List<Programme>> epg(List<Channel> channels) async => const [];

  static const _movies = [
    MediaItem(
      id: 'search-movie',
      title: 'Big Buck Bunny',
      kind: ContentKind.movie,
    ),
  ];
  static const _series = [
    MediaItem(
      id: 'search-series',
      title: 'Bunny Series',
      kind: ContentKind.series,
    ),
  ];

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async =>
      const [];

  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async => switch (kind) {
    ContentKind.movie => _movies,
    ContentKind.series => _series,
    _ => const [],
  };

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async => MediaPage(
    items: await mediaItems(kind, categoryId: categoryId, parent: parent),
    page: page,
    totalPages: 1,
  );

  @override
  Future<List<MediaItem>> searchMedia(
    ContentKind kind,
    String query, {
    String? categoryId,
  }) async {
    final items = await mediaItems(kind, categoryId: categoryId);
    final normalized = query.trim().toLowerCase();
    return items
        .where((item) => item.title.toLowerCase().contains(normalized))
        .toList(growable: false);
  }
}
