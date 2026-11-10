import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppDatabase db;
  late _CatalogSource source;
  late LibraryRepository repo;
  late DateTime now;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('tvbro_catalog');
    db = await AppDatabase.openAt('${directory.path}/library.db');
    source = _CatalogSource();
    now = DateTime.now();
    repo = LibraryRepository(source: source, db: db, now: () => now);
  });

  tearDown(() async {
    repo.cancelCatalogSync();
    await db.close();
    directory.deleteSync(recursive: true);
  });

  test(
    'full import drains every page and later browsing/search are offline',
    () async {
      await repo.synchronizeCatalog();
      expect(source.pages, [
        'movie:a:1',
        'movie:a:2',
        'movie:b:1',
        'movie:b:2',
        'series:a:1',
        'series:a:2',
        'series:b:1',
        'series:b:2',
      ]);
      source.offline = true;
      final calls = source.connects;
      final movie = await repo.loadMedia(ContentKind.movie);
      final category = await repo.loadMedia(ContentKind.movie, categoryId: 'b');
      final missing = await repo.loadMedia(
        ContentKind.movie,
        categoryId: 'removed',
      );
      final series = await repo.loadMedia(ContentKind.series);
      expect(movie.fromCache, isTrue);
      expect(movie.items, hasLength(4));
      expect(movie.hasMore, isFalse);
      expect(category.items, hasLength(2));
      expect(missing.items, isEmpty);
      expect(series.items, hasLength(4));
      expect(await repo.searchMedia(ContentKind.movie, 'B:2'), hasLength(1));
      expect(
        await repo.loadMoreMedia(ContentKind.movie),
        isA<MediaLibrarySnapshot>(),
      );
      final live = await repo.load();
      await repo.pendingEpgRefresh;
      expect(live.fromCache, isTrue);
      // EPG may authenticate independently, but cached catalog reads do not.
      expect(source.pages, hasLength(8));
      expect(source.connects, inInclusiveRange(calls, calls + 1));
    },
  );

  test('daily refresh is due at 24h and keeps old data until commit', () async {
    await repo.synchronizeCatalog();
    final last = await db.lastCatalogSynced(source.id, ContentKind.movie);
    now = last!.add(const Duration(hours: 23, minutes: 59));
    final calls = source.pages.length;
    await repo.synchronizeCatalog();
    expect(source.pages, hasLength(calls));
    expect(await repo.catalogRefreshDelay(), greaterThan(Duration.zero));

    now = last.add(const Duration(hours: 24, seconds: 1));
    expect(await repo.catalogRefreshDelay(), Duration.zero);
    source.version = 2;
    source.gate = Completer<void>();
    final started = Completer<void>();
    source.started = started;
    final changed = repo.catalogChanged.firstWhere(
      (kind) => kind == ContentKind.movie,
    );
    final refresh = repo.synchronizeCatalog();
    await started.future;
    final during = await repo.loadMedia(ContentKind.movie);
    expect(during.items.first.title, startsWith('v1'));
    expect(during.fromCache, isTrue);
    source.gate!.complete();
    await refresh;
    await changed;
    expect(
      (await repo.loadMedia(ContentKind.movie)).items.first.title,
      startsWith('v2'),
    );
  });

  test(
    'failed daily download preserves the complete old section and timestamp',
    () async {
      await repo.synchronizeCatalog();
      final last = await db.lastCatalogSynced(source.id, ContentKind.movie);
      now = last!.add(const Duration(hours: 25));
      source.failMovies = true;
      source.version = 2;
      await expectLater(repo.synchronizeCatalog(), throwsStateError);
      expect(await db.lastCatalogSynced(source.id, ContentKind.movie), last);
      expect(
        (await repo.loadMedia(ContentKind.movie)).items.first.title,
        startsWith('v1'),
      );
      expect(
        (await repo.loadMedia(ContentKind.series)).items.first.title,
        startsWith('v2'),
      );
    },
  );

  test(
    'manual category refresh replaces full catalog before its daily deadline',
    () async {
      await repo.synchronizeCatalog();
      source.version = 2;
      final calls = source.pages.length;
      final refreshed = await repo.loadMedia(
        ContentKind.movie,
        categoryId: 'b',
        forceRefresh: true,
      );
      expect(refreshed.items, hasLength(2));
      expect(refreshed.items.first.title, startsWith('v2'));
      expect(source.pages.length - calls, 4);
      expect((await repo.loadMedia(ContentKind.movie)).items, hasLength(4));
    },
  );

  test('simultaneous full requests share provider work', () async {
    source.gate = Completer<void>();
    source.started = Completer<void>();
    final first = repo.synchronizeMediaCatalog(ContentKind.movie);
    await source.started!.future;
    final second = repo.synchronizeMediaCatalog(ContentKind.movie);
    source.gate!.complete();
    await Future.wait([first, second]);
    expect(source.pages, hasLength(4));
  });

  test('manual TV refresh waits for an older daily download', () async {
    await repo.synchronizeCatalog();
    final last = await db.lastCatalogSynced(source.id, ContentKind.live);
    now = last!.add(const Duration(hours: 25));
    source.version = 2;
    source.liveGate = Completer<void>();
    source.liveStarted = Completer<void>();
    final daily = repo.synchronizeCatalog();
    await source.liveStarted!.future;
    source.version = 3;
    final manual = repo.load(forceRefresh: true);
    source.liveGate!.complete();
    await Future.wait([daily, manual]);
    await repo.pendingEpgRefresh;
    expect((await repo.load()).channels.single.name, 'TV 3');
    expect(source.channelFetches, 3);
  });

  test(
    'cancelling an in-flight refresh retains data and skips later sections',
    () async {
      await repo.synchronizeCatalog();
      final last = await db.lastCatalogSynced(source.id, ContentKind.movie);
      now = last!.add(const Duration(hours: 25));
      source.version = 2;
      source.gate = Completer<void>();
      source.started = Completer<void>();
      final refresh = repo.synchronizeCatalog();
      await source.started!.future;
      repo.cancelCatalogSync();
      source.gate!.complete();
      await refresh;
      expect(await db.lastCatalogSynced(source.id, ContentKind.movie), last);
      expect(
        (await repo.loadMedia(ContentKind.movie)).items.first.title,
        startsWith('v1'),
      );
    },
  );

  test(
    'successful empty catalogs are not requested again on browse or restart',
    () async {
      source.empty = true;
      await repo.synchronizeCatalog();
      final calls = source.connects;
      source.offline = true;
      repo = LibraryRepository(source: source, db: db);
      expect((await repo.loadMedia(ContentKind.movie)).items, isEmpty);
      expect((await repo.loadMedia(ContentKind.series)).items, isEmpty);
      expect(await repo.searchMedia(ContentKind.movie, 'anything'), isEmpty);
      expect((await repo.load()).channels, isEmpty);
      await repo.pendingEpgRefresh;
      expect(source.connects, inInclusiveRange(calls, calls + 1));
    },
  );
}

class _CatalogSource extends DemoSource implements RefreshableSource {
  _CatalogSource() : super(sourceId: 'catalog-test');
  final pages = <String>[];
  int connects = 0;
  int channelFetches = 0;
  int version = 1;
  bool offline = false;
  bool empty = false;
  bool failMovies = false;
  Completer<void>? gate;
  Completer<void>? started;
  Completer<void>? liveGate;
  Completer<void>? liveStarted;

  @override
  Future<void> connect() async {
    connects++;
    if (offline) throw StateError('offline');
  }

  @override
  void invalidate() {}

  @override
  Future<List<Category>> categories() async => const [];

  @override
  Future<List<Channel>> channels({String? categoryId}) async {
    channelFetches++;
    final fetchedVersion = version;
    if (liveStarted case final signal? when !signal.isCompleted) {
      signal.complete();
    }
    await liveGate?.future;
    return empty ? const [] : [Channel(id: 'tv', name: 'TV $fetchedVersion')];
  }

  @override
  Future<List<Programme>> epg(List<Channel> channels) async => const [];

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async => [
    MediaCategory(id: 'a', title: 'A', kind: kind),
    MediaCategory(id: 'b', title: 'B', kind: kind),
  ];

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async {
    if (offline) throw StateError('offline');
    pages.add('${kind.name}:$categoryId:$page');
    if (started case final signal? when !signal.isCompleted) signal.complete();
    await gate?.future;
    if (failMovies && kind == ContentKind.movie && page == 2) {
      throw StateError('provider failed after first page');
    }
    return MediaPage(
      items: empty
          ? const []
          : [
              MediaItem(
                id: '$categoryId:$page',
                title: 'v$version $categoryId:$page',
                kind: kind,
                categoryId: categoryId,
              ),
            ],
      page: page,
      totalPages: empty ? page : 2,
    );
  }
}
