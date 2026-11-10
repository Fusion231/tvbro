import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/diagnostics_log.dart';
import 'package:iptvs/data/net.dart';
import 'package:iptvs/data/source_identity_migration.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/channel_list_screen.dart';
import 'package:iptvs/screens/home_shell.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/widgets/library_preload_progress.dart';
import 'package:iptvs/widgets/tv_text_field.dart';

const _sourceId = 'new-onboarding-source';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late AppDatabase db;
  late SourceStore store;

  setUp(() async {
    ProviderRequestGate.instance.debugReset();
    FlutterSecureStorage.setMockInitialValues({});
    DiagnosticsLog.instance.clear();
    tempDir = Directory.systemTemp.createTempSync('iptvs_home_preload');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
    store = SourceStore();
  });

  tearDown(() async {
    await db.epgIngest.cancelAndWait();
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> exercisePreload(
    WidgetTester tester, {
    required bool failMovies,
    bool startWithBadUrl = false,
    int transientMovieFailures = 0,
    int transientConnectFailures = 0,
    int catalogItems = 1,
    bool restartOffline = false,
    bool gateEpg = false,
    bool failEpg = false,
    bool disposeDuringEpg = false,
    bool failLive = false,
  }) async {
    Future<T> read<T>(Future<T> Function() operation) async =>
        (await tester.runAsync(operation)) as T;

    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fixture = await tester.runAsync(
      () => _XtreamFixture.start(
        failMovies: failMovies,
        gateValidation: startWithBadUrl,
        transientMovieFailures: transientMovieFailures,
        transientConnectFailures: transientConnectFailures,
        catalogItems: catalogItems,
        gateEpg: gateEpg,
        failEpg: failEpg,
        failLive: failLive,
        now: tester.binding.clock.now,
      ),
    );
    if (fixture == null) throw StateError('Could not start Xtream fixture');
    addTearDown(() => tester.runAsync(fixture.close));
    final validHost = 'http://127.0.0.1:${fixture.server.port}';
    final savedHost = startWithBadUrl ? '$validHost/bad' : validHost;

    // Saving a source with an empty database is the state immediately after
    // onboarding's first-source editor returns to Home.
    await read(
      () => store.save(
        SourceConfig(
          id: _sourceId,
          kind: SourceKind.xtream,
          label: 'New provider',
          fields: {
            'host': savedHost,
            'username': 'fixture',
            'password': 'fixture',
          },
        ),
      ),
    );
    expect(await read(() => db.lastSynced(_sourceId)), isNull);

    final liveReady = _nextLog((entry) => entry.scope == 'source:$_sourceId');
    final preloadReady = _nextLog(
      (entry) => entry.message == 'onboarding preload completed',
    );

    await HttpOverrides.runWithHttpOverrides(() async {
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: HomeShell(db: db, store: store),
          ),
        );
        if (startWithBadUrl) {
          await _pumpUntil(
            tester,
            () => find.text('Back and edit source').evaluate().isNotEmpty,
          );
          expect(find.byType(ChannelListScreen), findsNothing);
          expect(find.text('Could not connect to the source'), findsOneWidget);
          expect(
            find.text(
              'The provider could not find the requested data (HTTP 404). '
              'Try again; if the error persists, check the source URL.',
            ),
            findsOneWidget,
          );
          expect(find.text('Try again'), findsOneWidget);
          expect(fixture.requests.keys, everyElement('invalid-url'));
          // After the connection error is visible, the independent expiry
          // watcher may also perform one internally retried account lookup.
          expect(fixture.requests['invalid-url'], inInclusiveRange(2, 4));
          _expectRetryPauses(fixture.requestTimes['invalid-url']!);
          expect(await read(() => db.lastSynced(_sourceId)), isNull);

          final editButton = find.text('Back and edit source');
          await tester.ensureVisible(editButton);
          await tester.pumpAndSettle();
          await tester.tap(editButton);
          await _pumpUntil(
            tester,
            () => find.text('Edit source').evaluate().isNotEmpty,
          );
          await tester.pumpAndSettle();

          TvTextField field(String label) => tester.widget<TvTextField>(
            find.byWidgetPredicate(
              (widget) => widget is TvTextField && widget.label == label,
            ),
          );
          expect(field('Host').controller.text, savedHost);
          expect(field('Username').controller.text, 'fixture');
          expect(field('Password').controller.text, 'fixture');
          expect(field('Label (optional)').controller.text, 'New provider');

          field('Host').controller.text = validHost;
          final saveButton = find.text('Save source');
          await tester.ensureVisible(saveButton);
          await tester.pump();
          await tester.tap(saveButton);
          await _pumpUntil(
            tester,
            () =>
                fixture.validationStarted.isCompleted &&
                find.text('Checking source connection…').evaluate().isNotEmpty,
          );
          expect(find.byType(ChannelListScreen), findsNothing);
          expect(fixture.requests['get_live_categories'], isNull);
          expect(fixture.requests['get_vod_categories'], isNull);
          expect(fixture.requests['get_series_categories'], isNull);
          final corrected = await store.activeConfig();
          expect(corrected!.id, _sourceId);
          expect(corrected.fields['host'], validHost);
          expect(corrected.fields['username'], 'fixture');
          expect(corrected.fields['password'], 'fixture');
          fixture.validationGate.complete();
        }
        // Advance Flutter's fake clock as well as real HTTP/SQLite work. The
        // source loader resumes through both zones before it starts requests.
        var movieReleasedEarly = false;
        await _pumpUntil(
          tester,
          () =>
              fixture.movieStarted.isCompleted &&
              fixture.seriesStarted.isCompleted,
        );
        if (!fixture.liveStarted.isCompleted) {
          movieReleasedEarly = true;
          fixture.movieGate.complete();
        }
        bool preloadStageFinished(ContentKind kind) {
          final progress = find.byType(LibraryPreloadProgress);
          return progress.evaluate().isNotEmpty &&
              tester.widget<LibraryPreloadProgress>(progress).stages[kind] !=
                  null;
        }
        await _pumpUntil(
          tester,
          () =>
              fixture.liveStarted.isCompleted &&
              (failLive || liveReady.isCompleted) &&
              (!movieReleasedEarly ||
                  preloadStageFinished(ContentKind.movie)),
        );
        if (transientConnectFailures > 0) {
          _expectRetryPauses(fixture.requestTimes['connect']!);
        }

        expect(find.text('Preparing your library'), findsOneWidget);
        expect(find.byType(ChannelListScreen), findsNothing);
        expect(
          (await read(() => db.readChannels(_sourceId)))
              .map((channel) => channel.name),
          failLive ? isEmpty : ['Fixture TV'],
        );
        if (!movieReleasedEarly) {
          expect(
            await read(() => db.mediaSyncState(_sourceId, ContentKind.movie)),
            isNull,
          );
        }
        expect(
          await read(() => db.mediaSyncState(_sourceId, ContentKind.series)),
          isNull,
        );

        if (!movieReleasedEarly) fixture.movieGate.complete();
        await _pumpUntil(tester, () => fixture.movieResponded.isCompleted);
        // A fast or failed movie request cannot finish onboarding while the
        // series catalog still has an outstanding response.
        expect(find.text('Preparing your library'), findsOneWidget);
        expect(find.byType(ChannelListScreen), findsNothing);

        fixture.seriesGate.complete();
        if (gateEpg) {
          await _pumpUntil(
            tester,
            () =>
                fixture.epgStarted.isCompleted &&
                (find.byType(ChannelListScreen).evaluate().isNotEmpty ||
                    (find
                            .byType(LibraryPreloadProgress)
                            .evaluate()
                            .isNotEmpty &&
                        tester
                            .widget<LibraryPreloadProgress>(
                              find.byType(LibraryPreloadProgress),
                            )
                            .stages
                            .values
                            .every((ready) => ready != null))),
          );
          expect(find.byType(LibraryPreloadProgress), findsOneWidget);
          expect(find.byType(ChannelListScreen), findsNothing);
          expect(find.text('Program guide (EPG)'), findsOneWidget);
          expect(preloadReady.isCompleted, isFalse);
          expect(fixture.epgGate.isCompleted, isFalse);
          expect(await read(() => db.lastEpgSynced(_sourceId)), isNull);
          expect(fixture.requests['xmltv'], 1);
          if (disposeDuringEpg) {
            await tester.pumpWidget(const SizedBox());
            fixture.epgGate.complete();
            var epgStopped = false;
            final stopEpg = db.epgIngest.cancelAndWait().whenComplete(
              () => epgStopped = true,
            );
            await _pumpUntil(tester, () => epgStopped);
            await stopEpg;
            await tester.pump();
            expect(tester.takeException(), isNull);
            expect(preloadReady.isCompleted, isFalse);
            expect(find.byType(HomeShell), findsNothing);
            return;
          }
          fixture.epgGate.complete();
        }
        await _pumpUntil(
          tester,
          () =>
              preloadReady.isCompleted &&
              find.byType(ChannelListScreen).evaluate().isNotEmpty,
        );

        expect(find.byType(ChannelListScreen), findsOneWidget);
        expect(find.text('Preparing your library'), findsNothing);
        if (failMovies || failLive) {
          await tester.pump();
          final section = failLive ? 'TV channels' : 'Movies';
          expect(
            find.textContaining('Could not load $section.'),
            findsOneWidget,
          );
          expect(
            find.textContaining('Saved content is still available.'),
            findsOneWidget,
          );
        }
        if (!gateEpg && !failLive) {
          await tester.pump();
          expect(
            find.textContaining(
              'The source returned no current program information.',
            ),
            findsOneWidget,
          );
        }
        if (gateEpg) {
          final repo = tester
              .widget<ChannelListScreen>(find.byType(ChannelListScreen))
              .repo;
          expect(repo.lastEpgRefreshFailed, failEpg);
          if (failEpg) {
            await tester.pump();
            expect(
              find.textContaining('Could not download the program guide.'),
              findsOneWidget,
            );
          }
          expect(
            await read(() => db.lastEpgSynced(_sourceId)),
            failEpg ? isNull : isNotNull,
          );
          if (!failEpg) {
            final channels = await read(() => db.readChannels(_sourceId));
            final programmes = await read(
              () => db.programmesForChannel(
                _sourceId,
                channels.single.id,
                from: tester.binding.clock.now().subtract(
                  const Duration(hours: 2),
                ),
                to: tester.binding.clock.now().add(const Duration(hours: 2)),
              ),
            );
            expect(programmes.map((programme) => programme.title), [
              'Fixture programme',
            ]);
          }
          // Browsing reuses the initial guide task and its failure backoff
          // instead of downloading it again on the handoff.
          expect(fixture.requests['xmltv'], 1);
        }
        expect(
          await read(() => db.lastSynced(_sourceId)),
          failLive ? isNull : isNotNull,
        );
        if (failLive) {
          expect(fixture.requests['xmltv'], isNull);
          expect(await read(() => db.lastEpgSynced(_sourceId)), isNull);
          expect(
            DiagnosticsLog.instance.entries.any(
              (entry) =>
                  entry.message.startsWith('onboarding live preload failed:'),
            ),
            isTrue,
          );
        }
        expect(
          await read(() => db.mediaSyncState(_sourceId, ContentKind.series)),
          isNotNull,
        );
        expect(
          (await read(() => db.readMediaItems(_sourceId, ContentKind.series)))
              .map((item) => item.title),
          _catalogTitles('series', catalogItems),
        );
        expect(
          (await read(
            () => db.readMediaCategories(_sourceId, ContentKind.series),
          )).map((category) => category.title),
          ['Series'],
        );

        if (failMovies) {
          expect(
            await read(() => db.mediaSyncState(_sourceId, ContentKind.movie)),
            isNull,
          );
          expect(
            await read(() => db.readMediaItems(_sourceId, ContentKind.movie)),
            isEmpty,
          );
          expect(
            DiagnosticsLog.instance.entries.any(
              (entry) =>
                  entry.message.startsWith('onboarding movie preload failed:'),
            ),
            isTrue,
          );
        } else {
          expect(
            await read(() => db.mediaSyncState(_sourceId, ContentKind.movie)),
            isNotNull,
          );
          expect(
            (await read(() => db.readMediaItems(_sourceId, ContentKind.movie)))
                .map((item) => item.title),
            _catalogTitles('movie', catalogItems),
          );
          expect(
            (await read(
              () => db.readMediaCategories(_sourceId, ContentKind.movie),
            )).map((category) => category.title),
            ['Movies'],
          );
          // The repository passed into the library can immediately serve both
          // tabs from the seeded cache instead of fetching their catalogs again.
          final repo = tester
              .widget<ChannelListScreen>(find.byType(ChannelListScreen))
              .repo;
          var cacheReady = false;
          final cached = Future.wait([
            repo.loadMedia(ContentKind.movie),
            repo.loadMedia(ContentKind.series),
          ]).whenComplete(() => cacheReady = true);
          await _pumpUntil(tester, () => cacheReady);
          expect(
            (await cached).every((snapshot) => snapshot.fromCache),
            isTrue,
          );
          for (final snapshot in await cached) {
            expect(snapshot.items.length, catalogItems);
            expect(snapshot.hasMore, isFalse);
          }
        }

        expect(
          fixture.requests['get_live_streams'],
          failLive ? greaterThanOrEqualTo(2) : 1,
        );
        expect(
          fixture.requests['get_vod_streams'],
          failMovies ? 2 : transientMovieFailures + 1,
        );
        expect(fixture.requests['get_series'], 1);
        if (failMovies || transientMovieFailures > 0) {
          _expectRetryPauses(fixture.requestTimes['get_vod_streams']!);
        }
        if (restartOffline) {
          final before = Map<String, int>.from(fixture.requests);
          await tester.pumpWidget(const SizedBox());
          var epgStopped = false;
          final stopEpg = db.epgIngest.cancelAndWait().whenComplete(
            () => epgStopped = true,
          );
          await _pumpUntil(tester, () => epgStopped);
          await stopEpg;
          fixture.offline = true;
          final cachedLive = _nextLog(
            (entry) =>
                entry.scope == 'library' &&
                entry.message.startsWith('loaded live ') &&
                entry.message.contains('cache=true'),
          );
          await tester.pumpWidget(
            MaterialApp(
              home: HomeShell(db: db, store: store),
            ),
          );
          await _pumpUntil(
            tester,
            () => find.byKey(const ValueKey('home-live')).evaluate().isNotEmpty,
          );
          await tester.ensureVisible(find.byKey(const ValueKey('home-live')));
          await tester.tap(find.byKey(const ValueKey('home-live')));
          await _pumpUntil(tester, () => cachedLive.isCompleted);
          expect(find.byType(ChannelListScreen), findsOneWidget);
          expect(find.text('Preparing your library'), findsNothing);
          final repo = tester
              .widget<ChannelListScreen>(find.byType(ChannelListScreen))
              .repo;
          final cached = await read(
            () => Future.wait([
              repo.loadMedia(ContentKind.movie),
              repo.loadMedia(ContentKind.series),
            ]),
          );
          expect(cached.every((snapshot) => snapshot.fromCache), isTrue);
          expect(cached.every((snapshot) => !snapshot.hasMore), isTrue);
          expect(fixture.requests, before);
        }
      } finally {
        if (!fixture.epgGate.isCompleted) fixture.epgGate.complete();
        await tester.pumpWidget(const SizedBox());
        var epgStopped = false;
        final stopEpg = db.epgIngest.cancelAndWait().whenComplete(
          () => epgStopped = true,
        );
        await _pumpUntil(tester, () => epgStopped);
        await stopEpg;
        await tester.runAsync(fixture.close);
      }
    }, _RealHttpOverrides());
  }

  Future<void> exerciseRefresh(
    WidgetTester tester, {
    bool failConnection = false,
    bool gateEpg = false,
  }) async {
    Future<T> read<T>(Future<T> Function() operation) async =>
        (await tester.runAsync(operation)) as T;

    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = await tester.runAsync(
      () => _XtreamFixture.start(
        failMovies: false,
        gateEpg: gateEpg,
        now: tester.binding.clock.now,
      ),
    );
    if (fixture == null) throw StateError('Could not start Xtream fixture');
    addTearDown(() => tester.runAsync(fixture.close));
    final config = SourceConfig(
      id: _sourceId,
      kind: SourceKind.xtream,
      label: 'Cached provider',
      fields: {
        'host': 'http://127.0.0.1:${fixture.server.port}',
        'username': 'fixture',
        'password': 'fixture',
      },
    );
    await read(
      () => store.save(config),
    );
    await read(() => migrateSourceIdentity(db, config));
    await read(
      () => db.replaceLibrary(
        _sourceId,
        'Cached provider',
        const [Category(id: 'stale', title: 'Stale TV')],
        const [
          Channel(id: 'stale-tv', name: 'Stale channel', categoryId: 'stale'),
        ],
        completeCatalog: true,
      ),
    );
    for (final kind in [ContentKind.movie, ContentKind.series]) {
      await read(
        () => db.replaceMediaLibrary(
          _sourceId,
          kind,
          [MediaCategory(id: 'stale', title: 'Stale ${kind.name}', kind: kind)],
          [
            MediaItem(
              id: 'stale-${kind.name}',
              title: 'Stale ${kind.name}',
              categoryId: 'stale',
              kind: kind,
            ),
          ],
          completeCatalog: true,
        ),
      );
    }

    await HttpOverrides.runWithHttpOverrides(() async {
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: HomeShell(db: db, store: store),
          ),
        );
        await _pumpUntil(
          tester,
          () => find.byKey(const ValueKey('home-movie')).evaluate().isNotEmpty,
        );
        expect(find.byType(LibraryPreloadProgress), findsNothing);
        expect(fixture.requests['get_live_streams'], isNull);
        expect(fixture.requests['get_vod_streams'], isNull);
        expect(fixture.requests['get_series'], isNull);
        fixture.rejectAuthentication = failConnection;
        await tester.tap(find.byTooltip('Menu'));
        await _pumpUntil(
          tester,
          () => find.text('Refresh').hitTestable().evaluate().isNotEmpty,
        );
        await tester.tap(find.text('Refresh'));
        await tester.pump();
        expect(find.byType(LibraryPreloadProgress), findsOneWidget);
        expect(find.text('Preparing your library'), findsOneWidget);

        if (failConnection) {
          await _pumpUntil(
            tester,
            () => find.text('Try again').evaluate().isNotEmpty,
          );
          expect(find.text('Could not connect to the source'), findsOneWidget);
          expect(
            (await read(() => db.readChannels(_sourceId))).single.name,
            'Stale channel',
          );
          for (final kind in [ContentKind.movie, ContentKind.series]) {
            expect(
              (await read(() => db.readMediaItems(_sourceId, kind)))
                  .single
                  .title,
              'Stale ${kind.name}',
            );
          }
          expect(fixture.requests['get_live_streams'], isNull);
          expect(fixture.requests['get_vod_streams'], isNull);
          expect(fixture.requests['get_series'], isNull);
          fixture.rejectAuthentication = false;
          await tester.ensureVisible(find.text('Try again'));
          await tester.tap(find.text('Try again'));
          await tester.pump();
          expect(find.byType(LibraryPreloadProgress), findsOneWidget);
          await _pumpUntil(
            tester,
            () => find.text('Try again').evaluate().isNotEmpty,
          );
          // Manual retry cannot bypass a rejected account's host cooldown.
          expect(fixture.requests['get_live_streams'], isNull);
          expect(fixture.requests['get_vod_streams'], isNull);
          expect(fixture.requests['get_series'], isNull);
          // Release the simulated refusal so the same explicit retry can
          // exercise recovery after the pause has elapsed.
          ProviderRequestGate.instance.debugReset();
          await tester.ensureVisible(find.text('Try again'));
          await tester.tap(find.text('Try again'));
          await tester.pump();
        }

        await _pumpUntil(
          tester,
          () =>
              fixture.movieStarted.isCompleted &&
              fixture.seriesStarted.isCompleted,
        );
        expect(find.byType(ChannelListScreen), findsNothing);
        fixture.movieGate.complete();
        await _pumpUntil(
          tester,
          () =>
              fixture.movieResponded.isCompleted &&
              fixture.liveStarted.isCompleted,
        );
        expect(find.byType(LibraryPreloadProgress), findsOneWidget);
        expect(find.byType(ChannelListScreen), findsNothing);
        fixture.seriesGate.complete();
        if (gateEpg) {
          await _pumpUntil(
            tester,
            () =>
                fixture.epgStarted.isCompleted &&
                (find.byType(ChannelListScreen).evaluate().isNotEmpty ||
                    (find
                            .byType(LibraryPreloadProgress)
                            .evaluate()
                            .isNotEmpty &&
                        tester
                            .widget<LibraryPreloadProgress>(
                              find.byType(LibraryPreloadProgress),
                            )
                            .stages
                            .values
                            .every((ready) => ready != null))),
          );
          expect(find.byType(LibraryPreloadProgress), findsOneWidget);
          expect(find.byType(ChannelListScreen), findsNothing);
          expect(find.text('Program guide (EPG)'), findsOneWidget);
          expect(fixture.epgGate.isCompleted, isFalse);
          fixture.epgGate.complete();
        }
        await _pumpUntil(
          tester,
          () => find.byType(ChannelListScreen).evaluate().isNotEmpty,
        );
        expect(find.byType(LibraryPreloadProgress), findsNothing);
        expect(
          (await read(() => db.readChannels(_sourceId)))
              .map((channel) => channel.name),
          ['Fixture TV'],
        );
        for (final kind in [ContentKind.movie, ContentKind.series]) {
          expect(
            (await read(() => db.readMediaItems(_sourceId, kind)))
                .map((item) => item.title),
            _catalogTitles(kind.name, 1),
          );
        }
        expect(fixture.requests['get_live_streams'], 1);
        expect(fixture.requests['get_vod_streams'], 1);
        expect(fixture.requests['get_series'], 1);
        await tester.ensureVisible(find.byKey(const ValueKey('home-movie')));
        await tester.tap(find.byKey(const ValueKey('home-movie')));
        await _pumpUntil(
          tester,
          () => find.text('Fixture movie').evaluate().isNotEmpty,
        );
        expect(find.text('Stale movie'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox());
        var epgStopped = false;
        final stopEpg = db.epgIngest.cancelAndWait().whenComplete(
          () => epgStopped = true,
        );
        await _pumpUntil(tester, () => epgStopped);
        await stopEpg;
        await tester.runAsync(fixture.close);
      }
    }, _RealHttpOverrides());
  }

  testWidgets(
    'manual refresh shows progress and replaces all recently cached catalogs',
    (tester) => exerciseRefresh(tester),
  );

  testWidgets(
    'failed manual refresh preserves cached content and can be retried',
    (tester) => exerciseRefresh(tester, failConnection: true),
  );

  testWidgets(
    'manual refresh keeps progress open until the program guide is saved',
    (tester) => exerciseRefresh(tester, gateEpg: true),
  );

  testWidgets('cached M3U profile downloads its due guide before opening TV', (
    tester,
  ) async {
    Future<T> read<T>(Future<T> Function() operation) async =>
        (await tester.runAsync(operation)) as T;
    final server = await tester.runAsync(
      () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    if (server == null) throw StateError('Could not start M3U fixture');
    final guideStarted = Completer<void>();
    final guideGate = Completer<void>();
    final requests = <String, int>{};
    final playlistUrl = 'http://127.0.0.1:${server.port}/playlist.m3u';
    final guideUrl = 'http://127.0.0.1:${server.port}/guide.xml';
    final now = tester.binding.clock.now();
    String timestamp(DateTime value) =>
        '${value.toUtc().toIso8601String().substring(0, 19).replaceAll(RegExp(r'[-:T]'), '')} +0000';
    await read(() async {
      server.listen((request) async {
        final path = request.uri.path;
        requests.update(path, (count) => count + 1, ifAbsent: () => 1);
        try {
          if (path == '/playlist.m3u') {
            request.response.write(
              '#EXTM3U url-tvg="$guideUrl"\n'
              '#EXTINF:-1 tvg-id="fixture.tv",Fixture TV\n'
              'http://stream.example.invalid/live.ts\n',
            );
          } else if (path == '/guide.xml') {
            if (!guideStarted.isCompleted) guideStarted.complete();
            await guideGate.future;
            request.response.write(
              '<?xml version="1.0"?><tv>'
              '<channel id="fixture.tv"><display-name>Fixture TV</display-name></channel>'
              '<programme channel="fixture.tv" '
              'start="${timestamp(now.subtract(const Duration(hours: 1)))}" '
              'stop="${timestamp(now.add(const Duration(hours: 1)))}">'
              '<title>Cached profile guide</title></programme></tv>',
            );
          } else {
            request.response.statusCode = HttpStatus.notFound;
          }
          await request.response.close();
        } on SocketException {
          // Disposing Home may cancel a response held at the guide gate.
        } on HttpException {
          // Disposing Home may cancel a response held at the guide gate.
        }
      });
    });
    final config = SourceConfig(
      id: _sourceId,
      kind: SourceKind.m3u,
      label: 'Cached playlist',
      fields: {'playlistUrl': playlistUrl},
    );
    await read(() => store.save(config));
    await read(() => migrateSourceIdentity(db, config));
    await HttpOverrides.runWithHttpOverrides(() async {
      final source = config.build();
      try {
        final channels = await read(source.channels);
        final categories = await read(source.categories);
        await read(
          () => db.replaceLibrary(
            _sourceId,
            'Cached playlist',
            categories,
            channels,
            completeCatalog: true,
          ),
        );
        for (final kind in [ContentKind.movie, ContentKind.series]) {
          await read(
            () => db.replaceMediaLibrary(
              _sourceId,
              kind,
              const [],
              const [],
              completeCatalog: true,
            ),
          );
        }
        await read(source.dispose);
        expect(await read(() => db.lastEpgSynced(_sourceId)), isNull);

        await tester.pumpWidget(
          MaterialApp(
            home: HomeShell(db: db, store: store),
          ),
        );
        await _pumpUntil(
          tester,
          () => find.byKey(const ValueKey('home-live')).evaluate().isNotEmpty,
        );
        expect(find.byType(LibraryPreloadProgress), findsNothing);
        await _pumpUntil(tester, () => guideStarted.isCompleted);
        expect(requests, {'/playlist.m3u': 1, '/guide.xml': 1});

        guideGate.complete();
        final repo = tester
            .widget<ChannelListScreen>(find.byType(ChannelListScreen))
            .repo;
        var finished = false;
        final pending = repo.pendingEpgRefresh;
        expect(pending, isNotNull);
        final refresh = pending!.whenComplete(() => finished = true);
        await _pumpUntil(tester, () => finished);
        await refresh;
        expect(
          (await read(() => db.nowNext(_sourceId, now)))
              .now[channels.single.id]
              ?.title,
          'Cached profile guide',
        );
        expect(requests, {'/playlist.m3u': 1, '/guide.xml': 1});
      } finally {
        if (!guideGate.isCompleted) guideGate.complete();
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => db.epgIngest.cancelAndWait());
        await tester.runAsync(source.dispose);
        await tester.runAsync(() => server.close(force: true));
      }
    }, _RealHttpOverrides());
  });

  testWidgets(
    'new source preloads TV, movies and series before opening Home',
    (tester) => exercisePreload(tester, failMovies: false),
  );

  testWidgets(
    'onboarding waits for the initial guide after the three catalogs finish',
    (tester) => exercisePreload(tester, failMovies: false, gateEpg: true),
  );

  testWidgets(
    'a failed initial guide still opens Home with the catalogs cached',
    (tester) => exercisePreload(
      tester,
      failMovies: false,
      gateEpg: true,
      failEpg: true,
    ),
  );

  testWidgets(
    'disposing Home during the initial guide does not publish late state',
    (tester) => exercisePreload(
      tester,
      failMovies: false,
      gateEpg: true,
      disposeDuringEpg: true,
    ),
  );

  testWidgets(
    'failed TV channels do not block setup with saved VOD catalogs',
    (tester) => exercisePreload(tester, failMovies: false, failLive: true),
  );

  testWidgets(
    'one failed catalog still opens Home with the others cached',
    (tester) => exercisePreload(tester, failMovies: true),
  );

  testWidgets(
    'onboarding caches every media page and restarts offline without requests',
    (tester) => exercisePreload(
      tester,
      failMovies: false,
      catalogItems: 31,
      restartOffline: true,
    ),
  );

  testWidgets(
    'movie catalog recovers within the source transport retry budget',
    (tester) => exercisePreload(
      tester,
      failMovies: false,
      transientMovieFailures: 1,
    ),
  );

  testWidgets(
    'source connection recovers within the source transport retry budget',
    (tester) => exercisePreload(
      tester,
      failMovies: false,
      transientConnectFailures: 1,
    ),
  );

  testWidgets(
    'bad source URL is explained and can be corrected before catalogs load',
    (tester) =>
        exercisePreload(tester, failMovies: false, startWithBadUrl: true),
  );
}

void _expectRetryPauses(List<DateTime> requestTimes) {
  expect(requestTimes.length, greaterThanOrEqualTo(2));
  // Xtream owns one short transport retry. Home does not replay setup.
  expect(
    [
      for (var i = 1; i < requestTimes.length; i++)
        requestTimes[i].difference(requestTimes[i - 1]),
    ],
    contains(greaterThanOrEqualTo(const Duration(milliseconds: 550))),
  );
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  for (var frame = 0; frame < 1000; frame++) {
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(
    ready(),
    isTrue,
    reason: 'The preload did not reach the expected state',
  );
}

Completer<void> _nextLog(bool Function(DiagnosticsEntry) matches) {
  final result = Completer<void>();
  final log = DiagnosticsLog.instance;
  late VoidCallback listener;
  listener = () {
    if (log.entries.isEmpty || !matches(log.entries.last)) return;
    log.removeListener(listener);
    result.complete();
  };
  log.addListener(listener);
  addTearDown(() => log.removeListener(listener));
  return result;
}

class _XtreamFixture {
  final HttpServer server;
  final bool failMovies;
  final bool gateValidation;
  final int transientMovieFailures;
  final int transientConnectFailures;
  final int catalogItems;
  final bool gateEpg;
  final bool failEpg;
  final bool failLive;
  final DateTime Function() now;
  final validationStarted = Completer<void>();
  final validationGate = Completer<void>();
  final liveStarted = Completer<void>();
  final movieStarted = Completer<void>();
  final seriesStarted = Completer<void>();
  final movieGate = Completer<void>();
  final seriesGate = Completer<void>();
  final movieResponded = Completer<void>();
  final epgStarted = Completer<void>();
  final epgGate = Completer<void>();
  final Map<String, int> requests = {};
  final Map<String, List<DateTime>> requestTimes = {};
  bool _closed = false;
  bool offline = false;
  bool rejectAuthentication = false;

  _XtreamFixture._(
    this.server, {
    required this.failMovies,
    required this.gateValidation,
    required this.transientMovieFailures,
    required this.transientConnectFailures,
    required this.catalogItems,
    required this.gateEpg,
    required this.failEpg,
    required this.failLive,
    required this.now,
  }) {
    server.listen(_respond);
  }

  static Future<_XtreamFixture> start({
    required bool failMovies,
    bool gateValidation = false,
    int transientMovieFailures = 0,
    int transientConnectFailures = 0,
    int catalogItems = 1,
    bool gateEpg = false,
    bool failEpg = false,
    bool failLive = false,
    required DateTime Function() now,
  }) async => _XtreamFixture._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    failMovies: failMovies,
    gateValidation: gateValidation,
    transientMovieFailures: transientMovieFailures,
    transientConnectFailures: transientConnectFailures,
    catalogItems: catalogItems,
    gateEpg: gateEpg,
    failEpg: failEpg,
    failLive: failLive,
    now: now,
  );

  void _recordRequest(String action) {
    requests.update(action, (count) => count + 1, ifAbsent: () => 1);
    requestTimes.putIfAbsent(action, () => []).add(now());
  }

  Future<void> _respond(HttpRequest request) async {
    if (offline) {
      _recordRequest('offline');
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    if (request.uri.path.startsWith('/bad/')) {
      _recordRequest('invalid-url');
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    if (request.uri.path == '/xmltv.php') {
      _recordRequest('xmltv');
      if (!epgStarted.isCompleted) epgStarted.complete();
      if (gateEpg) await epgGate.future;
      String timestamp(DateTime value) =>
          '${value.toUtc().toIso8601String().substring(0, 19).replaceAll(RegExp(r'[-:T]'), '')} +0000';
      final current = now();
      final guide = failEpg
          ? '<tv><programme></tv>'
          : gateEpg
          ? '<?xml version="1.0"?><tv>'
                '<channel id="fixture.tv"><display-name>Fixture TV</display-name></channel>'
                '<programme channel="fixture.tv" '
                'start="${timestamp(current.subtract(const Duration(hours: 1)))}" '
                'stop="${timestamp(current.add(const Duration(hours: 1)))}">'
                '<title>Fixture programme</title></programme></tv>'
          : '<?xml version="1.0"?><tv></tv>';
      request.response
        ..headers.contentType = ContentType('application', 'xml')
        ..write(guide);
      await request.response.close();
      return;
    }

    final action = request.uri.queryParameters['action'] ?? 'connect';
    _recordRequest(action);
    Object body;
    switch (action) {
      case 'connect':
        if (!validationStarted.isCompleted) {
          validationStarted.complete();
          if (gateValidation) await validationGate.future;
        }
        if (requests[action]! <= transientConnectFailures) {
          request.response.statusCode = HttpStatus.internalServerError;
        }
        body = {
          'user_info': {'auth': rejectAuthentication ? 0 : 1},
        };
      case 'get_live_categories':
        body = [
          {'category_id': 'live', 'category_name': 'TV'},
        ];
      case 'get_live_streams':
        if (!liveStarted.isCompleted) liveStarted.complete();
        if (failLive) {
          request.response.statusCode = HttpStatus.internalServerError;
        }
        body = [
          {
            'stream_id': 101,
            'name': 'Fixture TV',
            'category_id': 'live',
            'epg_channel_id': 'fixture.tv',
          },
        ];
      case 'get_vod_categories':
        body = [
          {'category_id': 'movies', 'category_name': 'Movies'},
        ];
      case 'get_series_categories':
        body = [
          {'category_id': 'series', 'category_name': 'Series'},
        ];
      case 'get_vod_streams':
        if (!movieStarted.isCompleted) movieStarted.complete();
        await movieGate.future;
        if (failMovies || requests[action]! <= transientMovieFailures) {
          request.response.statusCode = HttpStatus.internalServerError;
        }
        body = [
          for (var index = 0; index < catalogItems; index++)
            {
              'stream_id': 201 + index,
              'name': _catalogTitles('movie', catalogItems)[index],
              'category_id': 'movies',
            },
        ];
      case 'get_series':
        if (!seriesStarted.isCompleted) seriesStarted.complete();
        await seriesGate.future;
        body = [
          for (var index = 0; index < catalogItems; index++)
            {
              'series_id': 301 + index,
              'name': _catalogTitles('series', catalogItems)[index],
              'category_id': 'series',
            },
        ];
      default:
        body = [];
    }
    request.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
    if (action == 'get_vod_streams' && !movieResponded.isCompleted) {
      movieResponded.complete();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!validationGate.isCompleted) validationGate.complete();
    if (!movieGate.isCompleted) movieGate.complete();
    if (!seriesGate.isCompleted) seriesGate.complete();
    if (!epgGate.isCompleted) epgGate.complete();
    await server.close(force: true);
  }
}

class _RealHttpOverrides extends HttpOverrides {}

List<String> _catalogTitles(String kind, int count) => [
  for (var index = 0; index < count; index++)
    'Fixture $kind${index == 0 ? '' : ' ${index + 1}'}',
];
