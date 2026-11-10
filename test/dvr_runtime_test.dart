import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/dvr_runtime.dart';
import 'package:iptvs/data/local_profile_store.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/dvr/dvr_schedule.dart';
import 'package:iptvs/dvr/dvr_service.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';

class _ScheduleDb implements AppDatabase {
  String? readSource;
  @override
  Future<Channel?> readChannel(String sourceId, String channelId) async {
    readSource = sourceId;
    return Channel(
      id: channelId,
      name: 'Demo',
      extra: const {'urlKey': 'sintel_trailer'},
    );
  }

  @override
  Future<Channel> revealChannel(Channel channel) async => channel;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'uses the existing inactive cloud snapshot without a server call',
    () async {
      const profiles = LocalProfileStore();
      const config = SourceConfig(
        id: 'cloud-source',
        kind: SourceKind.demo,
        label: 'Cloud demo',
        fields: {},
      );
      await profiles.saveCloudSnapshot(
        'profile',
        ProfileSnapshot(sourcesJson: [config.toJson()]),
      );
      final job = DvrSchedule(
        id: 'cloud-job',
        profileId: 'cloud:profile',
        sourceId: config.id,
        channelId: 'channel',
        channelName: 'Demo',
        startsAt: DateTime(2026, 11, 1),
        endsAt: DateTime(2026, 11, 1, 1),
      );
      final db = _ScheduleDb();
      final stream = await resolveScheduledRecording(
        job,
        db: db,
        store: SourceStore(),
      );
      expect(stream.url, contains('sintel'));
      expect(db.readSource, config.id);
    },
  );
  const source = SourceConfig(
    id: 'original',
    kind: SourceKind.demo,
    label: 'Demo',
    fields: {},
  );
  DvrSchedule schedule(String profile) => DvrSchedule(
    id: 'scheduled',
    sourceId: source.id,
    channelId: 'channel',
    channelName: 'My alias',
    startsAt: DateTime(2026, 11, 1),
    endsAt: DateTime(2026, 11, 1, 1),
    profileId: profile,
  );

  test(
    'recording resolves its saved owner after switching local profiles',
    () async {
      const profiles = LocalProfileStore();
      final owner = await profiles.createProfile(
        'Owner',
        0,
        snapshot: ProfileSnapshot(sourcesJson: [source.toJson()]),
      );
      final other = await profiles.createProfile('Other', 1);
      await profiles.setActive(other.id);
      final store = SourceStore();
      await store.setAll([]);
      final db = _ScheduleDb();
      final stream = await resolveScheduledRecording(
        schedule(owner.id),
        db: db,
        store: store,
      );
      expect(stream.url, contains('sintel'));
      expect(db.readSource, source.id);
    },
  );

  test(
    'deleted source or profile cannot resolve against the active provider',
    () async {
      const profiles = LocalProfileStore();
      final owner = await profiles.createProfile('Owner', 0);
      await profiles.setActive(owner.id);
      final store = SourceStore();
      await store.save(source.copyWith(id: 'different'));
      final db = _ScheduleDb();
      await expectLater(
        resolveScheduledRecording(schedule(owner.id), db: db, store: store),
        throwsA(isA<DvrException>()),
      );
      expect(db.readSource, isNull);
      await expectLater(
        resolveScheduledRecording(schedule('removed'), db: db, store: store),
        throwsA(isA<DvrException>()),
      );
    },
  );
}
