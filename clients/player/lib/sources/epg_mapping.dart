import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'epg_matching.dart';
import 'source.dart';

/// A device-local, explicitly saved override for a stable provider channel.
class EpgChannelOverride {
  final String channelId;
  final String? guideId;
  final String? guideChannelId;
  final int offsetMinutes;

  const EpgChannelOverride({
    required this.channelId,
    this.guideId,
    this.guideChannelId,
    this.offsetMinutes = 0,
  });

  bool get hasBinding => guideId != null && guideChannelId != null;
}

/// A guide declaration, including channels that matched no provider channel.
/// The URL is deliberately absent: guide locators often contain credentials.
class EpgGuideChannel {
  final String guideId;
  final String guideLabel;
  final String channelId;
  final List<String> displayNames;

  const EpgGuideChannel({
    required this.guideId,
    required this.guideLabel,
    required this.channelId,
    this.displayNames = const [],
  });

  String get name => displayNames.isEmpty ? channelId : displayNames.first;
}

String epgGuideId(String sourceId, String url) =>
    sha256.convert(utf8.encode(jsonEncode([sourceId, url]))).toString();

/// Optional capability; providers without XMLTV still support time corrections
/// in the repository, without implementing this interface.
abstract interface class MappedEpgSource {
  EpgMappingSession get epgMapping;
}

class EpgMappingSession {
  List<EpgChannelOverride> _overrides = const [];
  Set<String> _reserved = const {};
  final List<EpgGuideChannel> catalogue = [];

  void begin(List<EpgChannelOverride> overrides) {
    _overrides = overrides;
    _reserved = overrides
        .where((item) => item.hasBinding)
        .map((item) => item.channelId)
        .toSet();
    catalogue.clear();
  }

  /// Explicitly bound channels are excluded from all other guide claims,
  /// including an earlier guide that would normally win the merge.
  Map<String, List<String>> indexFor(
    Map<String, List<String>> index,
    String guideId, {
    bool names = false,
  }) {
    final bindings = _overrides.where((item) => item.hasBinding).toList();
    if (bindings.isEmpty) return index;
    final out = <String, List<String>>{};
    for (final entry in index.entries) {
      final ids = entry.value.where((id) => !_reserved.contains(id)).toList();
      if (ids.isNotEmpty) out[entry.key] = ids;
    }
    if (!names) {
      for (final binding in bindings) {
        if (binding.guideId == guideId) {
          (out[binding.guideChannelId!] ??= []).add(binding.channelId);
        }
      }
    }
    return out;
  }

  bool allowsPortalChannel(String channelId) => !_reserved.contains(channelId);

  bool requiresGuide(String guideId) =>
      _overrides.any((item) => item.hasBinding && item.guideId == guideId);

  void validateGuides(Iterable<String> guideIds) {
    final available = guideIds.toSet();
    if (_overrides.any(
      (item) => item.hasBinding && !available.contains(item.guideId),
    )) {
      throw StateError(
        'A manually selected EPG guide is no longer configured. Reset its channel mapping.',
      );
    }
  }

  void addCatalogue(
    String guideId,
    String label,
    Map<String, List<String>> channels,
  ) {
    for (final override in _overrides) {
      if (override.guideId == guideId &&
          !channels.containsKey(override.guideChannelId)) {
        throw StateError(
          'A manually selected channel is no longer present in its EPG guide. Reset its mapping.',
        );
      }
    }
    catalogue.addAll([
      for (final entry in channels.entries)
        EpgGuideChannel(
          guideId: guideId,
          guideLabel: label,
          channelId: entry.key,
          displayNames: entry.value,
        ),
    ]);
  }
}

class EpgMappingSuggestion {
  final EpgGuideChannel candidate;
  final double score;
  const EpgMappingSuggestion(this.candidate, this.score);
}

/// Bounded edit-distance suggestions only. No caller applies these implicitly.
List<EpgMappingSuggestion> suggestEpgMappings(
  Channel channel,
  Iterable<EpgGuideChannel> catalogue, {
  int limit = 8,
}) {
  final target = normalizeChannelName(channel.name);
  if (target.isEmpty || limit <= 0) return const [];
  final suggestions = <EpgMappingSuggestion>[];
  for (final candidate in catalogue) {
    var best = 0.0;
    for (final name in [candidate.channelId, ...candidate.displayNames]) {
      final key = normalizeChannelName(name);
      if (key.isEmpty || (key.length - target.length).abs() > 8) continue;
      // Keep work bounded even for malformed, enormous display-name fields.
      final a = target.length > 80 ? target.substring(0, 80) : target;
      final b = key.length > 80 ? key.substring(0, 80) : key;
      final score =
          1 - _distance(a, b) / (a.length > b.length ? a.length : b.length);
      if (score > best) best = score;
    }
    if (best < 0.55) continue;
    suggestions.add(EpgMappingSuggestion(candidate, best));
    suggestions.sort((a, b) {
      final score = b.score.compareTo(a.score);
      if (score != 0) return score;
      return '${a.candidate.guideId}/${a.candidate.channelId}'.compareTo(
        '${b.candidate.guideId}/${b.candidate.channelId}',
      );
    });
    if (suggestions.length > limit) suggestions.removeLast();
  }
  return suggestions;
}

int _distance(String a, String b) {
  var previous = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 0; i < a.length; i++) {
    final row = <int>[i + 1];
    for (var j = 0; j < b.length; j++) {
      final insert = row[j] + 1;
      final delete = previous[j + 1] + 1;
      final replace = previous[j] + (a[i] == b[j] ? 0 : 1);
      row.add([insert, delete, replace].reduce((a, b) => a < b ? a : b));
    }
    previous = row;
  }
  return previous.last;
}
