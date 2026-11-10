import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/load_token.dart';
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
  _GatedEpgSource() : super(sourceId: 'fake');

  final firstStarted = Completer<void>();
  final firstGate = Completer<void>();
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
    }
    if (token.isCancelled) throw const LoadCancelledException();
    final now = DateTime.now();
    yield [
      Programme(
        channelId: 'a',
        start: now.subtract(const Duration(minutes: 5)),
        stop: now.add(const Duration(minutes: 55)),
        title: 'Guide $call',
      ),
    ];
  }
}
