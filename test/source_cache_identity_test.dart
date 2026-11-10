import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/load_token.dart';
import 'package:iptvs/data/source_identity_migration.dart';
import 'package:iptvs/sources/m3u_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/sources/xtream_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppDatabase db;
  final sources = <Source>[];
  String databasePath() => '${directory.path}/library.db';

  Future<void> openDatabase() async {
    db = await AppDatabase.openAt(databasePath());
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('tvbro_cache_identity');
    sources.clear();
    await openDatabase();
  });

  tearDown(() async {
    for (final source in sources) {
      await source.dispose();
    }
    await db.close();
    directory.deleteSync(recursive: true);
  });

  test('M3U to Xtream keeps the source ID and refreshes its catalog', () async {
    const sourceId = 'same-source-id';
    final m3uConfig = _m3uConfig(sourceId);
    await migrateSourceIdentity(db, m3uConfig);
    final m3u = _SyntheticM3u(
      sourceId: sourceId,
      playlistUrl: m3uConfig.fields['playlistUrl']!,
      channelId: 'm3u-channel:synthetic-old',
    );
    sources.add(m3u);
    final oldRepository = LibraryRepository(source: m3u, db: db);
    final oldSnapshot = await oldRepository.load();
    await oldRepository.pendingEpgRefresh;
    expect(oldSnapshot.channels.single.id, 'm3u-channel:synthetic-old');

    await db.setFavorite(
      sourceId,
      ContentKind.live,
      'm3u-channel:synthetic-old',
      true,
    );
    await db.savePlaybackPosition(
      sourceId,
      ContentKind.movie,
      'synthetic-history',
      position: const Duration(seconds: 20),
      duration: const Duration(minutes: 2),
    );
    final xtreamConfig = _xtreamConfig(sourceId);
    await migrateSourceIdentity(db, xtreamConfig);
    final xtream = _SyntheticXtream(
      sourceId: sourceId,
      host: xtreamConfig.fields['host']!,
      username: xtreamConfig.fields['username']!,
      password: xtreamConfig.fields['password']!,
      channelId: 'xtream-channel:synthetic-new',
    );
    sources.add(xtream);

    final current = await LibraryRepository(source: xtream, db: db).load();
    await LibraryRepository(source: xtream, db: db).pendingEpgRefresh;
    expect(current.fromCache, isFalse);
    expect(current.channels.single.id, 'xtream-channel:synthetic-new');
    expect(await db.readFavoriteIds(sourceId, ContentKind.live), {
      'm3u-channel:synthetic-old',
    });
    expect(
      (await db.readPlaybackPosition(
        sourceId,
        ContentKind.movie,
        'synthetic-history',
      ))?.position,
      const Duration(seconds: 20),
    );
  });

  test(
    'same-kind endpoint/account edits replace the old cached catalog',
    () async {
      const sourceId = 'same-kind-source';
      final first = _xtreamConfig(sourceId, host: 'https://first.invalid');
      await migrateSourceIdentity(db, first);
      final original = _SyntheticXtream(
        sourceId: sourceId,
        host: first.fields['host']!,
        username: first.fields['username']!,
        password: first.fields['password']!,
        channelId: 'channel-from-first-account',
      );
      sources.add(original);
      await LibraryRepository(source: original, db: db).load();
      final reusedMediaId = MediaItem(
        id: 'reused-provider-id',
        title: 'Old account movie',
        kind: ContentKind.movie,
      );
      await db.cacheExternalMetadata(
        sourceId,
        reusedMediaId,
        ExternalMetadata(
          provider: 'tmdb',
          providerKey: 'old-account-match',
          title: 'Old account metadata',
          refreshedAt: DateTime.now(),
        ),
      );

      final edited = _xtreamConfig(
        sourceId,
        host: 'https://second.invalid',
        username: 'fixture-user-b',
      );
      await migrateSourceIdentity(db, edited);
      expect(
        await db.readExternalMetadata(sourceId, reusedMediaId, 'tmdb'),
        isNull,
      );
      final oldIdentity = sourceCacheIdentityForConfig(first);
      await expectLater(
        db.cacheExternalMetadata(
          sourceId,
          reusedMediaId,
          ExternalMetadata(
            provider: 'tmdb',
            providerKey: 'late-old-account-match',
            refreshedAt: DateTime.now(),
          ),
          expectedCacheIdentity: oldIdentity,
        ),
        throwsA(isA<LoadCancelledException>()),
      );
      await expectLater(
        db.updateMediaDisplayFields(
          sourceId,
          [reusedMediaId.copyWith(title: 'Late old account metadata')],
          expectedCacheIdentity: oldIdentity,
        ),
        throwsA(isA<LoadCancelledException>()),
      );
      final replacement = _SyntheticXtream(
        sourceId: sourceId,
        host: edited.fields['host']!,
        username: edited.fields['username']!,
        password: edited.fields['password']!,
        channelId: 'channel-from-second-account',
      );
      sources.add(replacement);

      final snapshot = await LibraryRepository(
        source: replacement,
        db: db,
      ).load();
      expect(snapshot.fromCache, isFalse);
      expect(snapshot.channels.single.id, 'channel-from-second-account');
    },
  );

  test('label-only edits continue to use cache without connecting', () async {
    const sourceId = 'renamed-source';
    final original = _m3uConfig(sourceId, label: 'Before rename');
    await migrateSourceIdentity(db, original);
    final firstSource = _SyntheticM3u(
      sourceId: sourceId,
      playlistUrl: original.fields['playlistUrl']!,
      channelId: 'm3u-channel:label-stable',
    );
    sources.add(firstSource);
    await LibraryRepository(source: firstSource, db: db).load();

    final renamed = _m3uConfig(sourceId, label: 'After rename');
    await migrateSourceIdentity(db, renamed);
    final offline = _SyntheticM3u(
      sourceId: sourceId,
      playlistUrl: renamed.fields['playlistUrl']!,
      channelId: 'm3u-channel:label-stable',
      failConnect: true,
      displayName: renamed.label,
    );
    sources.add(offline);

    final snapshot = await LibraryRepository(source: offline, db: db).load();
    expect(snapshot.fromCache, isTrue);
    expect(snapshot.channels.single.id, 'm3u-channel:label-stable');
    expect(offline.connects, 0);
  });

  test(
    'unknown old cache identity refreshes once and preserves user state',
    () async {
      const sourceId = 'legacy-cache-source';
      await db.replaceLibrary(
        sourceId,
        'Old label',
        const [Category(id: 'old-category', title: 'Old')],
        const [Channel(id: 'm3u-channel:legacy', name: 'Legacy channel')],
        completeCatalog: true,
      );
      await db.replaceMediaLibrary(
        sourceId,
        ContentKind.movie,
        const [
          MediaCategory(
            id: 'old-movies',
            title: 'Old movies',
            kind: ContentKind.movie,
          ),
        ],
        const [
          MediaItem(
            id: 'legacy-movie',
            title: 'Old movie',
            kind: ContentKind.movie,
          ),
        ],
        completeCatalog: true,
      );
      await db.setFavorite(
        sourceId,
        ContentKind.live,
        'm3u-channel:legacy',
        true,
      );
      await db.savePlaybackPosition(
        sourceId,
        ContentKind.movie,
        'legacy-movie',
        position: const Duration(seconds: 30),
        duration: const Duration(minutes: 2),
      );

      final config = _m3uConfig(sourceId);
      final refreshedSource = _SyntheticM3u(
        sourceId: sourceId,
        playlistUrl: config.fields['playlistUrl']!,
        channelId: 'm3u-channel:current',
      );
      sources.add(refreshedSource);
      final refreshedRepository = LibraryRepository(
        source: refreshedSource,
        db: db,
      );
      final refreshed = await refreshedRepository.load();
      await refreshedRepository.pendingEpgRefresh;

      expect(refreshed.fromCache, isFalse);
      expect(refreshed.channels.single.id, 'm3u-channel:current');
      expect(await db.readFavoriteIds(sourceId, ContentKind.live), {
        'm3u-channel:legacy',
      });
      expect(
        (await db.readPlaybackPosition(
          sourceId,
          ContentKind.movie,
          'legacy-movie',
        ))?.position,
        const Duration(seconds: 30),
      );

      await migrateSourceIdentity(db, config);
      final offlineSource = _SyntheticM3u(
        sourceId: sourceId,
        playlistUrl: config.fields['playlistUrl']!,
        channelId: 'm3u-channel:current',
        failConnect: true,
      );
      sources.add(offlineSource);
      final current = await LibraryRepository(
        source: offlineSource,
        db: db,
      ).load();
      expect(current.fromCache, isTrue);
      expect(offlineSource.connects, 0);
    },
  );

  test(
    'failed replacement and restart never serve the previous account rows',
    () async {
      const sourceId = 'failed-replacement-source';
      final first = _m3uConfig(sourceId, url: 'https://one.invalid/list.m3u');
      await migrateSourceIdentity(db, first);
      final original = _SyntheticM3u(
        sourceId: sourceId,
        playlistUrl: first.fields['playlistUrl']!,
        channelId: 'm3u-channel:previous-account',
      );
      sources.add(original);
      await LibraryRepository(source: original, db: db).load();
      await db.setFavorite(
        sourceId,
        ContentKind.live,
        'm3u-channel:previous-account',
        true,
      );
      await db.savePlaybackPosition(
        sourceId,
        ContentKind.movie,
        'synthetic-history',
        position: const Duration(seconds: 25),
        duration: const Duration(minutes: 2),
      );

      final edited = _m3uConfig(sourceId, url: 'https://two.invalid/list.m3u');
      await migrateSourceIdentity(db, edited);
      final offline = _SyntheticM3u(
        sourceId: sourceId,
        playlistUrl: edited.fields['playlistUrl']!,
        channelId: 'm3u-channel:replacement-account',
        failConnect: true,
      );
      sources.add(offline);
      await expectLater(
        LibraryRepository(source: offline, db: db).load(),
        throwsStateError,
      );
      expect(await db.readChannels(sourceId), isEmpty);
      expect(await db.lastSynced(sourceId), isNull);

      await db.close();
      await openDatabase();
      await migrateSourceIdentity(db, edited);
      expect(await db.readChannels(sourceId), isEmpty);
      expect(await db.lastSynced(sourceId), isNull);
      expect(await db.readFavoriteIds(sourceId, ContentKind.live), {
        'm3u-channel:previous-account',
      });
      expect(
        (await db.readPlaybackPosition(
          sourceId,
          ContentKind.movie,
          'synthetic-history',
        ))?.position,
        const Duration(seconds: 25),
      );
      await expectLater(
        LibraryRepository(source: offline, db: db).load(),
        throwsStateError,
      );
      expect(await db.readChannels(sourceId), isEmpty);
    },
  );

  test(
    'cancelled old request cannot seed rows after identity changes',
    () async {
      const sourceId = 'stale-writer-source';
      final first = _m3uConfig(sourceId, url: 'https://old.invalid/list.m3u');
      final started = Completer<void>();
      final release = Completer<void>();
      final oldSource = _SyntheticM3u(
        sourceId: sourceId,
        playlistUrl: first.fields['playlistUrl']!,
        channelId: 'm3u-channel:old-inflight',
        channelsStarted: started,
        releaseChannels: release,
      );
      sources.add(oldSource);
      final oldRepo = LibraryRepository(source: oldSource, db: db);
      final token = LoadToken();
      oldRepo.loadToken = token;
      final oldLoad = oldRepo.load();
      await started.future;
      expect(
        await db.sourceCacheIdentityMatches(
          sourceId,
          sourceCacheIdentityForConfig(first),
        ),
        isTrue,
      );

      await migrateSourceIdentity(
        db,
        _m3uConfig(sourceId, url: 'https://new.invalid/list.m3u'),
      );
      token.cancel();
      release.complete();
      await expectLater(oldLoad, throwsA(isA<LoadCancelledException>()));

      expect(await db.readChannels(sourceId), isEmpty);
      expect(await db.lastSynced(sourceId), isNull);
    },
  );

  test('late lazy bind cannot replace a newer identity or its catalog', () async {
    const sourceId = 'competing-lazy-bind-source';
    final oldConfig = _m3uConfig(
      sourceId,
      url: 'https://old-account.invalid/list.m3u',
    );
    final currentConfig = _xtreamConfig(
      sourceId,
      host: 'https://current-account.invalid',
    );

    // This is the observation made by the old repository before its delayed
    // lazy-bind transaction gets a turn on the database connection.
    expect(await db.sourceCacheIdentity(sourceId), isNull);
    await migrateSourceIdentity(db, currentConfig);
    await db.replaceLibrary(
      sourceId,
      currentConfig.label,
      const [Category(id: 'current-category', title: 'Current account')],
      const [Channel(id: 'current-channel', name: 'Current channel')],
      completeCatalog: true,
      expectedCacheIdentity: sourceCacheIdentityForConfig(currentConfig),
    );

    // The old repository's delayed lazy bind must refuse to claim B's known
    // identity after its earlier null observation.
    expect(
      await db.migrateSourceCacheIdentity(
        sourceId,
        oldConfig.label,
        sourceCacheIdentityForConfig(oldConfig),
        onlyIfUnknown: true,
      ),
      isFalse,
    );

    expect(
      await db.sourceCacheIdentity(sourceId),
      sourceCacheIdentityForConfig(currentConfig),
    );
    expect(
      (await db.readChannels(sourceId)).map((channel) => channel.id),
      ['current-channel'],
    );
  });

  test(
    'old guide ingestion cannot repopulate after source identity changes',
    () async {
      const sourceId = 'stale-guide-source';
      final first = _m3uConfig(sourceId);
      await migrateSourceIdentity(db, first);
      final started = Completer<void>();
      final release = Completer<void>();
      final now = DateTime.now();
      final oldSource = _SyntheticM3u(
        sourceId: sourceId,
        playlistUrl: first.fields['playlistUrl']!,
        channelId: 'm3u-channel:old-guide',
        epgStarted: started,
        releaseEpg: release,
        epgProgrammes: [
          Programme(
            channelId: 'm3u-channel:old-guide',
            start: now.subtract(const Duration(minutes: 1)),
            stop: now.add(const Duration(hours: 1)),
            title: 'Old account guide',
          ),
        ],
      );
      sources.add(oldSource);
      final repository = LibraryRepository(source: oldSource, db: db);
      await repository.load();
      await started.future;

      await migrateSourceIdentity(db, _xtreamConfig(sourceId));
      release.complete();
      await repository.pendingEpgRefresh;

      expect(
        await db.programmesForChannel(
          sourceId,
          'm3u-channel:old-guide',
          from: now.subtract(const Duration(days: 1)),
          to: now.add(const Duration(days: 1)),
        ),
        isEmpty,
      );
    },
  );
}

SourceConfig _m3uConfig(
  String id, {
  String label = 'Synthetic M3U',
  String url = 'https://fixture.invalid/list.m3u',
}) => SourceConfig(
  id: id,
  kind: SourceKind.m3u,
  label: label,
  fields: {'playlistUrl': url},
);

SourceConfig _xtreamConfig(
  String id, {
  String host = 'https://fixture.invalid',
  String username = 'fixture-user-a',
  String password = 'fixture-password-a',
}) => SourceConfig(
  id: id,
  kind: SourceKind.xtream,
  label: 'Synthetic Xtream',
  fields: {'host': host, 'username': username, 'password': password},
);

class _SyntheticM3u extends M3uSource {
  _SyntheticM3u({
    required super.sourceId,
    required super.playlistUrl,
    required this.channelId,
    this.failConnect = false,
    this.channelsStarted,
    this.releaseChannels,
    this.epgStarted,
    this.releaseEpg,
    this.epgProgrammes = const [],
    super.displayName,
  });

  final String channelId;
  final bool failConnect;
  final Completer<void>? channelsStarted;
  final Completer<void>? releaseChannels;
  final Completer<void>? epgStarted;
  final Completer<void>? releaseEpg;
  final List<Programme> epgProgrammes;
  int connects = 0;

  @override
  Future<void> connect() async {
    connects++;
    if (failConnect) throw StateError('synthetic offline');
  }

  @override
  Future<void> prepareCatalog(
    Object refreshKey, {
    required bool refresh,
  }) async {}

  @override
  Future<List<Category>> categories() async => const [
    Category(id: 'synthetic-category', title: 'Synthetic'),
  ];

  @override
  Future<List<Channel>> channels({String? categoryId}) async {
    if (channelsStarted case final started? when !started.isCompleted) {
      started.complete();
    }
    await releaseChannels?.future;
    return [Channel(id: channelId, name: 'Synthetic channel')];
  }

  @override
  Stream<List<Programme>>? epgBatched(
    List<Channel> channels, {
    LoadToken? token,
  }) => null;

  @override
  Future<List<Programme>> epg(List<Channel> channels) async {
    if (epgStarted case final started? when !started.isCompleted) {
      started.complete();
    }
    await releaseEpg?.future;
    return epgProgrammes;
  }
}

class _SyntheticXtream extends XtreamSource {
  _SyntheticXtream({
    required super.sourceId,
    required super.host,
    required super.username,
    required super.password,
    required this.channelId,
  });

  final String channelId;
  int connects = 0;

  @override
  Future<void> connect() async {
    connects++;
  }

  @override
  Future<List<Category>> categories() async => const [
    Category(id: 'synthetic-category', title: 'Synthetic'),
  ];

  @override
  Future<List<Channel>> channels({String? categoryId}) async => [
    Channel(id: channelId, name: 'Synthetic channel'),
  ];

  @override
  Future<List<Programme>> epg(List<Channel> channels) async => const [];
}
