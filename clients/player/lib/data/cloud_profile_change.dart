/// Which part of a cloud profile needs to be downloaded after a notification.
enum CloudProfileChange { profile, playback }

/// A partial old Realtime row can use the last complete notification for this
/// profile. Without that baseline, the observer keeps its full-profile catch-up.
/// Configuration revisions and favorites must both remain unchanged.
CloudProfileChange classifyCloudProfileChange(
  Map<String, dynamic> previous,
  Map<String, dynamic> current, {
  Map<String, dynamic>? lastKnownRecord,
}) {
  const requiredFields = [
    'id',
    'name',
    'position',
    'pin',
    'favorites',
    'updated_at',
    'playback_revision',
  ];
  bool complete(Map<String, dynamic> record) =>
      requiredFields.every(record.containsKey);
  if (!complete(current)) return CloudProfileChange.profile;
  if (!complete(previous)) {
    final baseline = lastKnownRecord;
    if (baseline == null ||
        !complete(baseline) ||
        baseline['id'] != current['id'] ||
        (previous.containsKey('id') && previous['id'] != current['id'])) {
      return CloudProfileChange.profile;
    }
    previous = baseline;
  }
  if (previous['id'] != current['id']) {
    return CloudProfileChange.profile;
  }
  final before = int.tryParse('${previous['playback_revision']}');
  final after = int.tryParse('${current['playback_revision']}');
  if (before == null ||
      after == null ||
      after <= before ||
      previous['id'] is! String ||
      previous['updated_at'] is! String ||
      previous['favorites'] is! List ||
      current['favorites'] is! List) {
    return CloudProfileChange.profile;
  }
  final fields = {...previous.keys, ...current.keys}
    ..remove('playback_revision');
  for (final field in fields) {
    if (!previous.containsKey(field) ||
        !current.containsKey(field) ||
        !_sameValue(previous[field], current[field])) {
      return CloudProfileChange.profile;
    }
  }
  return CloudProfileChange.playback;
}

bool _sameValue(Object? previous, Object? current) {
  if (previous is List && current is List) {
    if (previous.length != current.length) return false;
    for (var index = 0; index < previous.length; index++) {
      if (!_sameValue(previous[index], current[index])) return false;
    }
    return true;
  }
  if (previous is Map && current is Map) {
    return previous.length == current.length &&
        previous.keys.every(
          (key) =>
              current.containsKey(key) &&
              _sameValue(previous[key], current[key]),
        );
  }
  return previous == current;
}
