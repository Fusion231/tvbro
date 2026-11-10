import '../sources/source.dart';

final _resolution = RegExp(
  r'\b(8k|4320p|4k|uhd|2160p|qhd|1440p|fhd|1080[pi]|hd|720p|sd|576[pi]|480p)\b',
  caseSensitive: false,
);

int? channelResolution(String name) {
  final heights = _resolution.allMatches(name).map((match) {
    return switch (match.group(0)!.toLowerCase()) {
      '8k' || '4320p' => 4320,
      '4k' || 'uhd' || '2160p' => 2160,
      'qhd' || '1440p' => 1440,
      'fhd' || '1080p' || '1080i' => 1080,
      'hd' || '720p' => 720,
      '480p' => 480,
      _ => 576,
    };
  });
  return heights.fold<int?>(null, (a, b) => a == null || b > a ? b : a);
}

/// Only strip resolution markers. Preserve region, language, +1, codec and
/// channel number: an uncertain alternative is not an interchangeable feed.
String channelVariantIdentity(String name) => name
    .toLowerCase()
    .replaceAll(_resolution, '')
    .replaceAll(RegExp(r'\(\s*\)|\[\s*\]'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

List<Channel> lighterChannelVariants(
  Channel current,
  Iterable<Channel> channels, {
  int? currentHeight,
}) {
  final height = currentHeight ?? channelResolution(current.name);
  final identity = channelVariantIdentity(current.name);
  if (height == null || identity.isEmpty) return const [];
  final result = channels.where((channel) {
    final candidateHeight = channelResolution(channel.name);
    return channel.id != current.id &&
        candidateHeight != null &&
        candidateHeight < height &&
        channelVariantIdentity(channel.name) == identity;
  }).toList();
  result.sort(
    (a, b) => channelResolution(b.name)!.compareTo(channelResolution(a.name)!),
  );
  return result;
}
