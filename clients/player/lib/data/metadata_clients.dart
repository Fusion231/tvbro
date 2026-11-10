import 'mdblist_client.dart';
import 'metadata_config.dart';
import 'metadata_provider.dart';
import 'tmdb_client.dart';
import 'tvdb_client.dart';
import 'tvmaze_client.dart';

/// Shared by every account tier; TVmaze needs no stored credentials.
List<MetadataProvider> buildMetadataProviders(
  MetadataConfig config, {
  String language = 'eng',
}) {
  final visual = <MetadataProvider>[
    if (config.hasTmdb) TmdbClient(apiKey: config.tmdbApiKey),
    if (config.hasTvdb)
      TvdbClient(
        apiKey: config.tvdbApiKey,
        pin: config.tvdbPin,
        language: language,
      ),
  ];
  return [
    ...config.preferredVisualProvider == 'tvdb' ? visual.reversed : visual,
    TvmazeClient(),
    if (config.hasMdblist) MdblistClient(apiKey: config.mdblistApiKey),
  ];
}
