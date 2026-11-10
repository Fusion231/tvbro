import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'buffer_preset.dart';

/// Device-local choices, keyed by provider and stable content identity, never URL.
class PlaybackPreferences {
  const PlaybackPreferences({
    this.quality = 'auto',
    this.buffer,
    this.adaptiveBuffer = false,
    this.matchRefreshRate = false,
    this.aspect,
  });

  final String quality;
  final BufferPreset? buffer;
  final bool adaptiveBuffer;
  final bool matchRefreshRate;
  final String? aspect;

  PlaybackPreferences copyWith({
    String? quality,
    BufferPreset? buffer,
    bool? adaptiveBuffer,
    bool? matchRefreshRate,
    String? aspect,
  }) => PlaybackPreferences(
    quality: quality ?? this.quality,
    buffer: buffer ?? this.buffer,
    adaptiveBuffer: adaptiveBuffer ?? this.adaptiveBuffer,
    matchRefreshRate: matchRefreshRate ?? this.matchRefreshRate,
    aspect: aspect ?? this.aspect,
  );

  Map<String, Object?> toJson() => {
    'quality': quality,
    'buffer': buffer?.name,
    'adaptiveBuffer': adaptiveBuffer,
    'matchRefreshRate': matchRefreshRate,
    'aspect': aspect,
  };

  factory PlaybackPreferences.fromJson(Map<String, dynamic> json) =>
      PlaybackPreferences(
        quality: json['quality'] is String ? json['quality'] as String : 'auto',
        buffer: json['buffer'] is String
            ? bufferPresetFromName(json['buffer'] as String)
            : null,
        adaptiveBuffer: json['adaptiveBuffer'] == true,
        matchRefreshRate: json['matchRefreshRate'] == true,
        aspect: json['aspect'] is String ? json['aspect'] as String : null,
      );
}

class PlaybackPreferencesStore {
  PlaybackPreferencesStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static String key(String sourceId, String contentId) =>
      'playback_v1_${base64Url.encode(utf8.encode(jsonEncode([sourceId, contentId])))}';

  Future<PlaybackPreferences> read(String sourceId, String contentId) async {
    final raw = await _storage.read(key: key(sourceId, contentId));
    if (raw == null) return const PlaybackPreferences();
    try {
      final data = jsonDecode(raw);
      if (data is Map<String, dynamic>) {
        return PlaybackPreferences.fromJson(data);
      }
    } on FormatException {
      // A malformed local entry must not prevent opening a channel.
    }
    return const PlaybackPreferences();
  }

  Future<void> write(
    String sourceId,
    String contentId,
    PlaybackPreferences preferences,
  ) => _storage.write(
    key: key(sourceId, contentId),
    value: jsonEncode(preferences.toJson()),
  );
}

/// A real track offered by the current media. IDs are session-local; the
/// resolution/bitrate key is the durable preference used after a reconnect.
class VideoQuality {
  const VideoQuality({
    required this.id,
    required this.height,
    this.bitrate = 0,
  });

  final String id;
  final int height;
  final int bitrate;
  String get key => '$height:$bitrate';
  String get label => bitrate > 0
      ? '${height}p · ${(bitrate / 1000000).toStringAsFixed(1)} Mb/s'
      : '${height}p';

  factory VideoQuality.fromMap(Map<Object?, Object?> map) => VideoQuality(
    id: map['id']?.toString() ?? '',
    height: (map['height'] as num?)?.toInt() ?? 0,
    bitrate: (map['bitrate'] as num?)?.toInt() ?? 0,
  );
}

VideoQuality? selectVideoQuality(List<VideoQuality> tracks, String key) {
  if (key == 'auto') return null;
  final exact = tracks.where((track) => track.key == key).firstOrNull;
  if (exact != null) return exact;
  final height = int.tryParse(key.split(':').first);
  if (height == null || height <= 0) return null;
  final candidates = tracks.where((track) => track.height > 0).toList()
    ..sort((a, b) {
      final resolution = a.height.compareTo(b.height);
      return resolution != 0 ? resolution : a.bitrate.compareTo(b.bitrate);
    });
  // If a provider removes the saved rendition, use the closest lower one.
  return candidates.where((track) => track.height <= height).lastOrNull ??
      candidates.firstOrNull;
}
