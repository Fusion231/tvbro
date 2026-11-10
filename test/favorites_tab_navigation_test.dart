import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/channel_list_chrome.dart';
import 'package:iptvs/screens/channel_list_screen.dart';
import 'package:iptvs/screens/favorites_tab_view.dart';
import 'package:iptvs/screens/global_search_view.dart';
import 'package:iptvs/screens/live_tab_view.dart';
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/theme.dart';
import 'package:iptvs/widgets/routed_focus_node.dart';
import 'package:iptvs/widgets/tv_text_field.dart';

const _active = SourceConfig(
  id: 'active',
  kind: SourceKind.demo,
  label: 'Local provider',
  fields: {},
);
const _foreign = SourceConfig(
  id: 'foreign',
  kind: SourceKind.demo,
  label: 'Other provider',
  fields: {},
);
const _localMovie = MediaItem(
  id: 'shared',
  title: 'Local saved movie',
  kind: ContentKind.movie,
);
const _foreignMovie = MediaItem(
  id: 'shared',
  title: 'Other saved movie',
  kind: ContentKind.movie,
);
const _series = MediaItem(
  id: 'series',
  title: 'Saved series catalogue',
  kind: ContentKind.series,
);

class _NavigationSource extends Source {
  int detailsOpened = 0;

  @override
  String get id => _active.id;

  @override
  String get name => _active.label;

  @override
  Future<void> connect() async {}

  @override
  Future<List<Category>> categories() async => const [];

  @override
  Future<List<Channel>> channels({String? categoryId}) async => const [
    Channel(id: 'channel', name: 'Local saved channel'),
  ];

  @override
  Future<StreamInfo> resolve(Channel channel) async =>
      throw UnsupportedError('Playback is outside this navigation fixture');

  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async => switch (kind) {
    ContentKind.movie => const [_localMovie],
    ContentKind.series => const [_series],
    _ => const [],
  };

  @override
  Future<MediaItem> mediaDetails(MediaItem item) async {
    detailsOpened++;
    return item;
  }
}

void main() {
  late Directory temp;
  late AppDatabase db;
  late SourceStore store;
  late _NavigationSource source;
  var mediaKitAvailable = false;

  setUpAll(() {
    debugDisableNetworkChannelLogos = true;
    try {
      MediaKit.ensureInitialized();
      mediaKitAvailable = true;
    } catch (_) {}
  });

  tearDownAll(() => debugDisableNetworkChannelLogos = false);

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('favorites_navigation');
    db = await AppDatabase.openAt('${temp.path}/library.db');
    store = SourceStore();
    source = _NavigationSource();
    await store.setAll([_active, _foreign]);
    await db.replaceLibrary(_active.id, _active.label, const [], const [
      Channel(id: 'channel', name: 'Local saved channel'),
    ]);
    await db.replaceLibrary(_foreign.id, _foreign.label, const [], const [
      Channel(id: 'channel', name: 'Other saved channel'),
    ]);
    await db.replaceMediaLibrary(
      _active.id,
      ContentKind.movie,
      const [],
      const [_localMovie],
    );
    await db.replaceMediaLibrary(
      _foreign.id,
      ContentKind.movie,
      const [],
      const [_foreignMovie],
    );
    await db.replaceMediaLibrary(
      _active.id,
      ContentKind.series,
      const [],
      const [_series],
    );
    for (final config in [_active, _foreign]) {
      await db.setFavorite(config.id, ContentKind.live, 'channel', true);
      await db.setFavorite(config.id, ContentKind.movie, 'shared', true);
    }
    await db.setFavorite(_active.id, ContentKind.series, _series.id, true);
  });

  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });

  Future<void> drain(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> until(WidgetTester tester, Finder finder) async {
    for (var frame = 0; frame < 50; frame++) {
      await drain(tester);
      if (finder.evaluate().isNotEmpty) return;
    }
    expect(finder, findsWidgets);
  }

  Finder tab(String title) => find.descendant(
    of: find.byType(ChannelContentTabs),
    matching: find.text(title),
  );

  Finder favoriteText(String title) => find.descendant(
    of: find.byType(FavoritesTabView),
    matching: find.text(title),
  );

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: ChannelListScreen(
          repo: LibraryRepository(source: source, db: db),
          config: _active,
          store: store,
        ),
      ),
    );
    await until(tester, find.text('Channel groups'));
  }

  void navigationTest(String description, WidgetTesterCallback callback) {
    testWidgets(description, (tester) async {
      if (!mediaKitAvailable) {
        markTestSkipped('libmpv is unavailable');
        return;
      }
      try {
        await callback(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => db.epgIngest.cancelAndWait());
        await tester.pump(const Duration(seconds: 11));
      }
    });
  }

  navigationTest('Favorites returns to the previously selected Series tab', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.tap(tab('Series'));
    await until(tester, find.text(_series.title));
    await tester.tap(tab('Favorites'));
    await until(tester, favoriteText(_foreignMovie.title));
    expect(favoriteText('Local saved channel'), findsOneWidget);
    expect(favoriteText('Other saved channel'), findsOneWidget);

    await tester.tap(tab('Series'));
    await tester.pump();
    expect(find.byType(FavoritesTabView), findsNothing);
    expect(find.text(_series.title), findsWidgets);
    final tabs = tester.widget<ChannelContentTabs>(
      find.byType(ChannelContentTabs),
    );
    expect(tabs.value, ContentKind.series);
    expect(tabs.favoritesSelected, isFalse);
    expect(tester.takeException(), isNull);
  });

  navigationTest('Favorites Back and search return focus to its own tab', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.tap(tab('Favorites'));
    await until(tester, favoriteText(_foreignMovie.title));
    final tabs = tester.widget<ChannelContentTabs>(
      find.byType(ChannelContentTabs),
    );
    tabs.favoritesFocusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      focusRouteKey(FocusManager.instance.primaryFocus),
      startsWith('favorites.'),
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(
      focusRouteKey(FocusManager.instance.primaryFocus),
      'content.tab.favorites',
    );

    await tester.tap(find.byType(TvTextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'unmatched');
    await tester.pump();
    expect(find.byType(GlobalSearchView), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();
    await until(tester, favoriteText(_foreignMovie.title));
    expect(find.byType(GlobalSearchView), findsNothing);
    expect(
      focusRouteKey(FocusManager.instance.primaryFocus),
      'content.tab.favorites',
    );
    expect(tester.takeException(), isNull);
  });

  navigationTest('foreign movie details and unfavorite use its owning source', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.tap(tab('Favorites'));
    await until(tester, favoriteText(_foreignMovie.title));
    await tester.ensureVisible(favoriteText(_foreignMovie.title));
    await tester.pump();
    await tester.tap(favoriteText(_foreignMovie.title));
    await until(tester, find.byType(MediaDetailsSheet));
    final details = tester.widget<MediaDetailsSheet>(
      find.byType(MediaDetailsSheet),
    );
    expect(details.repo.source.id, _foreign.id);
    expect(details.item.id, _localMovie.id);
    expect(details.favorite, isTrue);
    expect(source.detailsOpened, 0);

    await tester.tap(
      find.descendant(
        of: find.byType(MediaDetailsSheet),
        matching: find.text('In favorites'),
      ),
    );
    await drain(tester);
    final foreignFavorite = await tester.runAsync(
      () => db.isFavorite(_foreign.id, ContentKind.movie, _foreignMovie.id),
    );
    final localFavorite = await tester.runAsync(
      () => db.isFavorite(_active.id, ContentKind.movie, _localMovie.id),
    );
    expect(foreignFavorite, isFalse);
    expect(localFavorite, isTrue);
    expect(tester.takeException(), isNull);
  });
  for (final kind in [ContentKind.movie, ContentKind.series]) {
    navigationTest('cloud replacement refreshes ${kind.name} favorite state', (
      tester,
    ) async {
      final item = kind == ContentKind.movie ? _localMovie : _series;
      await pumpScreen(tester);
      await tester.tap(tab(kind == ContentKind.movie ? 'Movies' : 'Series'));
      await until(tester, find.text(item.title));
      MediaTabView currentView() => tester.widget<MediaTabView>(
        find.byWidgetPredicate(
          (widget) => widget is MediaTabView && widget.kind == kind,
        ),
      );
      expect(currentView().isFavorite(item.id), isTrue);

      await tester.runAsync(() async {
        await db.clearFavorites(_active.id, kind);
        db.notifyFavoritesReplaced();
      });
      await drain(tester);
      expect(currentView().isFavorite(item.id), isFalse);
      expect(tester.takeException(), isNull);
    });
  }
}
