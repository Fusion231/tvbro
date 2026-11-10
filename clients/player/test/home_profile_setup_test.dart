import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/local_profile_store.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/channel_list_screen.dart';
import 'package:iptvs/screens/home_shell.dart';
import 'package:iptvs/screens/live_tab_view.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/widgets/tv_text_field.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late AppDatabase db;
  late SourceStore sourceStore;
  const profileStore = LocalProfileStore();

  setUp(() async {
    debugDisableNetworkChannelLogos = true;
    FlutterSecureStorage.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('iptvs_home_profile_setup');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
    sourceStore = SourceStore();
  });

  tearDown(() async {
    debugDisableNetworkChannelLogos = false;
    await db.epgIngest.cancelAndWait();
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<(LocalProfile, LocalProfile)> seedCanceledSetup() async {
    const existingSource = SourceConfig(
      id: 'existing-source',
      kind: SourceKind.demo,
      label: 'Existing Demo',
      fields: {},
    );
    final existing = await profileStore.createProfile(
      'Existing',
      0,
      snapshot: ProfileSnapshot(
        sourcesJson: [existingSource.toJson()],
        activeSourceId: existingSource.id,
      ),
    );
    await profileStore.setActive(existing.id);
    await sourceStore.setAll([existingSource]);

    // This is the persisted state left by backing out of a new profile's
    // source/Demo choice: that profile is active, its own snapshot is still
    // empty, and the previous profile's live source list has been cleared.
    final pending = await profileStore.createProfile(
      'Kids',
      1,
      snapshot: const ProfileSnapshot(),
    );
    await sourceStore.setAll(const []);
    await profileStore.setActive(pending.id);
    return (existing, pending);
  }

  Future<void> pumpUntil(
    WidgetTester tester,
    Finder finder, {
    int maxFrames = 100,
  }) async {
    for (var i = 0; i < maxFrames; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(finder, findsOneWidget);
  }

  Future<void> showHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: HomeShell(db: db, store: sourceStore)),
    );
    await pumpUntil(tester, find.text('Set up Kids'));
  }

  testWidgets(
    'canceled setup resumes in Home and Demo is saved only to that profile',
    (tester) async {
      final (existing, pending) = await seedCanceledSetup();
      await showHome(tester);

      expect(find.text('Add an IPTV source'), findsOneWidget);
      expect(find.text('Try Demo streams'), findsOneWidget);

      // Canceling the first-source editor must leave the profile incomplete so
      // Home can offer the choice again.
      await tester.tap(find.text('Add an IPTV source'));
      await pumpUntil(tester, find.text('Add source'));
      await tester.pageBack();
      await pumpUntil(tester, find.text('Set up Kids'));
      // The prompt becomes visible underneath the editor during its reverse
      // transition. Wait for the route to finish and the choice to receive hit
      // tests before activating it.
      await tester.pump();
      final demoChoice = find.text('Try Demo streams');
      await pumpUntil(tester, demoChoice.hitTestable());

      await tester.tap(demoChoice.hitTestable());
      await pumpUntil(tester, find.byType(ChannelListScreen));
      await tester.ensureVisible(find.byKey(const ValueKey('home-live')));
      await pumpUntil(
        tester,
        find.byKey(const ValueKey('home-live')).hitTestable(),
      );
      await tester.tap(find.byKey(const ValueKey('home-live')).hitTestable());
      await pumpUntil(tester, find.text('Big Buck Bunny (H.264)'));

      final profiles = await profileStore.loadAll();
      final updatedPending = profiles.singleWhere((p) => p.id == pending.id);
      final unchangedExisting = profiles.singleWhere(
        (p) => p.id == existing.id,
      );
      expect(updatedPending.snapshot.sourcesJson, hasLength(1));
      expect(updatedPending.snapshot.sourcesJson.single['id'], 'demo');
      expect(updatedPending.snapshot.activeSourceId, 'demo');
      expect(
        unchangedExisting.snapshot.sourcesJson.single['id'],
        'existing-source',
      );
      expect((await sourceStore.list()).map((source) => source.id), ['demo']);
      expect(await sourceStore.activeId(), 'demo');

      await tester.pumpWidget(const SizedBox());
      var epgStopped = false;
      final stopEpg = db.epgIngest.cancelAndWait().whenComplete(
        () => epgStopped = true,
      );
      for (var frame = 0; !epgStopped && frame < 100; frame++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(epgStopped, isTrue);
      await stopEpg;
    },
  );

  testWidgets(
    'first M3U source from resumed setup is snapshotted to the pending profile',
    (tester) async {
      final (existing, pending) = await seedCanceledSetup();
      final server = await tester.runAsync(() async {
        final server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        server.listen((request) async {
          request.response
            ..headers.contentType = ContentType.text
            ..write(
              '#EXTM3U\n'
              '#EXTINF:-1 tvg-id="fixture",Fixture channel\n'
              'http://stream.invalid/fixture.ts\n',
            );
          await request.response.close();
        });
        return server;
      });
      if (server == null) throw StateError('Could not start M3U fixture');
      var serverClosed = false;
      Future<void> closeServer() async {
        if (serverClosed) return;
        serverClosed = true;
        await tester.runAsync(() => server.close(force: true));
      }
      addTearDown(closeServer);

      await HttpOverrides.runWithHttpOverrides(() async {
        await showHome(tester);
        await tester.tap(find.text('Add an IPTV source'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Add source'), findsOneWidget);

        await tester.tap(find.byType(DropdownButtonFormField<SourceKind>));
        await tester.pump();
        await tester.tap(find.text('M3U').last);
        await tester.pump();

        final playlistUrl = 'http://127.0.0.1:${server.port}/list.m3u';
        final playlistField = find.byWidgetPredicate(
          (widget) => widget is TvTextField && widget.label == 'Playlist URL',
        );
        tester.widget<TvTextField>(playlistField).controller.text =
            playlistUrl;
        await tester.pump();
        await tester.tap(find.text('Save source'));

        await pumpUntil(tester, find.byKey(const ValueKey('home-live')));
        await tester.ensureVisible(find.byKey(const ValueKey('home-live')));
        await pumpUntil(
          tester,
          find.byKey(const ValueKey('home-live')).hitTestable(),
        );
        await tester.tap(find.byKey(const ValueKey('home-live')).hitTestable());
        await pumpUntil(tester, find.text('Fixture channel'));

        final savedSources = await sourceStore.list();
        expect(savedSources, hasLength(1));
        final saved = savedSources.single;
        expect(saved.kind, SourceKind.m3u);
        expect(saved.fields['playlistUrl'], playlistUrl);
        expect(await sourceStore.activeId(), saved.id);

        final profiles = await profileStore.loadAll();
        final updatedPending = profiles.singleWhere((p) => p.id == pending.id);
        final unchangedExisting = profiles.singleWhere(
          (p) => p.id == existing.id,
        );
        expect(updatedPending.snapshot.sourcesJson, hasLength(1));
        expect(updatedPending.snapshot.sourcesJson.single['id'], saved.id);
        expect(
          updatedPending.snapshot.sourcesJson.single['fields']['playlistUrl'],
          playlistUrl,
        );
        expect(
          unchangedExisting.snapshot.sourcesJson.single['id'],
          'existing-source',
        );

        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => db.epgIngest.cancelAndWait());
        await closeServer();
      }, _RealHttpOverrides());
    },
  );
}

/// Uses real HTTP for the local M3U fixture instead of Flutter test's default
/// client, which deliberately returns status 400 for every request.
class _RealHttpOverrides extends HttpOverrides {}
