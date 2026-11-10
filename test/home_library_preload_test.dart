import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/diagnostics_log.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/channel_list_screen.dart';
import 'package:iptvs/screens/home_shell.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/widgets/tv_text_field.dart';

const _sourceId = 'new-onboarding-source';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late AppDatabase db;
  late SourceStore store;

  setUp(() async {
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
        now: tester.binding.clock.now,
      ),
    );
    if (fixture == null) throw StateError('Could not start Xtream fixture');
    addTearDown(() => tester.runAsync(fixture.close));
    final validHost = 'http://127.0.0.1:${fixture.server.port}';
    final savedHost = startWithBadUrl ? '$validHost/bad' : validHost;

    // Saving a source with an empty database is the state immediately after
    // onboarding's first-source editor returns to Home.
    await store.save(
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
          expect(fixture.requests['invalid-url'], 6);
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
        await _pumpUntil(
          tester,
          () =>
              fixture.liveStarted.isCompleted &&
              fixture.movieStarted.isCompleted &&
              fixture.seriesStarted.isCompleted &&
              liveReady.isCompleted,
        );
        if (transientConnectFailures > 0) {
          _expectRetryPauses(fixture.requestTimes['connect']!);
        }

        expect(find.text('Preparing your library'), findsOneWidget);
        expect(find.byType(ChannelListScreen), findsNothing);
        expect(
          (await read(() => db.readChannels(_sourceId)))
              .map((channel) => channel.name),
          ['Fixture TV'],
        );
        expect(
          await read(() => db.mediaSyncState(_sourceId, ContentKind.movie)),
          isNull,
        );
        expect(
          await read(() => db.mediaSyncState(_sourceId, ContentKind.series)),
          isNull,
        );

        fixture.movieGate.complete();
        await _pumpUntil(tester, () => fixture.movieResponded.isCompleted);
        // A fast or failed movie request cannot finish onboarding while the
        // series catalog still has an outstanding response.
        expect(find.text('Preparing your library'), findsOneWidget);
        expect(find.byType(ChannelListScreen), findsNothing);

        fixture.seriesGate.complete();
        await _pumpUntil(
          tester,
          () =>
              preloadReady.isCompleted &&
              find.byType(ChannelListScreen).evaluate().isNotEmpty,
        );

        expect(find.byType(ChannelListScreen), findsOneWidget);
        expect(find.text('Preparing your library'), findsNothing);
        expect(await read(() => db.lastSynced(_sourceId)), isNotNull);
        expect(
          await read(() => db.mediaSyncState(_sourceId, ContentKind.series)),
          isNotNull,
        );
        expect(
          (await read(
            () => db.readMediaItems(_sourceId, ContentKind.series),
          )).map((item) => item.title),
          ['Fixture series'],
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
            (await read(
              () => db.readMediaItems(_sourceId, ContentKind.movie),
            )).map((item) => item.title),
            ['Fixture movie'],
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
          expect((await cached).every((snapshot) => snapshot.fromCache), isTrue);
        }

        expect(fixture.requests['get_live_streams'], 1);
        expect(
          fixture.requests['get_vod_streams'],
          failMovies ? 6 : transientMovieFailures + 1,
        );
        expect(fixture.requests['get_series'], 1);
        if (failMovies || transientMovieFailures > 0) {
          _expectRetryPauses(fixture.requestTimes['get_vod_streams']!);
        }
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
    'new source preloads TV, movies and series before opening Home',
    (tester) => exercisePreload(tester, failMovies: false),
  );

  testWidgets(
    'one failed catalog still opens Home with the others cached',
    (tester) => exercisePreload(tester, failMovies: true),
  );

  testWidgets(
    'movie catalog recovers on the third preload attempt',
    (tester) => exercisePreload(
      tester,
      failMovies: false,
      transientMovieFailures: 4,
    ),
  );

  testWidgets(
    'source connection recovers on the third onboarding attempt',
    (tester) => exercisePreload(
      tester,
      failMovies: false,
      transientConnectFailures: 4,
    ),
  );

  testWidgets(
    'bad source URL is explained and can be corrected before catalogs load',
    (tester) =>
        exercisePreload(tester, failMovies: false, startWithBadUrl: true),
  );
}

void _expectRetryPauses(List<DateTime> requestTimes) {
  expect(requestTimes.length, greaterThanOrEqualTo(5));
  // Xtream retries each HTTP request once internally. The next full
  // onboarding attempt must wait a second after that second failed request.
  for (final nextAttempt in [2, 4]) {
    expect(
      requestTimes[nextAttempt].difference(requestTimes[nextAttempt - 1]),
      greaterThanOrEqualTo(const Duration(seconds: 1)),
    );
  }
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
  final DateTime Function() now;
  final validationStarted = Completer<void>();
  final validationGate = Completer<void>();
  final liveStarted = Completer<void>();
  final movieStarted = Completer<void>();
  final seriesStarted = Completer<void>();
  final movieGate = Completer<void>();
  final seriesGate = Completer<void>();
  final movieResponded = Completer<void>();
  final Map<String, int> requests = {};
  final Map<String, List<DateTime>> requestTimes = {};
  bool _closed = false;

  _XtreamFixture._(
    this.server, {
    required this.failMovies,
    required this.gateValidation,
    required this.transientMovieFailures,
    required this.transientConnectFailures,
    required this.now,
  }) {
    server.listen(_respond);
  }

  static Future<_XtreamFixture> start({
    required bool failMovies,
    bool gateValidation = false,
    int transientMovieFailures = 0,
    int transientConnectFailures = 0,
    required DateTime Function() now,
  }) async => _XtreamFixture._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    failMovies: failMovies,
    gateValidation: gateValidation,
    transientMovieFailures: transientMovieFailures,
    transientConnectFailures: transientConnectFailures,
    now: now,
  );

  void _recordRequest(String action) {
    requests.update(action, (count) => count + 1, ifAbsent: () => 1);
    requestTimes.putIfAbsent(action, () => []).add(now());
  }

  Future<void> _respond(HttpRequest request) async {
    if (request.uri.path.startsWith('/bad/')) {
      _recordRequest('invalid-url');
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    if (request.uri.path == '/xmltv.php') {
      request.response
        ..headers.contentType = ContentType('application', 'xml')
        ..write('<?xml version="1.0"?><tv></tv>');
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
          'user_info': {'auth': 1},
        };
      case 'get_live_categories':
        body = [
          {'category_id': 'live', 'category_name': 'TV'},
        ];
      case 'get_live_streams':
        if (!liveStarted.isCompleted) liveStarted.complete();
        body = [
          {'stream_id': 101, 'name': 'Fixture TV', 'category_id': 'live'},
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
          {'stream_id': 201, 'name': 'Fixture movie', 'category_id': 'movies'},
        ];
      case 'get_series':
        if (!seriesStarted.isCompleted) seriesStarted.complete();
        await seriesGate.future;
        body = [
          {'series_id': 301, 'name': 'Fixture series', 'category_id': 'series'},
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
    await server.close(force: true);
  }
}

class _RealHttpOverrides extends HttpOverrides {}
