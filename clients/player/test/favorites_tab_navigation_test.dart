import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/source_store.dart';
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
const _unsavedMovie = MediaItem(
  id: 'unsaved',
  title: 'Other saved-looking movie',
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

class _OfflineForeignSource extends _NavigationSource {
  int connections = 0;

  @override
  String get id => _foreign.id;

  @override
  String get name => _foreign.label;

  @override
  Future<void> connect() async {
    connections++;
    throw StateError('The provider is offline');
  }
}

class _ForeignConfig extends SourceConfig {
  final Source source;

  _ForeignConfig(this.source)
    : super(
        id: _foreign.id,
        kind: SourceKind.demo,
        label: _foreign.label,
        fields: const {},
      );

  @override
  Source build() => source;
}

class _ForeignStore extends SourceStore {
  final SourceConfig foreign;

  _ForeignStore(this.foreign);

  @override
  Future<List<SourceConfig>> list() async => [_active, foreign];
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
      const [_foreignMovie, _unsavedMovie],
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

  Future<void> openSection(WidgetTester tester, String title) async {
    if (find.byTooltip('Home').evaluate().isNotEmpty) {
      await tester.tap(find.byTooltip('Home'));
      await tester.pump();
    }
    await tester.tap(
      title == 'Favorites'
          ? find.byKey(const ValueKey('home-favorites'))
          : find.text(title),
    );
    await tester.pump();
  }

  Finder favoriteText(String title) => find.descendant(
    of: find.byType(FavoritesTabView),
    matching: find.text(title),
  );

  Future<void> pumpScreen(WidgetTester tester, {bool openLive = true}) async {
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
    if (openLive) {
      await openSection(tester, 'TV');
      await until(tester, find.text('Channel groups'));
    }
  }

  void navigationTest(
    String description,
    WidgetTesterCallback callback, {
    bool requiresMediaKit = true,
  }) {
    testWidgets(description, (tester) async {
      if (requiresMediaKit && !mediaKitAvailable) {
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

  navigationTest('Favorites returns through Home to the Series catalogue', (
    tester,
  ) async {
    await pumpScreen(tester);
    await openSection(tester, 'Series');
    await until(tester, find.text(_series.title));
    await openSection(tester, 'Favorites');
    await until(tester, favoriteText(_foreignMovie.title));
    expect(favoriteText('Local saved channel'), findsOneWidget);
    expect(favoriteText('Other saved channel'), findsOneWidget);

    await tester.tap(find.byTooltip('Home'));
    await tester.pump();
    expect(
      focusRouteKey(FocusManager.instance.primaryFocus),
      'content.tab.favorites',
    );
    expect(find.byTooltip('Favorites'), findsNothing);
    await openSection(tester, 'Series');
    await tester.pump();
    expect(find.byType(FavoritesTabView), findsNothing);
    expect(find.text(_series.title), findsWidgets);
    expect(
      tester.widget<MediaTabView>(find.byType(MediaTabView)).kind,
      ContentKind.series,
    );
    expect(tester.takeException(), isNull);
  });

  navigationTest('Favorites Back and search return focus to Home', (
    tester,
  ) async {
    await pumpScreen(tester);
    await openSection(tester, 'Favorites');
    await until(tester, favoriteText(_foreignMovie.title));
    FocusManager.instance.rootScope.descendants
        .firstWhere((node) => focusRouteKey(node) == 'library.home')
        .requestFocus();
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
      'library.home',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      focusRouteKey(FocusManager.instance.primaryFocus),
      'live.search.cell',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(focusRouteKey(FocusManager.instance.primaryFocus), 'library.home');

    await tester.tap(find.byType(TvTextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'unmatched');
    await tester.pump();
    expect(find.byType(FavoritesTabView), findsOneWidget);
    await until(tester, favoriteText('No favorites found'));
    expect(favoriteText('No favorites found'), findsOneWidget);
    expect(find.byType(GlobalSearchView), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(
      focusRouteKey(FocusManager.instance.primaryFocus),
      'TvTextField.field',
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();
    await until(tester, favoriteText(_foreignMovie.title));
    expect(find.byType(GlobalSearchView), findsNothing);
    expect(focusRouteKey(FocusManager.instance.primaryFocus), 'library.home');
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byKey(const ValueKey('home-favorites')), findsOneWidget);
    expect(
      focusRouteKey(FocusManager.instance.primaryFocus),
      'content.tab.favorites',
    );
    expect(tester.takeException(), isNull);
  });

  navigationTest('Favorites search only matches saved items across sources', (
    tester,
  ) async {
    await pumpScreen(tester);
    await openSection(tester, 'Favorites');
    await until(tester, favoriteText(_foreignMovie.title));
    await tester.tap(find.byType(TvTextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '  oThEr SaVeD  ');
    await tester.pump();

    expect(find.byType(GlobalSearchView), findsNothing);
    expect(
      tester.widget<FavoritesTabView>(find.byType(FavoritesTabView)).query.trim(),
      'oThEr SaVeD',
    );
    await until(tester, favoriteText('Other saved channel'));
    expect(favoriteText('Other saved channel'), findsOneWidget);
    expect(favoriteText(_foreignMovie.title), findsOneWidget);
    expect(favoriteText('Local saved channel'), findsNothing);
    expect(favoriteText(_localMovie.title), findsNothing);
    expect(favoriteText(_unsavedMovie.title), findsNothing);
    expect(favoriteText(_series.title), findsNothing);

    await tester.enterText(find.byType(TextField), 'catalogue');
    await tester.pump();
    await until(tester, favoriteText(_series.title));
    expect(favoriteText(_series.title), findsOneWidget);
    expect(favoriteText(_foreignMovie.title), findsNothing);
    expect(favoriteText('Other saved channel'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  navigationTest('foreign movie details and unfavorite use its owning source', (
    tester,
  ) async {
    await pumpScreen(tester);
    await openSection(tester, 'Favorites');
    await until(tester, favoriteText(_foreignMovie.title));
    await tester.tap(find.byType(TvTextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Other saved movie');
    await tester.pump();
    expect(favoriteText(_localMovie.title), findsNothing);
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

  navigationTest(
    'cached foreign favorite details open without contacting an offline provider',
    (tester) async {
      final foreign = _OfflineForeignSource();
      store = _ForeignStore(_ForeignConfig(foreign));
      await tester.runAsync(
        () => db.updateMediaDisplayFields(_foreign.id, [
          _foreignMovie.copyWith(
            extra: const {
              'details': {'plot': 'Saved provider details'},
            },
          ),
        ]),
      );
      await pumpScreen(tester, openLive: false);
      await openSection(tester, 'Favorites');
      await until(tester, favoriteText(_foreignMovie.title));
      await tester.tap(find.byType(TvTextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), _foreignMovie.title);
      await tester.pump();
      await tester.ensureVisible(favoriteText(_foreignMovie.title));
      await tester.pump();
      await tester.tap(favoriteText(_foreignMovie.title));
      await until(tester, find.byType(MediaDetailsSheet));

      final details = tester.widget<MediaDetailsSheet>(
        find.byType(MediaDetailsSheet),
      );
      expect(details.repo.source.id, _foreign.id);
      expect(details.item.extra['details'], {'plot': 'Saved provider details'});
      expect(foreign.connections, 0);
      expect(foreign.detailsOpened, 0);
      expect(source.detailsOpened, 0);
      expect(tester.takeException(), isNull);
    },
    requiresMediaKit: false,
  );

  for (final kind in [ContentKind.movie, ContentKind.series]) {
    navigationTest('cloud replacement refreshes ${kind.name} favorite state', (
      tester,
    ) async {
      final item = kind == ContentKind.movie ? _localMovie : _series;
      await pumpScreen(tester);
      await openSection(tester, kind == ContentKind.movie ? 'Movies' : 'Series');
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
