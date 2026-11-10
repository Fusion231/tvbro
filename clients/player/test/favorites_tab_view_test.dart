import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/favorites_tab_view.dart';
import 'package:iptvs/screens/global_favorites_controller.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/theme.dart';

class _SourceStore extends SourceStore {
  _SourceStore(this.configs);

  List<SourceConfig> configs;
  bool fail = false;
  int listCalls = 0;
  Completer<void>? listGate;

  @override
  Future<List<SourceConfig>> list() async {
    listCalls++;
    await listGate?.future;
    if (fail) throw StateError('Source storage unavailable');
    return configs;
  }
}

/// Keeps widget rendering independent of SQLite's real-time worker isolate.
/// The actual-screen navigation tests exercise the persistent database path.
class _FavoritesDatabase implements AppDatabase {
  final _items = <(String, ContentKind), Map<String, MediaItem>>{};
  final _favorites = <(String, ContentKind), Set<String>>{};
  final _changed = StreamController<void>.broadcast(sync: true);
  final _replaced = StreamController<void>.broadcast(sync: true);

  void cacheMedia(String sourceId, ContentKind kind, List<MediaItem> items) {
    _items[(sourceId, kind)] = {for (final item in items) item.id: item};
  }

  @override
  Stream<void> get favoritesChanged => _changed.stream;

  @override
  Stream<void> get favoritesReplaced => _replaced.stream;

  @override
  Future<Set<String>> readFavoriteIds(String sourceId, ContentKind kind) async {
    return {...?_favorites[(sourceId, kind)]};
  }

  @override
  Future<List<MediaItem>> readMediaItemsByIds(
    String sourceId,
    ContentKind kind,
    List<String> ids,
  ) async {
    return [for (final id in ids) ?_items[(sourceId, kind)]?[id]];
  }

  @override
  Future<bool> setFavorite(
    String sourceId,
    ContentKind kind,
    String itemId,
    bool favorite,
  ) async {
    final ids = _favorites.putIfAbsent((sourceId, kind), () => {});
    favorite ? ids.add(itemId) : ids.remove(itemId);
    _changed.add(null);
    return favorite;
  }

  @override
  Future<void> setFavorites(
    String sourceId,
    ContentKind kind,
    Iterable<String> itemIds,
  ) async {
    _favorites.putIfAbsent((sourceId, kind), () => {}).addAll(itemIds);
  }

  @override
  void notifyFavoritesReplaced() => _replaced.add(null);

  @override
  Future<void> close() async {
    await _changed.close();
    await _replaced.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _alpha = SourceConfig(
  id: 'alpha',
  kind: SourceKind.demo,
  label: 'Panel Alpha',
  fields: {},
);
const _beta = SourceConfig(
  id: 'beta',
  kind: SourceKind.demo,
  label: 'Panel Beta',
  fields: {},
);

MediaItem _item(
  String id,
  String title, {
  ContentKind kind = ContentKind.movie,
  String? categoryId,
}) => MediaItem(id: id, title: title, kind: kind, categoryId: categoryId);

Future<({ScrollController scroll, FocusNode first})> _pumpFavorites(
  WidgetTester tester, {
  required _FavoritesDatabase db,
  required _SourceStore store,
  Size size = const Size(1280, 960),
  double textScale = 1,
  List<GlobalFavoriteChannel> channels = const [],
  bool channelsLoading = false,
  bool Function(MediaItem, SourceConfig)? isAllowed,
  ValueChanged<GlobalFavoriteChannel>? onPlayChannel,
  void Function(MediaItem, SourceConfig)? onOpenMedia,
  ValueNotifier<bool>? active,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  final scroll = ScrollController();
  final first = FocusNode();
  final activeState = active ?? ValueNotifier(true);
  if (active == null) addTearDown(activeState.dispose);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    scroll.dispose();
    first.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: Scaffold(
        body: ValueListenableBuilder<bool>(
          valueListenable: activeState,
          builder: (context, isActive, _) => TickerMode(
            enabled: isActive,
            child: FavoritesTabView(
              active: isActive,
              db: db,
              store: store,
              channels: channels,
              channelsLoading: channelsLoading,
              isMediaAllowed: isAllowed ?? (_, _) => true,
              onPlayChannel: onPlayChannel ?? (_) {},
              onOpenMedia: onOpenMedia ?? (_, _) {},
              scrollController: scroll,
              firstFocusNode: first,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (scroll: scroll, first: first);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FavoritesDatabase database;
  late _FavoritesDatabase observed;

  setUp(() {
    database = _FavoritesDatabase();
    observed = database;
  });

  tearDown(() async {
    await database.close();
  });

  Future<void> seed(
    SourceConfig source,
    ContentKind kind,
    List<MediaItem> items, {
    List<String>? favorites,
  }) async {
    database.cacheMedia(source.id, kind, items);
    for (final id in favorites ?? items.map((item) => item.id)) {
      await database.setFavorite(source.id, kind, id, true);
    }
  }

  testWidgets('combines live, movies and series with their owning sources', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await seed(_alpha, ContentKind.movie, [_item('same', 'Alpha movie')]);
      await seed(_beta, ContentKind.movie, [_item('same', 'Beta movie')]);
      await seed(_alpha, ContentKind.series, [
        _item('same', 'Alpha series', kind: ContentKind.series),
      ]);
    });
    const channel = GlobalFavoriteChannel(
      channel: Channel(id: 'same', name: 'Alpha live'),
      config: _alpha,
    );
    final opened = <(String, ContentKind, String)>[];
    final played = <GlobalFavoriteChannel>[];
    final view = await _pumpFavorites(
      tester,
      db: observed,
      store: _SourceStore([_alpha, _beta]),
      channels: [channel],
      onPlayChannel: played.add,
      onOpenMedia: (item, source) =>
          opened.add((source.id, item.kind, item.id)),
    );

    for (final label in ['Live', 'Movies', 'Series']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('Alpha movie'), findsOneWidget);
    expect(find.text('Beta movie'), findsOneWidget);
    expect(find.text('Alpha series'), findsOneWidget);
    expect(find.text('Panel Alpha'), findsWidgets);
    expect(find.text('Panel Beta'), findsWidgets);

    view.first.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(played, [channel]);

    await tester.tap(find.text('Beta movie'));
    await tester.pump();
    await tester.ensureVisible(find.text('Alpha series'));
    await tester.tap(find.text('Alpha series'));
    expect(opened, [
      ('beta', ContentKind.movie, 'same'),
      ('alpha', ContentKind.series, 'same'),
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('finds cached favorites beyond the current catalog page', (
    tester,
  ) async {
    final items = [
      for (var i = 0; i < 95; i++) _item('movie-$i', 'Cached movie $i'),
    ];
    await tester.runAsync(
      () => seed(_alpha, ContentKind.movie, items, favorites: ['movie-94']),
    );
    await _pumpFavorites(tester, db: observed, store: _SourceStore([_alpha]));

    expect(find.text('Cached movie 94'), findsOneWidget);
    expect(find.text('Cached movie 0'), findsNothing);
    expect(find.text('No favorites yet'), findsNothing);
  });

  testWidgets('excludes removed sources, hidden categories and locked media', (
    tester,
  ) async {
    final alpha = _alpha.withHiddenCategories(ContentKind.movie, {'hidden'});
    await tester.runAsync(() async {
      await seed(alpha, ContentKind.movie, [
        _item('visible', 'Visible favorite'),
        _item('hidden', 'Hidden favorite', categoryId: 'hidden'),
        _item('locked', 'Locked favorite'),
      ]);
      await seed(_beta, ContentKind.movie, [
        _item('orphan', 'Removed source favorite'),
      ]);
    });
    final checked = <(String, String)>[];
    await _pumpFavorites(
      tester,
      db: observed,
      store: _SourceStore([alpha]),
      isAllowed: (item, config) {
        checked.add((config.id, item.id));
        return item.id != 'locked';
      },
    );

    expect(find.text('Visible favorite'), findsOneWidget);
    expect(find.text('Hidden favorite'), findsNothing);
    expect(find.text('Locked favorite'), findsNothing);
    expect(find.text('Removed source favorite'), findsNothing);
    expect(checked, containsAll([('alpha', 'visible'), ('alpha', 'locked')]));
    expect(checked.every((entry) => entry.$1 == 'alpha'), isTrue);
  });

  testWidgets('shows an empty state when no configured source has favorites', (
    tester,
  ) async {
    await _pumpFavorites(tester, db: observed, store: _SourceStore([_alpha]));

    expect(find.text('No favorites yet'), findsOneWidget);
    expect(find.text('Movies'), findsNothing);
    expect(find.text('Series'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('updates after local removal and cloud replacement', (
    tester,
  ) async {
    await tester.runAsync(
      () => seed(
        _alpha,
        ContentKind.movie,
        [
          _item('first', 'Original favorite'),
          _item('second', 'Cloud favorite'),
        ],
        favorites: ['first'],
      ),
    );
    final store = _SourceStore([_alpha]);
    await _pumpFavorites(tester, db: observed, store: store);
    expect(find.text('Original favorite'), findsOneWidget);

    await tester.runAsync(() async {
      await database.setFavorite('alpha', ContentKind.movie, 'first', false);
    });
    await tester.pumpAndSettle();
    expect(find.text('Original favorite'), findsNothing);
    expect(find.text('No favorites yet'), findsOneWidget);

    await tester.runAsync(() async {
      await database.setFavorites('alpha', ContentKind.movie, ['second']);
      database.notifyFavoritesReplaced();
    });
    await tester.pumpAndSettle();
    expect(find.text('Cloud favorite'), findsOneWidget);
    expect(find.text('No favorites yet'), findsNothing);
  });

  testWidgets(
    'hidden favorites defer reads and visible bursts share one follow-up',
    (tester) async {
      final active = ValueNotifier(false);
      addTearDown(active.dispose);
      final store = _SourceStore([_alpha]);
      await _pumpFavorites(tester, db: observed, store: store, active: active);
      expect(store.listCalls, 0);

      database.notifyFavoritesReplaced();
      database.notifyFavoritesReplaced();
      await tester.pump();
      expect(store.listCalls, 0);
      active.value = true;
      await tester.pumpAndSettle();
      expect(store.listCalls, 1);

      active.value = false;
      await tester.pump();
      database.notifyFavoritesReplaced();
      database.notifyFavoritesReplaced();
      await tester.pump();
      expect(store.listCalls, 1);
      active.value = true;
      await tester.pumpAndSettle();
      expect(store.listCalls, 2);

      final gate = Completer<void>();
      store.listGate = gate;
      database.notifyFavoritesReplaced();
      await tester.pump();
      expect(store.listCalls, 3);
      database.notifyFavoritesReplaced();
      database.notifyFavoritesReplaced();
      database.notifyFavoritesReplaced();
      await tester.pump();
      expect(store.listCalls, 3);
      store.listGate = null;
      gate.complete();
      await tester.pumpAndSettle();
      expect(store.listCalls, 4);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('retries a source-storage failure', (tester) async {
    await tester.runAsync(
      () =>
          seed(_alpha, ContentKind.movie, [_item('movie', 'Recovered movie')]),
    );
    final store = _SourceStore([_alpha])..fail = true;
    await _pumpFavorites(tester, db: observed, store: store);

    expect(find.text('Could not load favorites.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    store.fail = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text('Recovered movie'), findsOneWidget);
    expect(find.text('Could not load favorites.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(960, 540), const Size(380, 780)]) {
    testWidgets('fits long titles at enlarged text on ${size.width} wide', (
      tester,
    ) async {
      const title =
          'An exceptionally long movie title with a subtitle and several '
          'additional words to cover a small television or phone display';
      await tester.runAsync(
        () => seed(_alpha, ContentKind.movie, [_item('long', title)]),
      );
      final opened = <String>[];
      final view = await _pumpFavorites(
        tester,
        db: observed,
        store: _SourceStore([_alpha]),
        size: size,
        textScale: 1.6,
        onOpenMedia: (item, source) => opened.add('${source.id}/${item.id}'),
      );

      expect(find.text(title), findsOneWidget);
      view.first.requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(opened, ['alpha/long']);
      expect(tester.takeException(), isNull);
    });
  }
}
