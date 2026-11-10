import '../sources/source.dart';

class ProgrammeSearchResult {
  final String sourceId;
  final String sourceName;
  final Channel channel;
  final Programme programme;

  const ProgrammeSearchResult({
    required this.sourceId,
    required this.sourceName,
    required this.channel,
    required this.programme,
  });
}
