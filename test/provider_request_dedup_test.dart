import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/load_token.dart';
import 'package:iptvs/data/net.dart';
import 'package:iptvs/data/source_identity_migration.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/stalker_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppDatabase db;
  late _CountingSource source;
  late LibraryRepository repo;
  late DateTime now;
  const movie = MediaItem(id: 'movie', title: 'Movie', kind: ContentKind.movie);
  const season = MediaItem(
    id: 'season',
    title: 'Season',
    kind: ContentKind.season,
  );

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    ProviderRequestGate.instance.debugReset();
    directory = await Directory.systemTemp.createTemp('request_dedup_');
    db = await AppDatabase.openAt('${directory.path}/library.db');
    source = _CountingSource();
    now = DateTime.now();
    repo = LibraryRepository(source: source, db: db, now: () => now);
    await db.migrateSourceCacheIdentity(
      source.id,
      source.name,
      sourceCacheIdentityForSource(source)!,
    );
    await db.replaceMediaLibrary(source.id, ContentKind.movie, [], [
      movie,
    ], completeCatalog: true);
  });

  tearDown(() async {
    source.release();
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'concurrent details share provider work until persistence completes',
    () async {
      source.hold();
      final reads = [for (var i = 0; i < 8; i++) repo.mediaDetails(movie)];
      await source.started!.future;
      source.release();
      final results = await Future.wait(reads);
      expect(source.details, 1);
      expect(results.every((item) => item.extra['details'] is Map), isTrue);
      await LibraryRepository(source: source, db: db).mediaDetails(movie);
      expect(source.details, 1);
    },
  );

  test('failed shared details do not poison a later explicit retry', () async {
    source.failDetails = true;
    final reads = [
      for (var i = 0; i < 3; i++)
        expectLater(repo.mediaDetails(movie), throwsStateError),
    ];
    await Future.wait(reads);
    expect(source.details, 1);
    source.failDetails = false;
    await repo.mediaDetails(movie);
    expect(source.details, 2);
  });

  test('concurrent season and pagination reads fetch each page once', () async {
    source.hold();
    final opens = [
      for (var i = 0; i < 4; i++)
        repo.loadMedia(ContentKind.episode, parent: season),
    ];
    await source.started!.future;
    source.release();
    await Future.wait(opens);
    expect(source.pages, [1]);

    source.hold();
    final next = [
      for (var i = 0; i < 4; i++)
        repo.loadMoreMedia(ContentKind.episode, parent: season),
    ];
    await source.started!.future;
    source.release();
    final results = await Future.wait(next);
    expect(source.pages, [1, 2]);
    expect(results.every((result) => result.items.length == 2), isTrue);
    await repo.loadMedia(ContentKind.episode, parent: season);
    expect(source.pages, [1, 2]);
  });

  test('cancelled child pagination stops requests and remains retryable', () async {
    await repo.loadMedia(ContentKind.episode, parent: season);
    source.hold();
    final token = LoadToken();
    repo.loadToken = token;
    final pending = repo.loadMoreMedia(ContentKind.episode, parent: season);
    await source.started!.future;
    token.cancel();
    source.release();
    final cancelled = await pending;
    expect(source.pages, [1, 2]);
    expect(cancelled.loadedPages, 1);
    expect(cancelled.items.map((item) => item.id), ['episode-1']);

    await repo.loadMoreMedia(ContentKind.episode, parent: season);
    expect(source.pages, [1, 2], reason: 'an already cancelled read stays local');
    repo.loadToken = null;
    final resumed = await repo.loadMoreMedia(ContentKind.episode, parent: season);
    expect(source.pages, [1, 2, 2]);
    expect(resumed.loadedPages, 2);
    expect(resumed.items, hasLength(2));
  });

  test(
    'simultaneous cold live loads share catalog and background guide',
    () async {
      source.hold();
      final loads = [for (var i = 0; i < 5; i++) repo.load()];
      await source.started!.future;
      source.release();
      await Future.wait(loads);
      await repo.pendingEpgRefresh;
      expect(source.channelsCalls, 1);
      expect(source.epgCalls, 1);
    },
  );

  test(
    'repeated forced catalog refreshes share an active forced operation',
    () async {
      source.hold();
      final loads = [
        for (var i = 0; i < 5; i++)
          repo.synchronizeMediaCatalog(ContentKind.live, forceRefresh: true),
      ];
      await source.started!.future;
      source.release();
      await Future.wait(loads);
      expect(source.channelsCalls, 1);
    },
  );

  test(
    'failed automatic EPG backs off; elapsed time and explicit refresh retry',
    () async {
      source.failEpg = true;
      await repo.load();
      await repo.pendingEpgRefresh;
      expect(repo.lastEpgRefreshFailed, isTrue);
      await repo.load();
      expect(repo.pendingEpgRefresh, isNull);
      expect(source.epgCalls, 1);
      final rebuilt = LibraryRepository(source: source, db: db, now: () => now);
      await rebuilt.load();
      expect(rebuilt.pendingEpgRefresh, isNull);
      expect(source.epgCalls, 1);
      await db.invalidateEpg(source.id);
      await rebuilt.load();
      await rebuilt.pendingEpgRefresh;
      expect(source.epgCalls, 2, reason: 'changed guides bypass the old failure');
      now = now.add(const Duration(minutes: 15));
      await repo.load();
      await repo.pendingEpgRefresh;
      expect(source.epgCalls, 3);
      source.failEpg = false;
      await repo.load(forceRefresh: true);
      await repo.pendingEpgRefresh;
      expect(source.epgCalls, 4);
      expect(repo.lastEpgRefreshFailed, isFalse);
    },
  );

  test('Stalker shares genres with live backfill and caches categories until refresh', () async {
    final calls = <String>[];
    final portal = StalkerSource(
      sourceId: 'portal',
      portal: 'http://provider.invalid',
      mac: '00:00:00:00:00:00',
      diagnostics: false,
      debugApi: (params) async {
        final action = params['action']!;
        calls.add('$action:${params['type']}');
        return {
          'js': switch (action) {
            'get_genres' || 'get_categories' => [
              {'id': '1', 'title': 'Category'},
            ],
            'get_all_channels' => {
              'data': [
                {'id': '1', 'name': 'TV', 'tv_genre_id': '1'},
              ],
            },
            _ => <String, dynamic>{},
          },
        };
      },
    );
    addTearDown(portal.dispose);
    await Future.wait([
      portal.categories(),
      portal.channels(),
      portal.channels(),
    ]);
    await portal.categories();
    await Future.wait([
      portal.mediaCategories(ContentKind.movie),
      portal.mediaCategories(ContentKind.movie),
    ]);
    expect(calls.where((call) => call.startsWith('get_genres')), hasLength(1));
    expect(
      calls.where((call) => call.startsWith('get_all_channels')),
      hasLength(1),
    );
    expect(
      calls.where((call) => call.startsWith('get_categories')),
      hasLength(1),
    );
    portal.invalidate();
    await portal.categories();
    await portal.mediaCategories(ContentKind.movie);
    expect(calls.where((call) => call.startsWith('get_genres')), hasLength(2));
    expect(
      calls.where((call) => call.startsWith('get_categories')),
      hasLength(2),
    );
  });

  test(
    'Stalker exhausted server errors cannot fan out into alternate catalogs',
    () async {
      final calls = <String>[];
      final portal = StalkerSource(
        sourceId: 'portal',
        portal: 'http://provider.invalid',
        mac: '00:00:00:00:00:00',
        diagnostics: false,
        debugApi: (params) async {
          calls.add('${params['type']}:${params['action']}');
          throw StalkerException('HTTP 500 from provider');
        },
      );
      addTearDown(portal.dispose);
      await expectLater(portal.channels(), throwsA(isA<StalkerException>()));
      expect(calls, ['itv:get_all_channels']);
      calls.clear();
      await expectLater(
        portal.mediaCategories(ContentKind.series),
        throwsA(isA<StalkerException>()),
      );
      expect(calls, ['series:get_categories']);
      calls.clear();
      await expectLater(
        portal.mediaItemsPage(ContentKind.series),
        throwsA(isA<StalkerException>()),
      );
      expect(calls, ['series:get_ordered_list']);
    },
  );
}

class _CountingSource extends DemoSource implements RefreshableSource {
  int details = 0;
  int channelsCalls = 0;
  int epgCalls = 0;
  bool failDetails = false;
  bool failEpg = false;
  final pages = <int>[];
  Completer<void>? gate;
  Completer<void>? started;
  void hold() {
    gate = Completer<void>();
    started = Completer<void>();
  }

  void release() {
    if (gate?.isCompleted == false) gate!.complete();
  }

  Future<void> wait() async {
    if (started?.isCompleted == false) started!.complete();
    await gate?.future;
  }

  @override
  void invalidate() {}
  @override
  Future<void> connect() async {}
  @override
  Future<List<Category>> categories() async => [];
  @override
  Future<List<Channel>> channels({String? categoryId}) async {
    channelsCalls++;
    await wait();
    return const [Channel(id: 'one', name: 'One')];
  }

  @override
  Future<List<Programme>> epg(List<Channel> channels) async {
    epgCalls++;
    if (failEpg) throw StateError('offline');
    return [];
  }

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async => [];
  @override
  Future<MediaItem> mediaDetails(MediaItem item) async {
    details++;
    await wait();
    if (failDetails) throw StateError('offline');
    return item.copyWith(
      extra: {...item.extra, 'details': <String, dynamic>{}},
    );
  }

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async {
    pages.add(page);
    await wait();
    return MediaPage(
      items: [
        MediaItem(
          id: 'episode-$page',
          title: '$page',
          kind: kind,
          parentId: parent?.id,
        ),
      ],
      page: page,
      totalPages: 4,
    );
  }
}
