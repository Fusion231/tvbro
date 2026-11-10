// Unit tests for LiveController's async generation guards: a monotonic
// counter so a slow/stale load() or refreshNowNext() can never clobber a
// newer one's result, and dispose() never triggers a post-dispose
// notification (ChangeNotifier asserts on that).

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/screens/live_controller.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

/// A repository whose `load`/`nowNext` are driven by test-controlled
/// completers, so interleaving between two overlapping calls is
/// deterministic instead of racing on real I/O.
class _GatedRepo extends LibraryRepository {
  _GatedRepo({required super.source, required super.db});

  final List<Completer<LibrarySnapshot>> loadCompleters = [];
  final List<
    Completer<({Map<String, Programme> now, Map<String, Programme> next})>
  >
  nowNextCompleters = [];
  final nowNextChannelIds = <List<String>?>[];
  bool throwSynchronously = false;

  @override
  Future<LibrarySnapshot> load({bool forceRefresh = false}) {
    final completer = Completer<LibrarySnapshot>();
    loadCompleters.add(completer);
    return completer.future;
  }

  @override
  Future<({Map<String, Programme> now, Map<String, Programme> next})> nowNext({
    List<String>? channelIds,
  }) {
    nowNextChannelIds.add(channelIds == null ? null : [...channelIds]);
    if (throwSynchronously) throw StateError('storage unavailable');
    final completer =
        Completer<
          ({Map<String, Programme> now, Map<String, Programme> next})
        >();
    nowNextCompleters.add(completer);
    return completer.future;
  }
}

/// A repository whose *guide* refresh the test drives, rather than its load.
///
/// `load` returns immediately — these tests are about what the controller does
/// with the refresh running behind the returned snapshot, which is the whole
/// shape of the change: the channel list is on screen and the guide is not.
class _EpgRepo extends LibraryRepository {
  _EpgRepo({required super.source, required super.db});

  final Completer<void> guide = Completer<void>();
  bool failed = false;
  ({Map<String, Programme> now, Map<String, Programme> next}) guideRows = (
    now: const <String, Programme>{},
    next: const <String, Programme>{},
  );

  @override
  Future<void>? get pendingEpgRefresh => guide.future;

  @override
  bool get lastEpgRefreshFailed => failed;

  @override
  Future<LibrarySnapshot> load({bool forceRefresh = false}) async =>
      _snapshot('loaded');

  @override
  Future<({Map<String, Programme> now, Map<String, Programme> next})> nowNext({
    List<String>? channelIds,
  }) async => guideRows;
}

/// A source that will not say whether it carries a guide — the
/// M3U-without-an-EPG-URL case, which reports `unknown`.
class _UnknownCapabilitySource extends DemoSource {
  @override
  SourceCapabilities get sourceCapabilities => const SourceCapabilities(
    epg: CapabilityAvailability.unknown,
    catchup: CapabilityAvailability.unknown,
    resolution: ResolutionCapability.unknown,
  );
}

class _NamedSource extends DemoSource {
  _NamedSource(String sourceId) : super(sourceId: sourceId);
}

LibrarySnapshot _snapshot(String marker) => LibrarySnapshot(
  categories: const [],
  channels: [Channel(id: marker, name: marker)],
  fromCache: false,
  syncedAt: DateTime(2024),
);

({Map<String, Programme> now, Map<String, Programme> next}) _nowNext(
  String marker,
) => (
  now: {
    marker: Programme(
      channelId: marker,
      start: DateTime(2024),
      stop: DateTime(2024, 1, 1, 1),
      title: marker,
    ),
  },
  next: <String, Programme>{},
);

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late _GatedRepo repo;
  late LiveController controller;
  var controllerDisposed = false;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('iptvs_live_controller_test');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
    repo = _GatedRepo(source: DemoSource(), db: db);
    controller = LiveController(repo: repo);
    controllerDisposed = false;
  });

  tearDown(() async {
    if (!controllerDisposed) controller.dispose();
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('newer load wins over a late-completing stale load', () async {
    final first = controller.load(); // generation 1
    final second = controller.load(forceRefresh: true); // generation 2

    expect(repo.loadCompleters.length, 2);

    // Complete generation 2 first, then let generation 1 resolve late.
    repo.loadCompleters[1].complete(_snapshot('gen2'));
    // load() awaits its own refreshNowNext() internally, so give it a gated
    // now/next completer to resolve before awaiting the outer future.
    await Future<void>.delayed(Duration.zero);
    expect(repo.nowNextCompleters.length, 1);
    repo.nowNextCompleters[0].complete(_nowNext('gen2'));
    await second;

    // The stale generation-1 load never gets to its own refreshNowNext() call
    // (its generation check returns early first).
    repo.loadCompleters[0].complete(_snapshot('gen1'));
    await first;

    expect(controller.channels.map((c) => c.id), ['gen2']);
  });

  test('a catalog reload keeps the visible channels and cached guide', () async {
    final initial = controller.load();
    repo.loadCompleters.single.complete(_snapshot('cached'));
    await Future<void>.delayed(Duration.zero);
    repo.nowNextCompleters.single.complete(_nowNext('cached'));
    await initial;

    final reload = controller.load();
    expect(controller.loading, isTrue);
    expect(controller.channels.single.id, 'cached');
    expect(controller.epgForChannel('cached').now?.title, 'cached');

    repo.loadCompleters.last.complete(_snapshot('cached'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.epgForChannel('cached').now?.title, 'cached');

    repo.nowNextCompleters.last.complete((
      now: {
        'cached': Programme(
          channelId: 'cached',
          start: DateTime(2024),
          stop: DateTime(2024, 1, 1, 1),
          title: 'Updated guide',
        ),
      },
      next: <String, Programme>{},
    ));
    await reload;
    expect(controller.epgForChannel('cached').now?.title, 'Updated guide');
    expect(controller.loading, isFalse);
  });

  test('overlapping now-next refreshes share one database query', () async {
    final first = controller.refreshNowNext();
    final second = controller.refreshNowNext();
    final third = controller.refreshNowNext();
    expect(repo.nowNextCompleters, hasLength(1));

    repo.nowNextCompleters.single.complete(_nowNext('shared'));
    await Future.wait([first, second, third]);
    expect(controller.now.keys, ['shared']);

    final later = controller.refreshNowNext();
    expect(repo.nowNextCompleters, hasLength(2));
    repo.nowNextCompleters.last.complete(_nowNext('later'));
    await later;
    expect(controller.now.keys, ['later']);
  });

  testWidgets('automatic guide reads pause, refresh on return and dispose', (
    tester,
  ) async {
    controller.setEpgRefreshActive(false);
    controller.startEpgRefresh();
    await tester.pump(const Duration(minutes: 2));
    expect(repo.nowNextCompleters, isEmpty);

    controller.setEpgRefreshActive(true);
    controller.setEpgRefreshActive(true);
    expect(repo.nowNextCompleters, hasLength(1));
    repo.nowNextCompleters.last.complete(_nowNext('returned'));
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));
    expect(repo.nowNextCompleters, hasLength(2));
    repo.nowNextCompleters.last.complete(_nowNext('minute'));
    await tester.pump();

    controller.setEpgRefreshActive(false);
    await tester.pump(const Duration(minutes: 2));
    expect(repo.nowNextCompleters, hasLength(2));
    final explicit = controller.refreshNowNext();
    expect(repo.nowNextCompleters, hasLength(3));
    repo.nowNextCompleters.last.complete(_nowNext('explicit'));
    await explicit;
    expect(controller.now.keys, ['explicit']);

    controller.dispose();
    controllerDisposed = true;
    controller.setEpgRefreshActive(true);
    await tester.pump(const Duration(minutes: 2));
    expect(repo.nowNextCompleters, hasLength(3));
  });

  testWidgets('hidden guide replacement invalidates explicit target caches', (
    tester,
  ) async {
    controller.dispose();
    controller = LiveController(repo: repo, epgChannelIds: () => ['visible']);
    final initial = controller.refreshNowNext();
    repo.nowNextCompleters.last.complete(_nowNext('visible'));
    await initial;
    final target = controller.ensureEpgForChannels(['outside']);
    repo.nowNextCompleters.last.complete(_nowNext('outside'));
    await target;

    controller.setEpgRefreshActive(false);
    controller.startEpgRefresh();
    db.notifyEpgChanged(repo.source.id);
    await tester.pump();
    expect(repo.nowNextCompleters, hasLength(2));
    final freshTarget = controller.ensureEpgForChannels(['outside']);
    expect(repo.nowNextCompleters, hasLength(3));
    repo.nowNextCompleters.last.complete(_nowNext('outside'));
    await freshTarget;

    controller.setEpgRefreshActive(true);
    expect(repo.nowNextCompleters, hasLength(4));
    repo.nowNextCompleters.last.complete(_nowNext('fresh-visible'));
    await tester.pump();
    expect(controller.now.keys, ['fresh-visible']);
    controller.dispose();
    controllerDisposed = true;
  });

  testWidgets('hidden guide replacement rejects an older viewport read', (
    tester,
  ) async {
    controller.startEpgRefresh();
    final pending = controller.refreshNowNext();
    controller.setEpgRefreshActive(false);
    db.notifyEpgChanged(repo.source.id);
    await tester.pump();
    repo.nowNextCompleters.last.complete(_nowNext('stale'));
    await pending;
    expect(controller.now, isEmpty);
    controller.setEpgRefreshActive(true);
    expect(repo.nowNextCompleters, hasLength(2));
    repo.nowNextCompleters.last.complete(_nowNext('fresh'));
    await tester.pump();
    expect(controller.now.keys, ['fresh']);
    controller.dispose();
    controllerDisposed = true;
  });

  test(
    'scroll windows read only their channels and coalesce a trailing move',
    () async {
      controller.dispose();
      var ids = ['first', 'preview'];
      controller = LiveController(repo: repo, epgChannelIds: () => ids);
      final first = controller.refreshNowNext(windowOnly: true);
      expect(repo.nowNextChannelIds, [
        ['first', 'preview'],
      ]);

      await controller.refreshNowNext(windowOnly: true);
      expect(repo.nowNextCompleters, hasLength(1));
      ids = ['second', 'preview'];
      final moved = controller.refreshNowNext(windowOnly: true);
      ids = ['third', 'preview'];
      final movedAgain = controller.refreshNowNext(windowOnly: true);
      repo.nowNextCompleters.first.complete(_nowNext('first'));
      await Future<void>.delayed(Duration.zero);
      expect(repo.nowNextChannelIds, [
        ['first', 'preview'],
        ['third', 'preview'],
      ]);
      repo.nowNextCompleters.last.complete(_nowNext('third'));
      await Future.wait([first, moved, movedAgain]);
      expect(controller.now.keys, ['third']);

      ids = ['without-guide'];
      final empty = controller.refreshNowNext(windowOnly: true);
      repo.nowNextCompleters.last.complete((
        now: <String, Programme>{},
        next: <String, Programme>{},
      ));
      await empty;
      expect(controller.now, isEmpty);
      expect(
        controller.hasEpg,
        isTrue,
        reason: 'scrolling through a guide gap must not change row heights',
      );
    },
  );

  test(
    'guide changes during a query coalesce into one fresh trailing read',
    () async {
      final first = controller.refreshNowNext();
      final changed = controller.refreshNowNext(guideChanged: true);
      final changedAgain = controller.refreshNowNext(guideChanged: true);
      expect(repo.nowNextCompleters, hasLength(1));

      repo.nowNextCompleters.first.complete(_nowNext('old-guide'));
      await Future<void>.delayed(Duration.zero);
      expect(repo.nowNextCompleters, hasLength(2));
      repo.nowNextCompleters.last.complete(_nowNext('new-guide'));
      await Future.wait([first, changed, changedAgain]);

      expect(repo.nowNextCompleters, hasLength(2));
      expect(controller.now.keys, ['new-guide']);
    },
  );

  test(
    'fullscreen targets retain their guide outside browsing windows',
    () async {
      controller.dispose();
      controller = LiveController(repo: repo, epgChannelIds: () => ['visible']);
      final browsing = controller.refreshNowNext();
      repo.nowNextCompleters.last.complete(_nowNext('visible'));
      await browsing;

      final target = controller.ensureEpgForChannels(['outside']);
      final duplicate = controller.ensureEpgForChannels(['outside']);
      expect(repo.nowNextChannelIds.last, ['outside']);
      expect(repo.nowNextCompleters, hasLength(2));
      repo.nowNextCompleters.last.complete(_nowNext('outside'));
      await Future.wait([target, duplicate]);
      expect(controller.epgForChannel('outside').now?.title, 'outside');
      expect(controller.now.keys, ['visible']);

      final nextBrowsing = controller.refreshNowNext();
      repo.nowNextCompleters.last.complete(_nowNext('visible'));
      await nextBrowsing;
      expect(controller.epgForChannel('outside').now?.title, 'outside');
      expect(await controller.ensureEpgForChannels(['outside']), isFalse);

      for (var batch = 0; batch < 2; batch++) {
        var visited = 0;
        final bounded = controller.ensureEpgForChannels(
          Iterable.generate(50000, (index) {
            visited++;
            return 'batch$batch.$index';
          }),
        );
        expect(
          visited,
          64,
          reason: 'even an accidental full zap range must stay bounded',
        );
        expect(repo.nowNextChannelIds.last, hasLength(64));
        repo.nowNextCompleters.last.complete((
          now: <String, Programme>{},
          next: <String, Programme>{},
        ));
        await bounded;
      }
      final reread = controller.ensureEpgForChannels(['outside']);
      expect(repo.nowNextChannelIds.last, [
        'outside',
      ], reason: 'the bounded auxiliary cache must evict old targets');
      repo.nowNextCompleters.last.complete(_nowNext('outside'));
      await reread;
    },
  );

  test(
    'same provider channel id has independent source-owned target caches',
    () async {
      controller.dispose();
      repo = _GatedRepo(source: _NamedSource('primary'), db: db);
      controller = LiveController(repo: repo, epgChannelIds: () => ['visible']);
      final foreignRepo = _GatedRepo(source: _NamedSource('foreign'), db: db);
      final foreign = LiveController(
        repo: foreignRepo,
        epgChannelIds: () => ['visible'],
      );
      addTearDown(foreign.dispose);
      final primaryRead = controller.ensureEpgForChannels(['shared']);
      final foreignRead = foreign.ensureEpgForChannels(['shared']);
      final original = _nowNext('shared').now['shared']!;
      ({Map<String, Programme> now, Map<String, Programme> next}) guide(
        String title,
      ) => (
        now: {
          'shared': Programme(
            channelId: 'shared',
            title: title,
            start: original.start,
            stop: original.stop,
          ),
        },
        next: <String, Programme>{},
      );
      repo.nowNextCompleters.single.complete(guide('Primary guide'));
      foreignRepo.nowNextCompleters.single.complete(guide('Foreign guide'));
      await Future.wait([primaryRead, foreignRead]);
      expect(controller.epgForChannel('shared').now?.title, 'Primary guide');
      expect(foreign.epgForChannel('shared').now?.title, 'Foreign guide');
    },
  );

  test('failed target reads are cached until a guide replacement', () async {
    controller.dispose();
    controller = LiveController(repo: repo, epgChannelIds: () => ['visible']);
    final failed = controller.ensureEpgForChannels(['outside']);
    repo.nowNextCompleters.single.completeError(
      StateError('storage unavailable'),
    );
    await failed;
    expect(await controller.ensureEpgForChannels(['outside']), isFalse);
    expect(
      repo.nowNextCompleters,
      hasLength(1),
      reason: 'a redraw after an error must not create a read/notify loop',
    );

    final replacement = controller.refreshNowNext(guideChanged: true);
    repo.nowNextCompleters.last.complete(_nowNext('visible'));
    await replacement;
    final recovered = controller.ensureEpgForChannels(['outside']);
    expect(repo.nowNextChannelIds.last, ['outside']);
    repo.nowNextCompleters.last.complete(_nowNext('outside'));
    await recovered;
    expect(controller.epgForChannel('outside').now?.title, 'outside');
  });

  test('guide replacement does not join an obsolete target request', () async {
    controller.dispose();
    controller = LiveController(repo: repo, epgChannelIds: () => ['visible']);
    final old = controller.ensureEpgForChannels(['outside']);
    final replacement = controller.refreshNowNext(guideChanged: true);
    final fresh = controller.ensureEpgForChannels(['outside']);
    expect(repo.nowNextChannelIds, [
      ['outside'],
      ['visible'],
      ['outside'],
    ]);
    repo.nowNextCompleters[0].complete(_nowNext('outside'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.epgForChannel('outside').now, isNull);
    expect(repo.nowNextCompleters, hasLength(3));
    repo.nowNextCompleters[1].complete(_nowNext('visible'));
    repo.nowNextCompleters[2].complete(_nowNext('outside'));
    await old;
    await replacement;
    await fresh;
    expect(controller.epgForChannel('outside').now?.title, 'outside');
  });

  test(
    'synchronous target failures leave no completed request stuck in flight',
    () async {
      controller.dispose();
      controller = LiveController(repo: repo, epgChannelIds: () => ['visible']);
      repo.throwSynchronously = true;
      await controller.ensureEpgForChannels(['outside']);
      expect(await controller.ensureEpgForChannels(['outside']), isFalse);
      expect(repo.nowNextChannelIds, hasLength(1));
      await controller.refreshNowNext(guideChanged: true);
      await controller.ensureEpgForChannels(['outside']);
      expect(await controller.ensureEpgForChannels(['outside']), isFalse);
      expect(repo.nowNextChannelIds, hasLength(3));
    },
  );

  test(
    'guide changes still refresh when the shared in-flight read fails',
    () async {
      final first = controller.refreshNowNext();
      final changed = controller.refreshNowNext(guideChanged: true);
      repo.nowNextCompleters.single.completeError(StateError('read failed'));
      await Future<void>.delayed(Duration.zero);
      expect(repo.nowNextCompleters, hasLength(2));

      repo.nowNextCompleters.last.complete(_nowNext('recovered'));
      await Future.wait([first, changed]);
      expect(controller.now.keys, ['recovered']);
    },
  );

  test(
    'stale now-next result is dropped after a newer load completes',
    () async {
      final refresh = controller.refreshNowNext();
      expect(repo.nowNextCompleters.length, 1);

      final load = controller.load();
      expect(repo.loadCompleters.length, 1);
      repo.loadCompleters[0].complete(_snapshot('fresh'));
      // load() awaits its own refreshNowNext() internally, so give it a second
      // gated now/next completer to resolve.
      await Future<void>.delayed(Duration.zero);
      expect(repo.nowNextCompleters.length, 2);
      repo.nowNextCompleters[1].complete(_nowNext('fresh'));
      await load;

      // The stale refresh (started before the new load) resolves late.
      repo.nowNextCompleters[0].complete(_nowNext('stale'));
      await refresh;

      expect(controller.now.keys, ['fresh']);
      expect(controller.next, isEmpty);
    },
  );

  test(
    'dispose during load causes no notification and does not throw',
    () async {
      var notifications = 0;
      controller.addListener(() => notifications++);

      final future = controller.load();
      final notificationsBeforeDispose = notifications;
      controller.dispose();
      controllerDisposed = true;

      repo.loadCompleters[0].complete(_snapshot('after-dispose'));
      await expectLater(future, completes);

      expect(notifications, notificationsBeforeDispose);
    },
  );

  test(
    'dispose during refreshNowNext causes no notification and does not throw',
    () async {
      var notifications = 0;
      controller.addListener(() => notifications++);

      final future = controller.refreshNowNext();
      final notificationsBeforeDispose = notifications;
      controller.dispose();
      controllerDisposed = true;

      repo.nowNextCompleters[0].complete(_nowNext('after-dispose'));
      await expectLater(future, completes);

      expect(notifications, notificationsBeforeDispose);
    },
  );

  group('the guide refreshing behind the channel list', () {
    late _EpgRepo epgRepo;
    late LiveController epgController;

    setUp(() {
      epgRepo = _EpgRepo(source: DemoSource(), db: db);
      epgController = LiveController(repo: epgRepo);
    });

    tearDown(() => epgController.dispose());

    test('reports the refresh as running until it ends', () async {
      await epgController.load();
      expect(epgController.epgRefreshing, isTrue);

      epgRepo.guide.complete();
      await pumpEventQueue();
      expect(epgController.epgRefreshing, isFalse);
    });

    test('expects a guide from a source that says it carries one', () async {
      // This is what holds the rows at their tall extent before the guide
      // lands. Without it a source's first load draws 72 px rows and jumps to
      // 112 px when the guide arrives.
      await epgController.load();
      expect(epgController.expectsEpg, isTrue);

      epgRepo.guide.complete();
      await pumpEventQueue();
      expect(
        epgController.expectsEpg,
        isFalse,
        reason: 'once the refresh is over the real guide decides',
      );
    });

    test('expects nothing from a source that reports unknown', () async {
      // Taking an `unknown` source at its word would size every first load's
      // rows tall and shrink them when no guide turned up — the same flip, in
      // the other direction.
      final unknown = _EpgRepo(source: _UnknownCapabilitySource(), db: db);
      final controller = LiveController(repo: unknown);
      addTearDown(controller.dispose);

      await controller.load();
      expect(controller.epgRefreshing, isTrue);
      expect(controller.expectsEpg, isFalse);
      unknown.guide.complete();
    });

    test('a failed refresh with no guide behind it is reported', () async {
      // The case the user can act on: a wrong or dead guide URL looks exactly
      // like a source that has no EPG.
      epgRepo.failed = true;
      await epgController.load();
      epgRepo.guide.complete();
      await pumpEventQueue();

      expect(epgController.epgUnavailable, isTrue);
      expect(epgController.epgRefreshing, isFalse);
    });

    test('a failed refresh with a cached guide stays quiet', () async {
      // Retaining the last good guide is the failure policy working, not
      // something to alarm anyone about.
      epgRepo
        ..failed = true
        ..guideRows = _nowNext('cached');
      await epgController.load();
      epgRepo.guide.complete();
      await pumpEventQueue();

      expect(epgController.epgUnavailable, isFalse);
    });

    test('a successful refresh reports neither state', () async {
      epgRepo.guideRows = _nowNext('fresh');
      await epgController.load();
      epgRepo.guide.complete();
      await pumpEventQueue();

      expect(epgController.epgRefreshing, isFalse);
      expect(epgController.epgUnavailable, isFalse);
      expect(epgController.now.keys, ['fresh']);
    });

    test('a newer load clears a previous failure verdict', () async {
      epgRepo.failed = true;
      await epgController.load();
      epgRepo.guide.complete();
      await pumpEventQueue();
      expect(epgController.epgUnavailable, isTrue);

      // A retry must not open still showing the previous attempt's verdict.
      final retry = _EpgRepo(source: DemoSource(), db: db);
      final controller = LiveController(repo: retry);
      addTearDown(controller.dispose);
      await controller.load();
      expect(controller.epgUnavailable, isFalse);
      retry.guide.complete();
    });
  });
}
