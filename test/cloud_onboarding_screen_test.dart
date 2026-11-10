import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/cloud_config.dart';
import 'package:iptvs/data/cloud_sync.dart';
import 'package:iptvs/data/local_profile_store.dart';
import 'package:iptvs/data/metadata_config.dart';
import 'package:iptvs/data/profile_pin.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/cloud_sync_screen.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/widgets/pairing_qr.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late Directory directory;
  late AppDatabase db;
  late SourceStore store;
  late _SetupSync sync;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('iptvs_cloud_setup');
    db = await AppDatabase.openAt('${directory.path}/test.db');
    store = SourceStore();
    sync = _SetupSync();
  });

  tearDown(() async {
    await sync.remote.close();
    await db.close();
    directory.deleteSync(recursive: true);
  });

  Future<void> openSetup(
    WidgetTester tester, {
    VoidCallback? onDone,
    bool onboarding = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                final result = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => CloudSyncScreen(
                      store: store,
                      db: db,
                      sync: sync,
                      onboarding: onboarding,
                    ),
                  ),
                );
                if (result == true) onDone?.call();
              },
              child: const Text('Setup'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Setup'));
    await tester.pumpAndSettle();
  }

  Future<void> refresh(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Refresh playlists'));
    await tester.tap(find.text('Refresh playlists'));
    await tester.pumpAndSettle();
  }

  Future<void> chooseProfile(WidgetTester tester, {String id = 'cloud'}) async {
    final profile = find.byKey(ValueKey('cloud-profile-$id'));
    await tester.ensureVisible(profile);
    await tester.tap(profile);
    await tester.pumpAndSettle();
  }

  testWidgets('TV onboarding shows profile choice immediately', (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    sync.profiles = [
      for (var i = 0; i < 10; i++)
        CloudProfile(id: 'cloud-$i', name: 'Profile $i', position: i),
    ];
    await openSetup(tester);
    expect(
      find.byKey(const ValueKey('cloud-profile-cloud-0')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unpaired onboarding shows QR and typed code fallback', (
    tester,
  ) async {
    sync.paired = false;
    await openSetup(tester);
    expect(find.byType(PairingQrView), findsOneWidget);
    expect(
      tester.widget<PairingQrView>(find.byType(PairingQrView)).link,
      pairingPanelLink(CloudConfig.panelUrl, 'ABCD2345', language: 'en'),
    );
    expect(find.text('ABCD2345'), findsOneWidget);
    expect(find.text('Continue'), findsNothing);
    expect(sync.pulls, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'refresh waits for a profile choice then downloads it automatically',
    (tester) async {
      const profiles = LocalProfileStore();
      final local = await profiles.createProfile('Later', 0);
      await profiles.setActive(local.id);
      var completed = false;
      await openSetup(tester, onDone: () => completed = true);
      expect(find.text('Continue'), findsNothing);
      expect(sync.previews, 0);

      sync.sources = [_playlist];
      await refresh(tester);
      expect(find.byIcon(Icons.radio_button_checked), findsNothing);
      expect(sync.previews, 0);
      expect(await store.list(), isEmpty);
      expect(sync.selected, isNull);
      expect(sync.pulls, 0);
      expect(await profiles.activeId(), local.id);
      expect(completed, isFalse);

      await chooseProfile(tester);
      expect(completed, isTrue);
      expect(sync.selected, 'cloud');
      expect(sync.pulls, 1);
      expect(sync.metadataPulls, 1);
      expect(sync.favoritePulls, 1);
      expect(sync.playbackPulls, 1);
      expect((await store.metadataConfig()).autoEnrich, isFalse);
      expect(await profiles.activeId(), isNull);
      expect((await store.activeConfig())?.id, _playlist.id);
      expect((await profiles.loadAll()).single.snapshot.sourcesJson, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('back before choosing a profile preserves local setup', (
    tester,
  ) async {
    const profiles = LocalProfileStore();
    final local = await profiles.createProfile('Later', 0);
    await profiles.setActive(local.id);
    await store.setAll([_localSource]);
    sync.sources = [_playlist];
    await openSetup(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect((await store.activeConfig())?.id, _localSource.id);
    expect(await profiles.activeId(), local.id);
    expect(sync.selected, isNull);
    expect(sync.previews, 0);
    expect(sync.pulls, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'explicit cloud download parks local data before replacing sources',
    (tester) async {
      const profiles = LocalProfileStore();
      const localSource = SourceConfig(
        id: 'local-source',
        kind: SourceKind.demo,
        label: 'Local',
        fields: {},
      );
      final local = await profiles.createProfile('Local', 0);
      await profiles.setActive(local.id);
      await store.setAll([localSource]);
      sync.sources = [_playlist];
      await openSetup(tester, onboarding: false);
      await tester.tap(find.byKey(const ValueKey('sync-download')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('transfer-submit')));
      await tester.tap(find.byKey(const ValueKey('transfer-submit')));
      await tester.pumpAndSettle();
      expect((await store.list()).map((source) => source.id), [_playlist.id]);
      expect(await profiles.activeId(), isNull);
      final parked = (await profiles.loadAll()).single.snapshot;
      expect(parked.sourcesJson.single['id'], localSource.id);
      expect(parked.activeSourceId, localSource.id);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('pairing waits for a profile choice before downloading', (
    tester,
  ) async {
    sync.paired = false;
    sync.sources = [_playlist];
    var completed = false;
    await openSetup(tester, onDone: () => completed = true);
    sync.paired = true;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byType(PairingQrView), findsNothing);
    expect(find.byKey(const ValueKey('cloud-profile-cloud')), findsOneWidget);
    expect(sync.pairingChecks, 1);
    expect(sync.previews, 0);
    expect(sync.pulls, 0);
    expect(completed, isFalse);

    await chooseProfile(tester);
    expect(completed, isTrue);
    expect(sync.pulls, 1);
    expect((await store.activeConfig())?.id, _playlist.id);
    await tester.pumpWidget(const SizedBox());
  });

  for (final onboarding in [false, true]) {
    testWidgets(
      'first pairing imports the sole profile automatically (onboarding: $onboarding)',
      (tester) async {
        sync.paired = false;
        sync.profiles = [sync.profiles.first];
        sync.sources = [_playlist];
        var completed = false;
        await openSetup(
          tester,
          onboarding: onboarding,
          onDone: () => completed = true,
        );
        sync.paired = true;
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(completed, isTrue);
        expect(sync.selected, 'cloud');
        expect(sync.pulls, 1);
        expect(sync.metadataPulls, 1);
        expect(sync.favoritePulls, 1);
        expect(sync.playbackPulls, 1);
        expect((await store.activeConfig())?.id, _playlist.id);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'pairing a configured device keeps the upload and download choices',
    (tester) async {
      sync.paired = false;
      sync.profiles = [sync.profiles.first];
      sync.sources = [_playlist];
      await store.setAll([_localSource]);
      await openSetup(tester, onboarding: false);
      sync.paired = true;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(sync.pulls, 0);
      expect(find.byKey(const ValueKey('sync-download')), findsOneWidget);
      expect(find.byKey(const ValueKey('sync-upload')), findsOneWidget);
      expect((await store.list()).single.id, _localSource.id);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('multiple profiles wait for choice and download the second', (
    tester,
  ) async {
    sync.profiles = [
      const CloudProfile(id: 'first', name: 'First', position: 0),
      const CloudProfile(id: 'second', name: 'Second', position: 1),
    ];
    sync.selected = 'first';
    sync.sources = [_playlist];
    await openSetup(tester);
    expect(find.byIcon(Icons.radio_button_checked), findsNothing);
    expect(sync.previews, 0);
    expect(sync.pulls, 0);
    expect(sync.selected, 'first');

    await chooseProfile(tester, id: 'second');
    expect(sync.selected, 'second');
    expect(sync.pulls, 1);
    expect((await store.activeConfig())?.id, _playlist.id);
    expect(find.byType(CloudSyncScreen), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a selected empty profile imports when its playlists arrive', (
    tester,
  ) async {
    var completed = false;
    await openSetup(tester, onDone: () => completed = true);
    await chooseProfile(tester);
    expect(sync.previews, 1);
    expect(sync.pulls, 0);
    expect(completed, isFalse);

    sync.sources = [_playlist];
    sync.remote.add(null);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(sync.pulls, 1);
    expect((await store.activeConfig())?.id, _playlist.id);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('subscriber setup also waits for explicit profile selection', (
    tester,
  ) async {
    sync.supported = true;
    sync.sources = [_playlist];
    var completed = false;
    await openSetup(tester, onDone: () => completed = true);
    expect(find.text('Continue'), findsNothing);
    expect(sync.previews, 0);
    expect(sync.pulls, 0);
    expect(completed, isFalse);

    await chooseProfile(tester);
    expect(completed, isTrue);
    expect((await store.activeConfig())?.id, _playlist.id);
    expect(sync.metadataPulls, 1);
    expect(sync.favoritePulls, 1);
    expect(sync.playbackPulls, 1);
    await tester.pumpWidget(const SizedBox());
  });

  for (final retryWithRefresh in [false, true]) {
    testWidgets(
      'failed download restores local data and retries with ${retryWithRefresh ? 'Refresh' : 'profile choice'}',
      (tester) async {
        const profiles = LocalProfileStore();
        final local = await profiles.createProfile('Later', 0);
        await profiles.setActive(local.id);
        await store.setAll([_localSource]);
        sync.selected = 'previous';
        sync.sources = [_playlist];
        sync.failPull = true;
        var completed = false;
        await openSetup(tester, onDone: () => completed = true);

        await chooseProfile(tester);
        expect((await store.list()).single.id, _localSource.id);
        expect(await store.activeId(), _localSource.id);
        expect(await profiles.activeId(), local.id);
        expect(await profiles.ownerless(), isFalse);
        expect(sync.selected, 'previous');
        expect(sync.pulls, 1);
        expect(completed, isFalse);
        expect(find.byType(CloudSyncScreen), findsOneWidget);

        sync.failPull = false;
        if (retryWithRefresh) {
          await refresh(tester);
        } else {
          await chooseProfile(tester);
        }
        expect(completed, isTrue);
        expect(sync.selected, 'cloud');
        expect(sync.pulls, 2);
        expect((await store.activeConfig())?.id, _playlist.id);
        expect(await profiles.activeId(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('failed first download remains incomplete until retry succeeds', (
    tester,
  ) async {
    const profiles = LocalProfileStore();
    sync.sources = [_playlist];
    sync.failPull = true;
    var completed = false;
    await openSetup(tester, onDone: () => completed = true);

    await chooseProfile(tester);
    expect(sync.selected, 'cloud');
    expect(await store.list(), isEmpty);
    expect(await profiles.activeId(), isNull);
    expect(await profiles.ownerless(), isTrue);
    expect(completed, isFalse);

    sync.failPull = false;
    await chooseProfile(tester);
    expect(completed, isTrue);
    expect(await profiles.ownerless(), isFalse);
    expect((await store.activeConfig())?.id, _playlist.id);
    await tester.pumpWidget(const SizedBox());
  });

  for (final missingCredentials in [false, true]) {
    testWidgets(
      '${missingCredentials ? 'missing credentials' : 'empty profile'} waits after selection',
      (tester) async {
        sync.sources = missingCredentials
            ? [_playlist.copyWith(fields: {})]
            : [];
        await openSetup(tester);
        await chooseProfile(tester);
        expect(find.text('Continue'), findsNothing);
        expect(find.byType(CloudSyncScreen), findsOneWidget);
        expect(sync.previews, 1);
        expect(sync.pulls, 0);
        expect(sync.selected, isNull);
        expect(await store.list(), isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('automatic sole profile import still waits for its PIN', (
    tester,
  ) async {
    sync.profiles = [
      CloudProfile(
        id: 'cloud',
        name: 'Locked',
        position: 0,
        pin: hashProfilePin('1234'),
      ),
    ];
    sync.sources = [_playlist];
    var completed = false;
    await openSetup(tester, onDone: () => completed = true);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(sync.previews, 0);
    expect(sync.favoritePulls, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(completed, isFalse);
    expect(sync.pulls, 0);
    expect(await store.list(), isEmpty);
    expect(await const LocalProfileStore().ownerless(), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('locked cloud profile requires PIN before playlist preview', (
    tester,
  ) async {
    const profiles = LocalProfileStore();
    final local = await profiles.createProfile('Local', 0);
    await profiles.setActive(local.id);
    await store.setAll([_localSource]);
    sync.profiles = [
      CloudProfile(
        id: 'cloud',
        name: 'Locked',
        position: 0,
        pin: hashProfilePin('1234'),
      ),
      const CloudProfile(id: 'other', name: 'Other', position: 1),
    ];
    sync.sources = [_playlist];
    await openSetup(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(sync.previews, 0);

    await chooseProfile(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(sync.previews, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(sync.selected, isNull);
    expect(sync.pulls, 0);
    expect((await store.activeConfig())?.id, _localSource.id);
    expect(await profiles.activeId(), local.id);
    expect(await profiles.ownerless(), isFalse);
    await tester.pumpWidget(const SizedBox());
  });
}

const _playlist = SourceConfig(
  id: 'playlist',
  kind: SourceKind.m3u,
  label: 'Playlist',
  fields: {'playlistUrl': 'https://example.invalid/list.m3u'},
);

const _localSource = SourceConfig(
  id: 'local-source',
  kind: SourceKind.demo,
  label: 'Local',
  fields: {},
);

class _SetupSync extends CloudSync {
  _SetupSync()
    : super(client: SupabaseClient('https://example.invalid', 'test'));

  List<CloudProfile> profiles = [
    const CloudProfile(id: 'cloud', name: 'Cloud', position: 0),
    const CloudProfile(id: 'other', name: 'Other', position: 1),
  ];
  List<SourceConfig> sources = [];
  String? selected;
  int pulls = 0;
  int previews = 0;
  int metadataPulls = 0;
  int favoritePulls = 0;
  int playbackPulls = 0;
  int pairingChecks = 0;
  bool paired = true;
  bool failPull = false;
  bool supported = false;
  final remote = StreamController<void>.broadcast();

  @override
  bool get hasSession => true;
  @override
  String get deviceId => 'device';

  @override
  Future<void> ensureAnonSession() async {}
  @override
  Future<bool> isPaired() async => paired;
  @override
  Future<bool> pairingStatus(String code) async {
    pairingChecks++;
    return paired;
  }

  @override
  Future<PairingCode> requestPairingCode({String? label}) async =>
      PairingCode('ABCD2345', DateTime.now().add(const Duration(minutes: 10)));
  @override
  Future<SupporterStatus> supporterStatus() async => SupporterStatus(
    supported: supported,
    validUntil: DateTime.now().add(const Duration(days: 1)),
  );
  @override
  Stream<void> observeProfileChanges(String profileId) => remote.stream;
  @override
  Future<List<CloudProfile>> listProfiles() async => profiles;
  @override
  Future<CloudCryptoState> cryptoState(String profileId) async =>
      const CloudCryptoState(status: CloudCryptoStatus.off);
  @override
  Future<List<SourceConfig>> previewSources(
    SourceStore store,
    String profileId,
  ) async {
    previews++;
    return sources;
  }

  @override
  Future<void> setProfile(String profileId) async => selected = profileId;
  @override
  Future<String?> activeProfileId() async => selected;
  @override
  Future<String?> cachedProfileId() async => selected;
  @override
  Future<CloudRevision?> profileRevision(String profileId) async =>
      CloudRevision(profileId: profileId);
  @override
  Future<int> pullSources(
    SourceStore store,
    String profileId, {
    bool preserveLocalChanges = false,
  }) async {
    pulls++;
    await store.setAll(sources);
    if (failPull) throw StateError('Pull failed');
    return sources.length;
  }

  @override
  Future<bool> pullMetadata(
    SourceStore store,
    String profileId, {
    bool preserveLocalChanges = false,
  }) async {
    metadataPulls++;
    await store.saveMetadataConfig(const MetadataConfig(autoEnrich: false));
    return true;
  }

  @override
  Future<void> pullFavorites(SourceStore store, String profileId) async {
    favoritePulls++;
  }

  @override
  Future<void> pullPlaybackPositions(
    SourceStore store,
    String profileId,
  ) async {
    playbackPulls++;
  }

  @override
  Future<Set<String>> managedSourceIds() async => {};
  @override
  Future<void> setManagedSourceIds(Set<String> ids) async {}
}
