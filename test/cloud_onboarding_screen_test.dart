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

  testWidgets('unpaired onboarding shows QR and typed code fallback', (
    tester,
  ) async {
    sync.paired = false;
    await openSetup(tester);
    expect(find.byType(PairingQrView), findsOneWidget);
    expect(find.text('ABCD2345'), findsOneWidget);
    expect(find.text('Continue'), findsNothing);
    expect(sync.pulls, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'refresh previews later playlists; Continue commits cloud profile',
    (tester) async {
      const profiles = LocalProfileStore();
      final local = await profiles.createProfile('Later', 0);
      await profiles.setActive(local.id);
      var completed = false;
      await openSetup(tester, onDone: () => completed = true);
      final continueButton = find.widgetWithText(FilledButton, 'Continue');
      expect(tester.widget<FilledButton>(continueButton).onPressed, isNull);

      sync.sources = [_playlist];
      await refresh(tester);
      expect(find.text('Found 1 ready source(s).'), findsOneWidget);
      expect(await store.list(), isEmpty);
      expect(sync.selected, isNull);
      expect(sync.pulls, 0);
      expect(await profiles.activeId(), local.id);
      expect(completed, isFalse);

      await tester.ensureVisible(continueButton);
      await tester.tap(continueButton);
      await tester.pumpAndSettle();
      expect(completed, isTrue);
      expect(sync.selected, 'cloud');
      expect(sync.pulls, 1);
      expect(sync.metadataPulls, 1);
      expect(sync.favoritePulls, 1);
      expect((await store.metadataConfig()).autoEnrich, isFalse);
      expect(await profiles.activeId(), isNull);
      expect((await store.activeConfig())?.id, _playlist.id);
      expect((await profiles.loadAll()).single.snapshot.sourcesJson, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('cancel after preview preserves empty local setup', (
    tester,
  ) async {
    const profiles = LocalProfileStore();
    final local = await profiles.createProfile('Later', 0);
    await profiles.setActive(local.id);
    sync.sources = [_playlist];
    await openSetup(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(await store.list(), isEmpty);
    expect(await profiles.activeId(), local.id);
    expect(sync.selected, isNull);
    expect(sync.pulls, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'entering a cloud profile parks local data before automatic sync',
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
      await tester.ensureVisible(find.text('Pull now'));
      await tester.tap(find.text('Pull now'));
      await tester.pumpAndSettle();
      expect((await store.list()).map((source) => source.id), [_playlist.id]);
      expect(await profiles.activeId(), isNull);
      final parked = (await profiles.loadAll()).single.snapshot;
      expect(parked.sourcesJson.single['id'], localSource.id);
      expect(parked.activeSourceId, localSource.id);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('remote profile changes refresh the paired setup automatically', (
    tester,
  ) async {
    await openSetup(tester);
    sync.sources = [_playlist];
    sync.remote.add(null);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('Found 1 ready source(s).'), findsOneWidget);
    expect(sync.pulls, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('subscriber setup downloads saved profile without Continue', (
    tester,
  ) async {
    sync.supported = true;
    sync.sources = [_playlist];
    var completed = false;
    await openSetup(tester, onDone: () => completed = true);
    expect(completed, isTrue);
    expect((await store.activeConfig())?.id, _playlist.id);
    expect(sync.metadataPulls, 1);
    expect(sync.favoritePulls, 1);
    await tester.pumpWidget(const SizedBox());
  }, skip: !CloudConfig.isConfigured);

  testWidgets('failed Continue restores the local source state', (
    tester,
  ) async {
    const profiles = LocalProfileStore();
    final local = await profiles.createProfile('Later', 0);
    await profiles.setActive(local.id);
    sync.sources = [_playlist];
    sync.failPull = true;
    await openSetup(tester);
    final button = find.widgetWithText(FilledButton, 'Continue');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(await store.list(), isEmpty);
    expect(await store.activeId(), isNull);
    expect(await profiles.activeId(), local.id);
    expect(find.byType(CloudSyncScreen), findsOneWidget);
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('missing credentials cannot enable Continue', (tester) async {
    sync.sources = [_playlist.copyWith(fields: {})];
    await openSetup(tester);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Continue'),
    );
    expect(button.onPressed, isNull);
    expect(sync.pulls, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('locked cloud profile requires PIN before playlist preview', (
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
    await openSetup(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(sync.previews, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(sync.selected, isNull);
    expect(await store.list(), isEmpty);
    expect(await const LocalProfileStore().ownerless(), isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}

const _playlist = SourceConfig(
  id: 'playlist',
  kind: SourceKind.m3u,
  label: 'Playlist',
  fields: {'playlistUrl': 'https://example.invalid/list.m3u'},
);

class _SetupSync extends CloudSync {
  _SetupSync()
    : super(client: SupabaseClient('https://example.invalid', 'test'));

  List<CloudProfile> profiles = [
    const CloudProfile(id: 'cloud', name: 'Cloud', position: 0),
  ];
  List<SourceConfig> sources = [];
  String? selected;
  int pulls = 0;
  int previews = 0;
  int metadataPulls = 0;
  int favoritePulls = 0;
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
  Future<Set<String>> managedSourceIds() async => {};
  @override
  Future<void> setManagedSourceIds(Set<String> ids) async {}
}
