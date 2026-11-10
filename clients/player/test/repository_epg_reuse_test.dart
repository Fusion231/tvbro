import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/load_token.dart';
import 'package:iptvs/screens/live_controller.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late AppDatabase db;
  late _GatedEpgSource source;
  late LibraryRepository repo;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('iptvs_epg_reuse_test');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
    source = _GatedEpgSource();
    repo = LibraryRepository(source: source, db: db);
  });

  tearDown(() async {
    if (!source.firstGate.isCompleted) source.firstGate.complete();
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('a cached load reuses the guide started during onboarding', () async {
    await repo.load();
    await source.firstStarted.future;
    final firstRefresh = repo.pendingEpgRefresh;

    final snapshot = await repo.load();

    expect(snapshot.fromCache, isTrue);
    expect(repo.pendingEpgRefresh, same(firstRefresh));
    expect(source.tokens, hasLength(1));
    expect(source.tokens.single.isCancelled, isFalse);

    source.firstGate.complete();
    await firstRefresh;
    expect((await repo.nowNext()).now['a']?.title, 'Guide 1');

    // A completed refresh must not remain an active handoff forever.
    await repo.load();
    expect(repo.pendingEpgRefresh, isNull);
    expect(source.tokens, hasLength(1));
  });

  test('a cached guide is refreshed after six hours or on demand', () async {
    source.firstGate.complete();
    await repo.load();
    await repo.pendingEpgRefresh;
    final syncedAt = (await db.lastEpgSynced(source.id))!;
    var now = syncedAt.add(const Duration(hours: 3, minutes: 1));
    final cached = LibraryRepository(source: source, db: db, now: () => now);

    await cached.load();
    expect(cached.pendingEpgRefresh, isNull);
    expect(source.tokens, hasLength(1));

    now = syncedAt.add(const Duration(hours: 6));
    await cached.load();
    expect(cached.pendingEpgRefresh, isNull);
    expect(source.tokens, hasLength(1));

    now = syncedAt.add(const Duration(hours: 6, seconds: 1));
    await cached.load();
    expect(cached.pendingEpgRefresh, isNotNull);
    await cached.pendingEpgRefresh;
    expect(source.tokens, hasLength(2));

    now = (await db.lastEpgSynced(source.id))!;
    await cached.load(forceRefresh: true);
    await cached.pendingEpgRefresh;
    expect(source.tokens, hasLength(3));
  });

  test('returning to TV after a day downloads the expired guide', () async {
    source.at = DateTime.now().subtract(const Duration(hours: 25));
    source.firstGate.complete();
    await repo.load();
    await repo.pendingEpgRefresh;
    var now = (await db.lastEpgSynced(source.id))!;
    repo = LibraryRepository(source: source, db: db, now: () => now);
    final controller = LiveController(repo: repo);
    addTearDown(controller.dispose);
    controller.setEpgRefreshActive(false);
    controller.startEpgRefresh();
    await controller.load();
    expect(controller.now, isEmpty);
    expect(source.tokens, hasLength(1));

    now = now.add(const Duration(hours: 25));
    source.at = null;
    source.secondGate = Completer<void>();
    addTearDown(() {
      if (!source.secondGate!.isCompleted) source.secondGate!.complete();
    });
    final settled = Completer<void>();
    controller.addListener(() {
      if (controller.now['a']?.title == 'Guide 2' &&
          !controller.epgRefreshing &&
          !settled.isCompleted) {
        settled.complete();
      }
    });

    controller.setEpgRefreshActive(true);
    await source.secondStarted.future.timeout(const Duration(seconds: 2));
    expect(controller.loading, isFalse);
    expect(controller.epgRefreshing, isTrue);
    source.secondGate!.complete();
    await settled.future.timeout(const Duration(seconds: 5));
    expect(controller.next['a']?.title, 'Guide 2 next');
    expect(source.tokens, hasLength(2));
  });

  for (final fails in [false, true]) {
    test(
      'a restart after 24 hours shows cached EPG while a ${fails ? 'failed' : 'successful'} refresh downloads',
      () async {
        source.firstGate.complete();
        await repo.load();
        await repo.pendingEpgRefresh;
        final syncedAt = (await db.lastEpgSynced(source.id))!;
        await db.close();

        db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
        source = _GatedEpgSource(guideName: 'Updated', fails: fails);
        repo = LibraryRepository(
          source: source,
          db: db,
          now: () => syncedAt.add(const Duration(hours: 25)),
        );
        final controller = LiveController(repo: repo);
        addTearDown(controller.dispose);
        controller.startEpgRefresh();

        await controller.load().timeout(const Duration(seconds: 5));
        await source.firstStarted.future;
        final refresh = repo.pendingEpgRefresh;
        expect(refresh, isNotNull);
        expect(source.firstGate.isCompleted, isFalse);
        expect(controller.loading, isFalse);
        expect(controller.fromCache, isTrue);
        expect(controller.epgRefreshing, isTrue);
        expect(controller.now['a']?.title, 'Guide 1');
        expect(controller.next['a']?.title, 'Guide 1 next');
        final at = DateTime.now();
        final programmes = await db.programmesForChannel(
          source.id,
          'a',
          from: at,
          to: at.add(const Duration(hours: 2)),
        );
        expect(programmes.map((p) => p.title), ['Guide 1', 'Guide 1 next']);

        final settled = Completer<void>();
        controller.addListener(() {
          if (!controller.epgRefreshing && !settled.isCompleted) {
            settled.complete();
          }
        });
        source.firstGate.complete();
        await refresh;
        await settled.future.timeout(const Duration(seconds: 5));
        expect(controller.now['a']?.title, fails ? 'Guide 1' : 'Updated 1');
        expect(
          controller.next['a']?.title,
          fails ? 'Guide 1 next' : 'Updated 1 next',
        );
        expect(controller.epgUnavailable, isFalse);
        expect(repo.lastEpgRefreshFailed, fails);
        if (fails) expect(await db.lastEpgSynced(source.id), syncedAt);
      },
    );
  }

  test(
    'an explicit refresh supersedes the guide still being downloaded',
    () async {
      await repo.load();
      await source.firstStarted.future;
      final firstRefresh = repo.pendingEpgRefresh;

      await repo.load(forceRefresh: true);
      final replacement = repo.pendingEpgRefresh;

      expect(replacement, isNot(same(firstRefresh)));
      expect(source.tokens.first.isCancelled, isTrue);

      source.firstGate.complete();
      await replacement;

      expect(source.tokens, hasLength(2));
      expect(source.tokens.last.isCancelled, isFalse);
      expect((await repo.nowNext()).now['a']?.title, 'Guide 2');
    },
  );
}

class _GatedEpgSource extends DemoSource implements BatchedEpgSource {
  _GatedEpgSource({this.guideName = 'Guide', this.fails = false})
    : super(sourceId: 'fake');

  final String guideName;
  final bool fails;

  final firstStarted = Completer<void>();
  final firstGate = Completer<void>();
  final secondStarted = Completer<void>();
  Completer<void>? secondGate;
  DateTime? at;
  final tokens = <LoadToken>[];

  @override
  Future<List<Channel>> channels({String? categoryId}) async => const [
    Channel(id: 'a', name: 'A', categoryId: 'test'),
  ];

  @override
  Stream<List<Programme>> epgBatched(
    List<Channel> channels, {
    LoadToken? token,
  }) async* {
    tokens.add(token!);
    final call = tokens.length;
    if (call == 1) {
      firstStarted.complete();
      await firstGate.future;
    } else if (call == 2) {
      secondStarted.complete();
      await secondGate?.future;
    }
    if (token.isCancelled) throw const LoadCancelledException();
    if (fails) throw StateError('Guide unavailable');
    final now = at ?? DateTime.now();
    yield [
      Programme(
        channelId: 'a',
        start: now.subtract(const Duration(minutes: 5)),
        stop: now.add(const Duration(minutes: 55)),
        title: '$guideName $call',
      ),
      Programme(
        channelId: 'a',
        start: now.add(const Duration(minutes: 55)),
        stop: now.add(const Duration(hours: 2)),
        title: '$guideName $call next',
      ),
    ];
  }
}
