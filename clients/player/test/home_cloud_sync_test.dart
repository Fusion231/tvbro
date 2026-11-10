import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/cloud_config.dart';
import 'package:iptvs/data/cloud_sync.dart';
import 'package:iptvs/data/local_profile_store.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/player/player_screen.dart';
import 'package:iptvs/screens/home_shell.dart';
import 'package:iptvs/sources/source.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Run with a configured test backend/panel via --dart-define. All network
// operations are replaced by the injected sync; no account is created.
void main() {
  const sessionChannel = MethodChannel('iptvs/app_session');
  late Directory directory;
  late AppDatabase db;
  late SourceStore store;
  late _ProfileSync sync;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sessionChannel, (_) async => false);
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('tvbro_home_sync');
    db = await AppDatabase.openAt('${directory.path}/test.db');
    store = SourceStore();
    sync = _ProfileSync();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sessionChannel, null);
    await sync.remote.close();
    await db.close();
    directory.deleteSync(recursive: true);
  });

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomeShell(db: db, store: store, sync: sync),
      ),
    );
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }

  testWidgets('licensed boot pulls the complete profile even with no source', (
    tester,
  ) async {
    await show(tester);
    await tester.runAsync(
      () => sync.pulled.future.timeout(const Duration(seconds: 10)),
    );
    expect(sync.calls, ['sources', 'metadata', 'favorites', 'playback']);
    expect(sync.sessionsCreated, 0);
    await finish(tester);
  }, skip: !CloudConfig.isConfigured);

  testWidgets(
    'remote changes refresh all profile data without a manual action',
    (tester) async {
      await show(tester);
      await tester.runAsync(() => sync.pulled.future);
      sync.calls.clear();
      sync.pulled = Completer<void>();
      sync.remote.add(CloudProfileChange.profile);
      await tester.pump(const Duration(seconds: 6));
      await tester.runAsync(
        () => sync.pulled.future.timeout(const Duration(seconds: 10)),
      );
      expect(sync.calls, ['sources', 'metadata', 'favorites', 'playback']);
      await finish(tester);
    },
    skip: !CloudConfig.isConfigured,
  );

  testWidgets(
    'cached cloud profile keeps automatic sync alive at offline boot',
    (tester) async {
      sync.profileOffline = true;
      await show(tester);
      await tester.runAsync(
        () => sync.pulled.future.timeout(const Duration(seconds: 10)),
      );
      expect(sync.calls, ['sources', 'metadata', 'favorites', 'playback']);
      expect(sync.remote.hasListener, isTrue);
      await finish(tester);
    },
    skip: !CloudConfig.isConfigured,
  );

  testWidgets('free device does not start automatic profile synchronization', (
    tester,
  ) async {
    sync.supported = false;
    await show(tester);
    await tester.runAsync(() => sync.checked.future);
    await tester.pump();
    expect(sync.calls, isEmpty);
    expect(sync.remote.hasListener, isFalse);
    await finish(tester);
  }, skip: !CloudConfig.isConfigured);

  testWidgets('saved playback waits for the two-minute upload interval', (
    tester,
  ) async {
    await show(tester);
    await tester.runAsync(
      () => sync.pulled.future.timeout(const Duration(seconds: 10)),
    );
    await tester.pump();
    // Drain the initial outbox attempt before observing this playback save.
    await tester.pump(const Duration(seconds: 6));
    await tester.runAsync(
      () => sync.initialPush.future.timeout(const Duration(seconds: 10)),
    );
    sync.playbackPushed = Completer<void>();
    await tester.runAsync(
      () => db.savePlaybackPosition(
        'source',
        ContentKind.movie,
        'movie',
        position: const Duration(minutes: 2),
        duration: const Duration(hours: 1),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(sync.playbackPushed!.isCompleted, isFalse);
    await tester.pump(const Duration(seconds: 108));
    await tester.runAsync(
      () => sync.playbackPushed!.future.timeout(const Duration(seconds: 10)),
    );
    await finish(tester);
  }, skip: !CloudConfig.isConfigured);

  testWidgets(
    'sleep checkpoint behind the player uploads before the two-minute interval',
    (tester) async {
      await show(tester);
      await tester.runAsync(() => sync.pulled.future);
      await tester.pump(const Duration(seconds: 6));
      await tester.runAsync(() => sync.initialPush.future);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(tester.binding.lifecycleState, AppLifecycleState.paused);
      sync.playbackPushed = Completer<void>();

      await tester.runAsync(
        () => persistNativePlaybackProgress(
          PlaybackContext(
            db: db,
            sourceId: 'source',
            kind: ContentKind.episode,
            itemId: 'episode',
          ),
          {
            'nativeOpenId': 1,
            'positionMs': 60000,
            'durationMs': 2700000,
            'flush': true,
          },
          nativeOpenId: 1,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.runAsync(
        () => sync.playbackPushed!.future.timeout(const Duration(seconds: 10)),
      );
      expect(
        (await tester.runAsync(() => db.readPlaybackOutbox()))!
            .single
            .positionMs,
        60000,
      );
      await finish(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    },
    skip: !CloudConfig.isConfigured,
  );

  testWidgets(
    'remote progress refreshes progress without reading the rest of the profile',
    (tester) async {
      await show(tester);
      await tester.runAsync(() => sync.pulled.future);
      sync.calls.clear();
      sync.pulled = Completer<void>();
      sync.remote.add(CloudProfileChange.playback);
      await tester.pump(const Duration(seconds: 6));
      await tester.runAsync(
        () => sync.pulled.future.timeout(const Duration(seconds: 10)),
      );
      expect(sync.calls, ['playback']);
      await finish(tester);
    },
    skip: !CloudConfig.isConfigured,
  );

  testWidgets('local profile never pulls a previously paired cloud profile', (
    tester,
  ) async {
    const profiles = LocalProfileStore();
    final local = await profiles.createProfile('Local', 0);
    await profiles.setActive(local.id);
    await show(tester);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(sync.calls, isEmpty);
    expect(sync.remote.hasListener, isFalse);
    await finish(tester);
  }, skip: !CloudConfig.isConfigured);
}

class _ProfileSync extends CloudSync {
  _ProfileSync()
    : super(client: SupabaseClient('https://example.invalid', 'test'));

  bool supported = true;
  bool profileOffline = false;
  int sessionsCreated = 0;
  final calls = <String>[];
  final remote = StreamController<CloudProfileChange>.broadcast();
  final checked = Completer<void>();
  Completer<void> pulled = Completer<void>();
  final initialPush = Completer<void>();
  Completer<void>? playbackPushed;

  @override
  bool get hasSession => true;
  @override
  String get deviceId => 'device';
  @override
  Future<void> ensureAnonSession() async => sessionsCreated++;
  @override
  Future<SupporterStatus> supporterStatus() async {
    if (!checked.isCompleted) checked.complete();
    return SupporterStatus(
      supported: supported,
      validUntil: DateTime.now().add(const Duration(days: 1)),
    );
  }

  @override
  Future<String?> activeProfileId() async {
    if (profileOffline) throw const SocketException('Offline');
    return 'profile';
  }

  @override
  Future<String?> cachedProfileId() async => 'profile';
  @override
  Future<List<CloudProfile>> listProfiles() async => const [];
  @override
  Stream<CloudProfileChange> observeProfileUpdates(String profileId) =>
      remote.stream;
  @override
  Future<int> pullSources(
    SourceStore store,
    String profileId, {
    bool preserveLocalChanges = false,
  }) async {
    calls.add('sources');
    return 0;
  }

  @override
  Future<bool> pullMetadata(
    SourceStore store,
    String profileId, {
    bool preserveLocalChanges = false,
  }) async {
    calls.add('metadata');
    return false;
  }

  @override
  Future<void> pullFavorites(SourceStore store, String profileId) async {
    calls.add('favorites');
  }

  @override
  Future<void> pullPlaybackPositions(
    SourceStore store,
    String profileId,
  ) async {
    calls.add('playback');
    if (!pulled.isCompleted) pulled.complete();
  }

  @override
  Future<bool> pushSourceSettingsDelta(
    SourceStore store,
    String profileId,
  ) async => false;
  @override
  Future<bool> pushFavoritesDelta(SourceStore store, String profileId) async {
    if (!initialPush.isCompleted) initialPush.complete();
    return false;
  }

  @override
  Future<bool> pushPlaybackPositions(
    SourceStore store,
    String profileId, {
    bool includeAll = false,
  }) async {
    if (!initialPush.isCompleted) initialPush.complete();
    final pushed = playbackPushed;
    if (pushed != null && !pushed.isCompleted) pushed.complete();
    return false;
  }
}
