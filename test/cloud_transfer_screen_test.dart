import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/cloud_sync.dart';
import 'package:iptvs/data/local_profile_store.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/cloud_sync_screen.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late Directory directory;
  late AppDatabase db;
  late SourceStore store;
  late _TransferSync sync;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('tvbro_cloud_transfer');
    db = await AppDatabase.openAt('${directory.path}/test.db');
    store = SourceStore();
    sync = _TransferSync();
  });

  tearDown(() async {
    await db.close();
    directory.deleteSync(recursive: true);
  });

  Future<void> openTransfer(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CloudSyncScreen(store: store, db: db, sync: sync),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> confirmUpload(WidgetTester tester) async {
    await tapKey(tester, 'transfer-submit');
    expect(find.text('Push to panel?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Push'));
    await tester.pumpAndSettle();
  }

  Future<void> openCreateConfirmation(WidgetTester tester) async {
    final submit = find.byKey(const ValueKey('transfer-submit'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Create a panel profile?'), findsOneWidget);
  }

  Future<void> confirmCreate(WidgetTester tester) async {
    await openCreateConfirmation(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Create and upload'));
    await tester.pumpAndSettle();
  }

  for (final size in [const Size(960, 540), const Size(1280, 720)]) {
    testWidgets('TV download controls fit immediately at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      sync.profiles = [
        for (var i = 0; i < 10; i++)
          CloudProfile(
            id: 'cloud-$i',
            name: 'Profile $i',
            position: i,
            updatedAt: _revision,
          ),
      ];
      sync.selected = 'cloud-9';
      sync.remoteSources['cloud-9'] = [
        for (var i = 0; i < 12; i++) _remoteSource('$i'),
      ];
      await openTransfer(tester);
      await tester.tap(find.byKey(const ValueKey('sync-download')));
      await tester.pumpAndSettle();

      final selected = find.byKey(const ValueKey('cloud-profile-cloud-9'));
      final submit = find.byKey(const ValueKey('transfer-submit'));
      expect(selected.hitTestable(), findsOneWidget);
      expect(submit.hitTestable(), findsOneWidget);
      expect(
        tester.getRect(submit).bottom,
        lessThanOrEqualTo(size.height - 16),
      );
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus!.context!
            .findAncestorWidgetOfExactType<FilledButton>()
            ?.key,
        const ValueKey('transfer-submit'),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(sync.pulls, 1);
      expect(
        find.byKey(const ValueKey('transfer-done')).hitTestable(),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('paired entry asks for a direction without choosing a profile', (
    tester,
  ) async {
    await store.setAll([_localSource]);
    await openTransfer(tester);
    expect(find.byKey(const ValueKey('sync-download')), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-upload')), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-profile-cloud-a')), findsNothing);
    expect(find.byKey(const ValueKey('transfer-submit')), findsNothing);
    expect(sync.selected, isNull);
    expect(sync.selections, isEmpty);
    expect(sync.pulls, 0);
    expect((await store.list()).single.id, _localSource.id);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'new pairing preserves local sources until a transfer is chosen',
    (tester) async {
      sync.paired = false;
      await store.setAll([_localSource]);
      await openTransfer(tester);
      expect(find.text('ABCD2345'), findsOneWidget);
      expect(sync.codeRequests, 1);
      expect(sync.pairingChecks, 0);

      await tester.ensureVisible(find.text('New code'));
      await tester.tap(find.text('New code'));
      await tester.pumpAndSettle();
      expect(sync.codeRequests, 2);
      sync.claimed = true;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      expect(sync.pairingChecks, 1);
      expect(find.byKey(const ValueKey('sync-download')), findsOneWidget);
      expect(find.byKey(const ValueKey('sync-upload')), findsOneWidget);
      expect(sync.pulls, 0);
      expect(sync.selections, isEmpty);
      expect((await store.list()).single.id, _localSource.id);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'empty upload stays disabled and offers local profile selection',
    (tester) async {
      await openTransfer(tester);
      await tapKey(tester, 'sync-upload');
      final submit = tester.widget<FilledButton>(
        find.byKey(const ValueKey('transfer-submit')),
      );
      expect(submit.onPressed, isNull);
      final chooseProfile = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Choose a profile on this device'),
      );
      expect(chooseProfile.onPressed, isNotNull);
      expect(sync.uploadedProfile, isNull);
      expect(sync.pulls, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'download selection previews distinct same-name profiles safely',
    (tester) async {
      await store.setAll([_localSource]);
      await openTransfer(tester);
      await tapKey(tester, 'sync-download');
      expect(find.textContaining('Panel playlist A'), findsOneWidget);
      expect(sync.pulls, 0);

      await tapKey(tester, 'cloud-profile-cloud-b');
      expect(find.textContaining('Panel playlist B'), findsOneWidget);
      expect(find.textContaining('Panel playlist A'), findsNothing);
      expect(sync.previews.last, 'cloud-b');
      expect(sync.selections, isEmpty);
      expect((await store.list()).single.id, _localSource.id);

      await tapKey(tester, 'change-direction');
      expect(find.byKey(const ValueKey('sync-download')), findsOneWidget);
      expect(find.byKey(const ValueKey('transfer-submit')), findsNothing);
      expect(sync.pulls, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'explicit download parks local profile and binds chosen profile',
    (tester) async {
      const profiles = LocalProfileStore();
      final local = await profiles.createProfile('This device', 0);
      await profiles.setActive(local.id);
      await store.setAll([_localSource]);
      await openTransfer(tester);
      await tapKey(tester, 'sync-download');
      await tapKey(tester, 'cloud-profile-cloud-b');
      expect(await profiles.activeId(), local.id);

      await tapKey(tester, 'transfer-submit');
      expect(sync.selected, 'cloud-b');
      expect(sync.pulls, 1);
      expect(sync.metadataPulls, 1);
      expect(sync.favoritePulls, 1);
      expect(sync.playbackPulls, 1);
      expect((await store.list()).single.label, 'Panel playlist B');
      expect(await profiles.activeId(), isNull);
      expect(await profiles.ownerless(), isFalse);
      final parked = (await profiles.loadAll()).single.snapshot;
      expect(parked.sourcesJson.single['id'], _localSource.id);
      expect(find.byKey(const ValueKey('transfer-done')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'upload refreshes profiles and binds while preserving local data',
    (tester) async {
      const profiles = LocalProfileStore();
      final local = await profiles.createProfile('This device', 0);
      await profiles.setActive(local.id);
      await store.setAll([_localSource]);
      sync.addProfileAfterUpload = true;
      sync.supported = true;
      await openTransfer(tester);
      await tapKey(tester, 'sync-upload');
      expect(find.textContaining(_localSource.label), findsWidgets);
      await tapKey(tester, 'cloud-profile-cloud-b');
      final listingsBeforePush = sync.listings;

      await confirmUpload(tester);
      expect(sync.uploadedProfile, 'cloud-b');
      expect(sync.selected, 'cloud-b');
      expect(sync.listings, greaterThan(listingsBeforePush));
      expect(sync.pulls, 0);
      expect(sync.metadataPushes, 1);
      expect(sync.favoritePushes, 1);
      expect(sync.playbackPushes, [true]);
      expect((await store.list()).single.id, _normalizedLocalId);
      expect((await store.list()).single.label, _localSource.label);
      expect(await profiles.activeId(), isNull);
      expect(await profiles.ownerless(), isFalse);
      final parked = (await profiles.loadAll()).single.snapshot;
      expect(parked.sourcesJson.single['id'], _normalizedLocalId);
      expect(parked.managedIds, isEmpty);
      final cloud = await profiles.cloudSnapshot('cloud-b');
      expect(cloud?.sourcesJson.single['id'], _normalizedLocalId);
      expect(cloud?.managedIds, [_normalizedLocalId]);
      expect(find.byKey(const ValueKey('transfer-done')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('upload cannot move a playlist out of another panel profile', (
    tester,
  ) async {
    const profiles = LocalProfileStore();
    final local = await profiles.createProfile('This device', 0);
    await profiles.setActive(local.id);
    await store.setAll([_localSource]);
    sync.remoteSources['cloud-a'] = [_localSource];
    await openTransfer(tester);
    await tapKey(tester, 'sync-upload');
    await tapKey(tester, 'cloud-profile-cloud-b');

    await tapKey(tester, 'transfer-submit');
    expect(
      find.text(
        'Some playlists already belong to another panel profile. Upload to that profile, or add a separate copy in the panel.',
      ),
      findsOneWidget,
    );
    expect(find.byType(AlertDialog), findsNothing);
    expect(sync.previews, contains('cloud-a'));
    expect(sync.uploadedProfile, isNull);
    expect(sync.metadataPushes, 0);
    expect(sync.favoritePushes, 0);
    expect(sync.selections, isEmpty);
    expect(sync.selected, isNull);
    expect(sync.pulls, 0);
    expect((await store.list()).single.toJson(), _localSource.toJson());
    expect(await profiles.activeId(), local.id);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('free manual upload keeps sources and favorites available', (
    tester,
  ) async {
    await store.setAll([_localSource]);
    await openTransfer(tester);
    await tapKey(tester, 'sync-upload');
    await tapKey(tester, 'cloud-profile-cloud-b');
    await confirmUpload(tester);

    expect(sync.uploadedProfile, 'cloud-b');
    expect(sync.favoritePushes, 1);
    expect(sync.playbackPushes, isEmpty);
    expect(find.byKey(const ValueKey('transfer-done')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('refresh lists makes a newly added panel profile selectable', (
    tester,
  ) async {
    await openTransfer(tester);
    await tapKey(tester, 'sync-download');
    sync.profiles = [...sync.profiles, _thirdProfile];
    sync.remoteSources['cloud-c'] = [_remoteSource('C')];

    await tapKey(tester, 'refresh-profiles');
    expect(find.byKey(const ValueKey('cloud-profile-cloud-c')), findsOneWidget);
    await tapKey(tester, 'cloud-profile-cloud-c');
    expect(find.textContaining('Panel playlist C'), findsOneWidget);
    expect(sync.pulls, 0);
    expect(sync.selections, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'new upload uses the local profile name and preserves its original lists',
    (tester) async {
      const profiles = LocalProfileStore();
      final local = await profiles.createProfile('Living room', 0);
      await profiles.setActive(local.id);
      await store.setAll([_localSource]);
      final originalPanelA = sync.remoteSources['cloud-a']!.single.toJson();
      final originalPanelB = sync.remoteSources['cloud-b']!.single.toJson();
      await openTransfer(tester);
      await tapKey(tester, 'sync-upload');

      final nameField = find.byKey(const ValueKey('new-profile-name'));
      final field = tester.widget<TextField>(nameField);
      expect(field.controller?.text, 'Living room');
      expect(find.byKey(const ValueKey('upload-new-profile')), findsOneWidget);
      await tester.enterText(nameField, 'Living room — panel');
      await tester.pumpAndSettle();
      await confirmCreate(tester);

      final createdId = sync.creationIds.single;
      expect(sync.creationNames, ['Living room — panel']);
      expect(sync.selected, createdId);
      expect(sync.uploadedProfile, isNull);
      expect(sync.remoteSources['cloud-a']!.single.toJson(), originalPanelA);
      expect(sync.remoteSources['cloud-b']!.single.toJson(), originalPanelB);
      expect(sync.remoteSources[createdId]!.single.label, _localSource.label);
      expect(sync.remoteSources[createdId]!.single.fields, _localSource.fields);
      expect((await store.list()).single.id, _newCloudSourceId);
      expect(await profiles.activeId(), isNull);
      final savedLocal = (await profiles.loadAll()).single;
      expect(savedLocal.id, local.id);
      expect(savedLocal.snapshot.sourcesJson.single['id'], _localSource.id);
      expect(savedLocal.snapshot.managedIds, isEmpty);
      expect(find.byKey(ValueKey('cloud-profile-$createdId')), findsOneWidget);
      expect(find.byKey(const ValueKey('transfer-done')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('new upload can create the first panel profile', (tester) async {
    const profiles = LocalProfileStore();
    final local = await profiles.createProfile('Cinema', 0);
    await profiles.setActive(local.id);
    await store.setAll([_localSource]);
    sync.profiles = [];
    await openTransfer(tester);
    await tapKey(tester, 'sync-upload');
    final submit = tester.widget<FilledButton>(
      find.byKey(const ValueKey('transfer-submit')),
    );
    expect(submit.onPressed, isNotNull);

    await confirmCreate(tester);
    expect(sync.creationNames, ['Cinema']);
    expect(sync.profiles.single.name, 'Cinema');
    expect(sync.selected, sync.profiles.single.id);
    expect((await store.list()).single.id, _newCloudSourceId);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('new upload requires a nonblank profile name', (tester) async {
    await store.setAll([_localSource]);
    await openTransfer(tester);
    await tapKey(tester, 'sync-upload');
    await tester.enterText(
      find.byKey(const ValueKey('new-profile-name')),
      '   ',
    );
    await tester.pumpAndSettle();
    final submit = tester.widget<FilledButton>(
      find.byKey(const ValueKey('transfer-submit')),
    );
    expect(submit.onPressed, isNull);
    expect(sync.creationIds, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'copying an encrypted profile explains protection before consent',
    (tester) async {
      await store.setAll([_localSource]);
      sync.selected = 'cloud-a';
      sync.managed = {_localSource.id};
      sync.currentCryptoStatus = CloudCryptoStatus.ready;
      sync.remoteSources['cloud-a'] = [_localSource];
      await openTransfer(tester);
      await tapKey(tester, 'sync-upload');
      await openCreateConfirmation(tester);
      expect(find.text('Create a panel profile?'), findsOneWidget);
      expect(
        find.text(
          'The new copy will not use end-to-end encryption. The panel server will be able to read its playlist credentials. The original encrypted profile stays unchanged.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(sync.creationIds, isEmpty);
      expect(sync.uploadedProfile, isNull);
      expect(sync.selections, isEmpty);
      expect(sync.selected, 'cloud-a');
      expect(sync.managed, {_localSource.id});
      expect(sync.pulls, 0);
      expect((await store.list()).single.toJson(), _localSource.toJson());
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'failed new upload preserves local data and retries the same id',
    (tester) async {
      const profiles = LocalProfileStore();
      final local = await profiles.createProfile('Living room', 0);
      await profiles.setActive(local.id);
      await store.setAll([_localSource]);
      sync.failCreation = true;
      await openTransfer(tester);
      await tapKey(tester, 'sync-upload');
      await confirmCreate(tester);

      final firstId = sync.creationIds.single;
      expect(sync.profiles, hasLength(2));
      expect((await store.list()).single.toJson(), _localSource.toJson());
      expect(await profiles.activeId(), local.id);
      expect(sync.selected, isNull);
      expect(sync.selections, isEmpty);
      expect(sync.pulls, 0);
      expect(find.byKey(const ValueKey('transfer-done')), findsNothing);

      sync.failCreation = false;
      await confirmCreate(tester);
      expect(sync.creationIds, [firstId, firstId]);
      expect(
        sync.profiles.where((profile) => profile.id == firstId),
        hasLength(1),
      );
      expect(sync.selected, firstId);
      expect(find.byKey(const ValueKey('transfer-done')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'failed upload restores normalized source changes and local owner',
    (tester) async {
      const profiles = LocalProfileStore();
      final local = await profiles.createProfile('This device', 0);
      await profiles.setActive(local.id);
      await store.setAll([_localSource]);
      sync.failMetadataPush = true;
      await openTransfer(tester);
      await tapKey(tester, 'sync-upload');
      await tapKey(tester, 'cloud-profile-cloud-a');
      await confirmUpload(tester);
      expect(sync.uploadedProfile, 'cloud-a');
      expect(sync.creationIds, isEmpty);
      expect((await store.list()).single.id, _localSource.id);
      expect(await profiles.activeId(), local.id);
      expect(sync.selected, isNull);
      expect(sync.pulls, 0);
      expect(find.byKey(const ValueKey('transfer-done')), findsNothing);
      final retry = tester.widget<FilledButton>(
        find.byKey(const ValueKey('transfer-submit')),
      );
      expect(retry.onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

const _localSource = SourceConfig(
  id: 'local-source',
  kind: SourceKind.m3u,
  label: 'Playlist on this device',
  fields: {'playlistUrl': 'https://example.invalid/local.m3u'},
);
const _normalizedLocalId = '22222222-2222-4222-8222-222222222222';
const _newCloudSourceId = '33333333-3333-4333-8333-333333333333';
final _revision = DateTime.utc(2026, 10, 23);
final _thirdProfile = CloudProfile(
  id: 'cloud-c',
  name: 'Added in the panel',
  position: 2,
  updatedAt: _revision,
);

SourceConfig _remoteSource(String suffix) => SourceConfig(
  id: 'remote-$suffix',
  kind: SourceKind.m3u,
  label: 'Panel playlist $suffix',
  fields: {'playlistUrl': 'https://example.invalid/$suffix.m3u'},
);

class _TransferSync extends CloudSync {
  _TransferSync()
    : super(client: SupabaseClient('https://example.invalid', 'test'));

  List<CloudProfile> profiles = [
    CloudProfile(
      id: 'cloud-a',
      name: 'Default',
      position: 0,
      updatedAt: _revision,
    ),
    CloudProfile(
      id: 'cloud-b',
      name: 'Default',
      position: 1,
      updatedAt: _revision,
    ),
  ];
  final remoteSources = <String, List<SourceConfig>>{
    'cloud-a': [_remoteSource('A')],
    'cloud-b': [_remoteSource('B')],
  };
  String? selected;
  String? uploadedProfile;
  final selections = <String>[];
  final previews = <String>[];
  final creationIds = <String>[];
  final creationNames = <String>[];
  Set<String> managed = {};
  int listings = 0;
  int pulls = 0;
  int metadataPulls = 0;
  int favoritePulls = 0;
  int playbackPulls = 0;
  int metadataPushes = 0;
  int favoritePushes = 0;
  final playbackPushes = <bool>[];
  bool addProfileAfterUpload = false;
  bool failMetadataPush = false;
  bool failCreation = false;
  CloudCryptoStatus currentCryptoStatus = CloudCryptoStatus.off;
  bool paired = true;
  bool supported = false;
  bool claimed = false;
  int codeRequests = 0;
  int pairingChecks = 0;

  @override
  bool get hasSession => true;
  @override
  String get deviceId => 'test-device';
  @override
  Future<void> ensureAnonSession() async {}
  @override
  Future<bool> isPaired() async => paired;
  @override
  Future<PairingCode> requestPairingCode({String? label}) async {
    codeRequests++;
    return PairingCode(
      'ABCD2345',
      DateTime.now().add(const Duration(minutes: 10)),
    );
  }

  @override
  Future<bool> pairingStatus(String code) async {
    pairingChecks++;
    return claimed;
  }

  @override
  Future<SupporterStatus> supporterStatus() async => SupporterStatus(
    supported: supported,
    validUntil: DateTime.now().add(const Duration(days: 1)),
  );
  @override
  Future<List<CloudProfile>> listProfiles() async {
    listings++;
    return profiles;
  }

  @override
  Future<CloudCryptoState> cryptoState(String profileId) async =>
      CloudCryptoState(status: currentCryptoStatus);
  @override
  Future<List<SourceConfig>> previewSources(
    SourceStore store,
    String profileId,
  ) async {
    previews.add(profileId);
    return remoteSources[profileId] ?? [];
  }

  @override
  Future<void> setProfile(String profileId) async {
    selected = profileId;
    selections.add(profileId);
  }

  @override
  Future<String?> activeProfileId() async => selected;
  @override
  Future<String?> cachedProfileId() async => selected;
  @override
  Future<CloudRevision?> profileRevision(String profileId) async =>
      CloudRevision(profileId: profileId, updatedAt: _revision);
  @override
  Future<int> pullSources(
    SourceStore store,
    String profileId, {
    bool preserveLocalChanges = false,
  }) async {
    pulls++;
    final sources = remoteSources[profileId] ?? [];
    await store.setAll(sources);
    managed = sources.map((source) => source.id).toSet();
    return sources.length;
  }

  @override
  Future<bool> pullMetadata(
    SourceStore store,
    String profileId, {
    bool preserveLocalChanges = false,
  }) async {
    metadataPulls++;
    return false;
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
  Future<int> pushSources(SourceStore store, String profileId) async {
    uploadedProfile = profileId;
    final sources = (await store.list())
        .map((source) => source.copyWith(id: _normalizedLocalId))
        .toList();
    await store.setAll(sources);
    managed = sources.map((source) => source.id).toSet();
    remoteSources[profileId] = sources;
    if (addProfileAfterUpload) profiles = [...profiles, _thirdProfile];
    return sources.length;
  }

  @override
  Future<void> pushMetadata(SourceStore store, String profileId) async {
    metadataPushes++;
    if (failMetadataPush) throw StateError('Upload failed');
  }

  @override
  Future<void> pushFavorites(SourceStore store, String profileId) async {
    favoritePushes++;
  }

  @override
  Future<bool> pushPlaybackPositions(
    SourceStore store,
    String profileId, {
    bool includeAll = false,
  }) async {
    playbackPushes.add(includeAll);
    return true;
  }

  @override
  Future<CloudProfile> createProfileFromDevice(
    SourceStore store, {
    required String profileId,
    required String name,
  }) async {
    creationIds.add(profileId);
    creationNames.add(name);
    if (failCreation) throw StateError('Profile creation failed');
    final profile = CloudProfile(
      id: profileId,
      name: name,
      position: profiles.length,
      updatedAt: _revision,
    );
    profiles = [...profiles.where((p) => p.id != profileId), profile];
    remoteSources[profileId] = [
      for (final source in await store.list())
        source.copyWith(id: _newCloudSourceId),
    ];
    return profile;
  }

  @override
  Future<Set<String>> managedSourceIds() async => managed;
  @override
  Future<void> setManagedSourceIds(Set<String> ids) async => managed = ids;
}
