import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/cloud_sync.dart';
import 'package:iptvs/data/local_profile_store.dart';
import 'package:iptvs/data/profile_pin.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/profile_pick_screen.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/widgets/pin_entry.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late AppDatabase db;
  late SourceStore store;
  late SupabaseClient client;
  late _RecoverySync sync;
  late bool completed;

  setUpAll(() async {
    directory = Directory.systemTemp.createTempSync('tvbro_profile_recovery');
    db = await AppDatabase.openAt('${directory.path}/test.db');
  });

  tearDownAll(() async {
    await db.close();
    directory.deleteSync(recursive: true);
  });

  setUp(() async {
    debugResetPinAttempts();
    FlutterSecureStorage.setMockInitialValues({'cloud_profile_id': 'cloud'});
    store = SourceStore();
    await store.setAll([_source]);
    await store.setActive(_source.id);
    await const LocalProfileStore().setPickerStartup(
      ProfilePickerStartup.always,
    );
    client = SupabaseClient(
      'https://example.invalid',
      'test',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    sync = _RecoverySync(client);
    completed = false;
  });

  tearDown(() async {
    debugPinWorkerZone = null;
    await client.dispose();
  });

  Future<void> settle(WidgetTester tester) async {
    // Profile switching leaves a busy spinner behind the confirmation dialog.
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ProfilePickScreen(
          db: db,
          store: store,
          sync: sync,
          bootMode: true,
          onDone: () => completed = true,
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  }

  Future<void> resume(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  }

  Future<void> typePin(WidgetTester tester, String pin) async {
    await tester.runAsync(() async => debugPinWorkerZone = Zone.current);
    for (final digit in pin.split('')) {
      await tester.tap(find.text(digit));
      await tester.pump();
    }
    await settle(tester);
    await tester.runAsync(debugWaitForPinWork);
    await settle(tester);
  }

  Future<void> cacheLockedProfile() => const LocalProfileStore().saveCloudPins({
    'cloud': CloudProfileLock(verifier: hashProfilePin('1234'), name: 'Główny'),
  });

  testWidgets('the cached active profile can open while pairing is pending', (
    tester,
  ) async {
    final pairing = Completer<bool>();
    sync.pendingPairing = pairing.future;
    final before = [for (final source in await store.list()) source.toJson()];

    await show(tester);

    expect(find.text('Cloud profile'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(sync.pairingCalls, 1);
    expect(pairing.isCompleted, isFalse);
    await tester.tap(find.text('Cloud profile'));
    await settle(tester);
    expect(completed, isTrue);
    expect(sync.profileSelections, 0);
    expect(sync.sourcePulls, 0);
    pairing.complete(false);
    await settle(tester);
    expect(find.text('Cloud profile'), findsOneWidget);
    expect(sync.listCalls, 0);
    expect([for (final source in await store.list()) source.toJson()], before);
    await finish(tester);
  });

  testWidgets('automatic startup enters the cached profile without the cloud', (
    tester,
  ) async {
    final pairing = Completer<bool>();
    sync.pendingPairing = pairing.future;
    await const LocalProfileStore().setPickerStartup(ProfilePickerStartup.auto);

    await show(tester);

    expect(completed, isTrue);
    expect(pairing.isCompleted, isFalse);
    expect(sync.profileSelections, 0);
    expect(sync.sourcePulls, 0);
    pairing.complete(true);
    await settle(tester);
    expect(await store.activeId(), _source.id);
    await finish(tester);
  });

  testWidgets('a background refresh updates the grid without navigating', (
    tester,
  ) async {
    final profiles = Completer<List<CloudProfile>>();
    sync.pendingProfiles = profiles.future;

    await show(tester);

    expect(find.text('Cloud profile'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(sync.listCalls, 1);
    profiles.complete(_profiles);
    await settle(tester);
    expect(find.text('Family'), findsOneWidget);
    expect(find.text('Kids'), findsOneWidget);
    expect(find.text('Cloud profile'), findsNothing);
    expect(completed, isFalse);
    expect(await store.activeId(), _source.id);
    await finish(tester);
  });

  testWidgets('a pending PIN dialog ignores a background profile response', (
    tester,
  ) async {
    final profiles = Completer<List<CloudProfile>>();
    sync.pendingProfiles = profiles.future;
    await cacheLockedProfile();
    await show(tester);
    await tester.tap(find.text('Główny'));
    await settle(tester);
    expect(find.byType(AlertDialog), findsOneWidget);

    profiles.complete([
      const CloudProfile(id: 'cloud', name: 'Late unlocked', position: 0),
    ]);
    await settle(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Late unlocked'), findsNothing);
    expect(sync.activeLookups, 0);
    expect(
      (await const LocalProfileStore().cloudPins())['cloud']?.name,
      'Główny',
    );
    expect(completed, isFalse);
    await typePin(tester, '1234');
    expect(completed, isTrue);
    expect(sync.profileSelections, 0);
    expect(sync.sourcePulls, 0);
    await finish(tester);
  });

  testWidgets(
    'a cloud identity read error leaves an active local profile usable',
    (tester) async {
      const profiles = LocalProfileStore();
      final local = await profiles.createProfile(
        'Local family',
        0,
        snapshot: ProfileSnapshot(
          sourcesJson: [_source.toJson()],
          activeSourceId: _source.id,
        ),
      );
      await profiles.setActive(local.id);
      await cacheLockedProfile();
      sync.cachedIdentityError = StateError('Cloud identity cache unavailable');
      final pairing = Completer<bool>();
      sync.pendingPairing = pairing.future;

      await show(tester);

      expect(find.text('Local family'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.tap(find.text('Local family'));
      await settle(tester);
      expect(completed, isTrue);
      expect(sync.profileSelections, 0);
      expect(sync.sourcePulls, 0);
      expect(await profiles.activeId(), local.id);
      expect(await store.activeId(), _source.id);
      pairing.complete(false);
      await settle(tester);
      await finish(tester);
    },
  );

  testWidgets(
    'an unknown cached cloud identity cannot bypass its PIN at boot',
    (tester) async {
      const profiles = LocalProfileStore();
      await profiles.createProfile('Local family', 0);
      await profiles.setPickerStartup(ProfilePickerStartup.off);
      await cacheLockedProfile();
      sync.cachedIdentityError = StateError('Cloud identity cache unavailable');
      final pairing = Completer<bool>();
      sync.pendingPairing = pairing.future;

      await show(tester);

      expect(find.text('Local family'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Skip'), findsNothing);
      expect(completed, isFalse);
      expect(await store.activeId(), _source.id);
      pairing.complete(false);
      await settle(tester);
      expect(find.text('Skip'), findsOneWidget);
      expect(completed, isFalse);
      expect(sync.sourcePulls, 0);
      await finish(tester);
    },
  );

  testWidgets(
    'wrapped DNS failure keeps the cached profile usable with its PIN',
    (tester) async {
      sync.pairingError = AuthRetryableFetchException(
        message:
            'ClientException with SocketException: Failed host lookup: '
            "'api.tvbro.online' (OS Error: No address associated with hostname) "
            'uri=https://api.tvbro.online/auth/v1/token',
      );
      await cacheLockedProfile();
      final before = [for (final source in await store.list()) source.toJson()];

      await show(tester);

      expect(find.text('Główny'), findsOneWidget);
      expect(find.text('Skip'), findsNothing);
      expect(
        find.text('Cloud sync failed. Check your connection and try again.'),
        findsOneWidget,
      );
      expect(find.textContaining('Failed host lookup'), findsNothing);
      expect(find.textContaining('/auth/v1/token'), findsNothing);
      await tester.tap(find.text('Główny'));
      await settle(tester);
      await typePin(tester, '1111');
      expect(find.text('Wrong PIN. Try again.'), findsOneWidget);
      expect(completed, isFalse);
      await typePin(tester, '1234');
      expect(completed, isTrue);
      expect(sync.profileSelections, 0);
      expect(sync.sourcePulls, 0);
      expect([
        for (final source in await store.list()) source.toJson(),
      ], before);
      expect(await store.activeId(), _source.id);
      await finish(tester);
    },
  );

  testWidgets(
    'pairing timeout keeps the PIN gate after a late unpair response',
    (tester) async {
      final pairing = Completer<bool>();
      sync.pendingPairing = pairing.future;
      await cacheLockedProfile();
      await show(tester);
      expect(find.text('Główny'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.pump(const Duration(seconds: 8));
      await settle(tester);
      expect(find.text('Główny'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Skip'), findsNothing);
      pairing.complete(false);
      await settle(tester);
      expect(find.text('Główny'), findsOneWidget);
      expect(find.text('Skip'), findsNothing);
      expect(sync.listCalls, 0);
      expect(sync.activeLookups, 0);
      expect(await sync.cachedProfileId(), 'cloud');
      await finish(tester);
    },
  );

  testWidgets(
    'one deadline covers all lookup stages and ignores late profiles',
    (tester) async {
      final pairing = Completer<bool>();
      final profiles = Completer<List<CloudProfile>>();
      sync.pendingPairing = pairing.future;
      sync.pendingProfiles = profiles.future;
      await cacheLockedProfile();
      await show(tester);

      await tester.pump(const Duration(seconds: 7));
      pairing.complete(true);
      await tester.pump();
      expect(sync.listCalls, 1);
      expect(find.text('Główny'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(find.text('Główny'), findsOneWidget);
      expect(find.text('Skip'), findsNothing);
      profiles.complete([
        const CloudProfile(
          id: 'cloud',
          name: 'Late unlocked profile',
          position: 0,
        ),
      ]);
      await settle(tester);
      expect(find.text('Late unlocked profile'), findsNothing);
      expect(find.text('Główny'), findsOneWidget);
      expect(find.text('Skip'), findsNothing);
      expect(sync.activeLookups, 0);
      expect(
        (await const LocalProfileStore().cloudPins())['cloud']?.name,
        'Główny',
      );
      await finish(tester);
    },
  );

  testWidgets('identity timeout retains freshly listed profile PINs', (
    tester,
  ) async {
    final activeId = Completer<String?>();
    sync.pendingActiveId = activeId.future;
    sync.pendingProfiles = Future.value([
      CloudProfile(
        id: 'cloud',
        name: 'Fresh locked profile',
        position: 0,
        pin: hashProfilePin('1234'),
      ),
    ]);
    await show(tester);
    expect(sync.activeLookups, 1);

    await tester.pump(const Duration(seconds: 8));
    await settle(tester);
    expect(find.text('Fresh locked profile'), findsOneWidget);
    expect(find.text('Skip'), findsNothing);
    expect(
      (await const LocalProfileStore().cloudPins())['cloud']?.name,
      'Fresh locked profile',
    );
    activeId.complete('late-other-profile');
    await settle(tester);
    expect(await sync.cachedProfileId(), 'cloud');
    expect(find.text('Fresh locked profile'), findsOneWidget);
    expect(find.text('Skip'), findsNothing);
    expect(completed, isFalse);
    await finish(tester);
  });

  for (final failure in ['pairing', 'profiles']) {
    testWidgets(
      'offline $failure check keeps the unlocked active profile usable',
      (tester) async {
        if (failure == 'pairing') {
          sync.pairingError = const SocketException('Offline');
        } else {
          sync.listError = const SocketException('Offline');
        }
        final before = [
          for (final source in await store.list()) source.toJson(),
        ];

        await show(tester);

        expect(find.text('Cloud profile'), findsOneWidget);
        expect(find.text('Retry'), findsOneWidget);
        expect(
          find.text(friendlyCloudError(const SocketException('Offline'))),
          findsOneWidget,
        );
        await tester.tap(find.text('Cloud profile'));
        await settle(tester);

        expect(completed, isTrue);
        expect(sync.profileSelections, 0);
        expect(sync.sourcePulls, 0);
        expect([
          for (final source in await store.list()) source.toJson(),
        ], before);
        expect(await store.activeId(), _source.id);
        expect(await sync.cachedProfileId(), 'cloud');
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
    );
  }

  testWidgets('Retry restores the remote profiles and clears the read error', (
    tester,
  ) async {
    sync.listError = const SocketException('Offline');
    await show(tester);
    expect(find.text('Cloud profile'), findsOneWidget);
    expect(sync.listCalls, 1);

    sync.listError = null;
    await tester.tap(find.text('Retry'));
    await settle(tester);

    expect(find.text('Family'), findsOneWidget);
    expect(find.text('Kids'), findsOneWidget);
    expect(find.text('Cloud profile'), findsNothing);
    expect(find.text('Retry'), findsNothing);
    expect(
      find.text(friendlyCloudError(const SocketException('Offline'))),
      findsNothing,
    );
    expect(sync.listCalls, 2);
    expect(completed, isFalse);
    expect(await store.activeId(), _source.id);
    await finish(tester);
  });

  testWidgets('resume retries a failed read once while that retry is pending', (
    tester,
  ) async {
    sync.listError = const SocketException('Offline');
    await show(tester);
    expect(sync.listCalls, 1);

    final pending = Completer<List<CloudProfile>>();
    sync.listError = null;
    sync.pendingProfiles = pending.future;
    await resume(tester);
    await tester.pump();
    expect(sync.listCalls, 2);
    expect(sync.pairingCalls, 2);
    expect(find.text('Cloud profile'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await resume(tester);
    await tester.pump();
    expect(sync.listCalls, 2);
    expect(sync.pairingCalls, 2);

    pending.complete(_profiles);
    await settle(tester);
    expect(find.text('Family'), findsOneWidget);
    expect(find.text('Kids'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);

    await resume(tester);
    await settle(tester);
    expect(sync.listCalls, 2, reason: 'a successful read needs no recovery');
    expect(sync.pairingCalls, 2);
    await finish(tester);
  });

  testWidgets('Retry keeps the cached grid usable and coalesces resume reads', (
    tester,
  ) async {
    sync.listError = const SocketException('Offline');
    await show(tester);
    final profiles = Completer<List<CloudProfile>>();
    sync.listError = null;
    sync.pendingProfiles = profiles.future;

    await tester.tap(find.text('Retry'));
    await settle(tester);
    expect(find.text('Cloud profile'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(sync.listCalls, 2);
    await resume(tester);
    await resume(tester);
    await settle(tester);
    expect(sync.listCalls, 2);
    expect(sync.pairingCalls, 2);
    profiles.complete(_profiles);
    await settle(tester);
    expect(find.text('Family'), findsOneWidget);
    expect(find.text('Kids'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(completed, isFalse);
    await finish(tester);
  });

  testWidgets('resume behind another route does not start profile recovery', (
    tester,
  ) async {
    sync.listError = const SocketException('Offline');
    await show(tester);
    final navigator = Navigator.of(
      tester.element(find.byType(ProfilePickScreen)),
    );
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Another screen')),
        ),
      ),
    );
    await settle(tester);

    await resume(tester);
    await settle(tester);
    expect(sync.pairingCalls, 1);
    expect(sync.listCalls, 1);

    navigator.pop();
    await settle(tester);
    expect(find.text('Retry'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('an offline cached locked profile still requires its PIN', (
    tester,
  ) async {
    sync.pairingError = const SocketException('Offline');
    await const LocalProfileStore().saveCloudPins({
      'cloud': CloudProfileLock(
        verifier: hashProfilePin('1234'),
        name: 'Locked family',
      ),
    });

    await show(tester);
    expect(find.text('Locked family'), findsOneWidget);
    expect(find.text('Skip'), findsNothing);
    await tester.tap(find.text('Locked family'));
    await settle(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(completed, isFalse);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(completed, isFalse);
    expect(find.text('Skip'), findsNothing);
    expect(sync.profileSelections, 0);
    expect(sync.sourcePulls, 0);
    expect(await store.activeId(), _source.id);
    await finish(tester);
  });

  testWidgets('a cached cloud profile cannot claim an active local profile', (
    tester,
  ) async {
    const profiles = LocalProfileStore();
    final local = await profiles.createProfile(
      'Local family',
      0,
      snapshot: ProfileSnapshot(
        sourcesJson: [_source.toJson()],
        activeSourceId: _source.id,
      ),
    );
    await profiles.setActive(local.id);
    sync.pairingError = const SocketException('Offline');
    await show(tester);

    await tester.tap(find.text('Cloud profile'));
    await settle(tester);
    expect(find.text('Switch profile'), findsOneWidget);
    expect(completed, isFalse);
    expect(sync.profileSelections, 0);
    await tester.tap(find.text('Cancel'));
    await settle(tester);

    await tester.tap(find.text('Local family'));
    await settle(tester);
    expect(completed, isTrue);
    expect(sync.profileSelections, 0);
    expect(sync.sourcePulls, 0);
    expect(await profiles.activeId(), local.id);
    expect(await store.activeId(), _source.id);
    expect(
      (await profiles.loadAll()).single.snapshot.toJson(),
      local.snapshot.toJson(),
    );
    await finish(tester);
  });

  testWidgets('a definitive unpair does not restore a cached cloud profile', (
    tester,
  ) async {
    final pairing = Completer<bool>();
    sync.pendingPairing = pairing.future;
    await const LocalProfileStore().saveCloudPins({
      'cloud': const CloudProfileLock(
        verifier: 'cached',
        name: 'Locked family',
      ),
    });

    await show(tester);
    expect(find.text('Locked family'), findsOneWidget);
    final initialCacheReads = sync.cacheReads;
    pairing.complete(false);
    await settle(tester);

    expect(find.text('Cloud profile'), findsNothing);
    expect(find.text('Locked family'), findsNothing);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Download from cloud'), findsOneWidget);
    expect(sync.listCalls, 0);
    expect(sync.cacheReads, initialCacheReads);
    expect(completed, isFalse);
    expect(await store.activeId(), _source.id);
    await finish(tester);
  });
}

const _source = SourceConfig(
  id: 'saved-source',
  kind: SourceKind.demo,
  label: 'Saved source',
  fields: {},
);

const _profiles = [
  CloudProfile(id: 'cloud', name: 'Family', position: 0),
  CloudProfile(id: 'kids', name: 'Kids', position: 1),
];

class _RecoverySync extends CloudSync {
  _RecoverySync(SupabaseClient client) : super(client: client);

  bool paired = true;
  Future<bool>? pendingPairing;
  Object? pairingError;
  Object? cachedIdentityError;
  Object? listError;
  Future<List<CloudProfile>>? pendingProfiles;
  Future<String?>? pendingActiveId;
  int pairingCalls = 0;
  int listCalls = 0;
  int activeLookups = 0;
  int cacheReads = 0;
  int profileSelections = 0;
  int sourcePulls = 0;

  @override
  bool get hasSession => true;

  @override
  Future<bool> isPaired() async {
    pairingCalls++;
    if (pairingError case final error?) throw error;
    return pendingPairing ?? Future.value(paired);
  }

  @override
  Future<List<CloudProfile>> listProfiles() async {
    listCalls++;
    if (listError case final error?) throw error;
    return pendingProfiles ?? Future.value(_profiles);
  }

  @override
  Future<String?> readActiveProfileId() async {
    activeLookups++;
    return pendingActiveId ?? Future.value('cloud');
  }

  @override
  Future<String?> cachedProfileId() {
    cacheReads++;
    if (cachedIdentityError case final error?) return Future.error(error);
    return super.cachedProfileId();
  }

  @override
  Future<void> setProfile(String profileId) async {
    profileSelections++;
    throw StateError('The active profile must not be selected remotely');
  }

  @override
  Future<int> pullSources(
    SourceStore store,
    String profileId, {
    bool preserveLocalChanges = false,
  }) async {
    sourcePulls++;
    throw StateError('The cached active profile must not pull sources');
  }
}
