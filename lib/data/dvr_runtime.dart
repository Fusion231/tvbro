import '../dvr/dvr_scheduler.dart';
import '../dvr/dvr_service.dart';
import '../sources/source.dart';
import '../sources/source_config.dart';
import 'app_database.dart';
import 'cloud_config.dart';
import 'cloud_sync.dart';
import 'local_profile_store.dart';
import 'source_store.dart';

Future<String?> recordingProfileId(AppDatabase db) async {
  const profiles = LocalProfileStore();
  final local = await profiles.activeId();
  if (local != null) return local;
  if (!CloudConfig.isConfigured || await profiles.ownerless()) return null;
  final cloud = await CloudSync(db: db).cachedProfileId();
  return cloud == null ? null : 'cloud:$cloud';
}

/// Resolve at capture time so expiring provider links never enter the schedule.
Future<StreamInfo> resolveScheduledRecording(
  DvrSchedule schedule, {
  required AppDatabase db,
  required SourceStore store,
}) async {
  final profiles = LocalProfileStore();
  final activeId = await recordingProfileId(db);
  List<SourceConfig> sources;
  if (schedule.profileId != null && schedule.profileId != activeId) {
    ProfileSnapshot? snapshot;
    if (schedule.profileId!.startsWith('cloud:')) {
      snapshot = await profiles.cloudSnapshot(schedule.profileId!.substring(6));
    } else {
      final saved = await profiles.loadAll();
      snapshot = saved
          .where((p) => p.id == schedule.profileId)
          .firstOrNull
          ?.snapshot;
    }
    if (snapshot == null) {
      throw const DvrException(
        'The profile for this recording is no longer available.',
      );
    }
    sources = snapshot.sourcesJson.map(SourceConfig.fromJson).toList();
  } else {
    sources = await store.list();
  }
  final config = sources.where((s) => s.id == schedule.sourceId).firstOrNull;
  if (config == null) {
    throw const DvrException(
      'The source for this recording is no longer available.',
    );
  }
  final channel = await db.readChannel(schedule.sourceId, schedule.channelId);
  if (channel == null) {
    throw const DvrException(
      'The channel for this recording is no longer available.',
    );
  }
  final source = config.build();
  try {
    await source.connect();
    return await source.resolve(await db.revealChannel(channel));
  } finally {
    await source.dispose();
  }
}
