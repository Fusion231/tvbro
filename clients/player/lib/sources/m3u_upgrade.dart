import '../data/diagnostics_log.dart';
import 'expiry.dart';
import 'source_config.dart';
import 'xtream_source.dart';

/// Turns an M3U source that is really an Xtream panel into a real Xtream
/// config, or returns null to leave it alone.
///
/// Explicit conversion only: a working `get.php` playlist does not imply that
/// the provider permits `player_api.php`. Startup and source saving never probe
/// this endpoint. Legacy automatic callers return null without network access.
///
/// [debugApi] is threaded to [XtreamSource.debugApi] so the whole path is
/// testable without HTTP. Null in production.
///
/// Returns null — keep it as an M3U — when the URL carries no credentials, when
/// `player_api.php` doesn't authenticate, or when the panel can't be reached.
/// [onError] receives a failed verification so an explicit conversion can
/// explain the cause without changing this source or exposing raw diagnostics.
/// Failing closed matters here: this **rewrites the user's saved source**, so
/// anything short of the panel actually answering leaves it exactly as it was.
Future<SourceConfig?> upgradeM3uToXtream(
  SourceConfig m3u, {
  Future<dynamic> Function(Map<String, String> params)? debugApi,
  void Function(Object error)? onError,
  bool automatic = false,
  DateTime? now,
}) async {
  // Discovery is explicit: a valid playlist does not imply API access.
  if (automatic) return null;
  if (m3u.kind != SourceKind.m3u) return null;
  final uri = Uri.tryParse(m3u.fields['playlistUrl'] ?? '');
  if (uri == null) return null;
  final credentials = xtreamCredentialsFromUrl(uri);
  if (credentials == null) return null;

  final probe = XtreamSource(
    sourceId: m3u.id,
    host: credentials.host,
    username: credentials.username,
    password: credentials.password,
    debugApi: debugApi,
  );
  try {
    await probe.connect(); // player_api auth check; throws on failure
  } catch (e) {
    // Not a working panel → stays M3U. The type alone separates "refused" from
    // "unreachable"; the message can embed the URL, so it stays out.
    DiagnosticsLog.instance.add(
      'm3u',
      'xtream upgrade declined: player_api did not authenticate '
          '(${e.runtimeType})',
    );
    onError?.call(e);
    return null;
  } finally {
    await probe.dispose();
  }

  DiagnosticsLog.instance.add(
    'm3u',
    'upgraded to xtream: player_api authenticated, movies/series/expiry now '
        'available',
  );
  return SourceConfig(
    // Same id: the whole SQLite cache, favorites and playback positions are
    // keyed by it, so preserving it is what makes this an upgrade rather than
    // a new source that happens to look the same.
    id: m3u.id,
    kind: SourceKind.xtream,
    label: m3u.label,
    fields: {
      'host': credentials.host,
      'username': credentials.username,
      'password': credentials.password,
      // Keep URL-only expiry metadata when the panel's player API does not
      // repeat it. The original playlist URL is deliberately not retained.
      if (expiryFromPlaylistUrl(uri.toString()) case final expiry?)
        'playlistExpiryHint': expiry.toIso8601String(),
    },
    // Per-source preferences (hidden categories, catch-up overrides) describe
    // the subscription, not the protocol used to read it.
    settings: m3u.settings,
  );
}

/// Whether [config] is even worth probing — a pure pre-check so a caller can
/// skip the whole async path (and the `XtreamSource` allocation) for the many
/// sources that could never qualify.
///
/// The load-time caller runs on every app start, so "does nothing, cheaply,
/// for a plain playlist" is a requirement rather than an optimisation.
bool couldBeXtreamPanel(SourceConfig config) {
  if (config.kind != SourceKind.m3u) return false;
  final uri = Uri.tryParse(config.fields['playlistUrl'] ?? '');
  if (uri == null) return false;
  return xtreamCredentialsFromUrl(uri) != null;
}
