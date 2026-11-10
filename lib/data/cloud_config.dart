import 'distribution_channel.dart';

/// Configuration for TVBro's optional account and source synchronization.
///
/// Public builds use TVBro's deployed API and panel. These addresses and the
/// public client identifier contain no secrets; the backend authorizes each
/// session. Custom backends must provide their own panel with `PANEL_URL`.
/// `TVBRO_CLOUD_ENABLED=false` builds a player with cloud features disabled.
class CloudConfig {
  CloudConfig._();

  static const String _apiUrl = String.fromEnvironment('TVBRO_API_URL');
  static const String _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const bool _usesDefaultBackend = _apiUrl == '' && _supabaseUrl == '';

  static const bool enabled = bool.fromEnvironment(
    'TVBRO_CLOUD_ENABLED',
    defaultValue: true,
  );

  static const String _nativeApiUrl = _apiUrl != ''
      ? _apiUrl
      : _usesDefaultBackend
      ? 'https://api.tvbro.online'
      : '';

  static const String url = _nativeApiUrl != '' ? _nativeApiUrl : _supabaseUrl;

  static const String anonKey = _nativeApiUrl != ''
      ? 'tvbro_public_client'
      : String.fromEnvironment('SUPABASE_ANON_KEY');

  /// Where users go to manage their sources and claim a device's pairing code.
  ///
  /// Never send users of an explicitly configured backend to TVBro's panel.
  static const String _panelUrl = String.fromEnvironment('PANEL_URL');
  static const String _configuredPanelUrl = _panelUrl != ''
      ? _panelUrl
      : _usesDefaultBackend
      ? 'https://tvbro.online/'
      : '';

  static String get panelUrl =>
      panelUrlForChannel(_configuredPanelUrl, DistributionConfig.channel);

  /// Existing Supporter access uses this build's account connection.
  static String get supporterPanelUrl => panelUrl;

  static String get accountPanelUrl =>
      panelAccountLink(panelUrl, DistributionConfig.channel);

  static bool get hasPanel => isConfiguredPanelUrl(panelUrl);

  /// A custom build must configure both its backend and a usable panel.
  static bool get isConfigured =>
      enabled &&
      isConfiguredApiUrl(url) &&
      anonKey.trim().isNotEmpty &&
      hasPanel;
}

/// Preserve the account setup flow without exposing web purchases in Play.
String panelAccountLink(String value, DistributionChannel channel) {
  if (channel.allowsExternalPurchases) return value;
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return value;
  final path =
      uri.host.toLowerCase() == 'tvbro.online' &&
          ['', '/', '/panel', '/panel/'].contains(uri.path)
      ? '/play/'
      : uri.path;
  return uri
      .replace(
        path: path,
        queryParameters: {...uri.queryParameters, 'channel': channel.name},
      )
      .toString();
}

/// Account tokens and cloud secrets always use HTTPS, independently of IPTV.
bool isConfiguredApiUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      value == value.trim() &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      (uri.path.isEmpty || uri.path == '/') &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      uri.port > 0 &&
      uri.port <= 65535;
}

/// Play account flows stay in the consumption-only panel on the same origin.
String panelUrlForChannel(String value, DistributionChannel channel) {
  if (!channel.isConsumptionOnly || !isConfiguredPanelUrl(value)) return value;
  final uri = Uri.parse(value.trim());
  if (uri.host.toLowerCase() != 'tvbro.online' ||
      !['', '/', '/panel', '/panel/'].contains(uri.path)) {
    return value;
  }
  return uri.replace(path: '/play/').toString();
}

/// Reject placeholders and the inherited panel endpoints before any cloud init.
bool isConfiguredPanelUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return false;
  }
  final host = uri.host.toLowerCase();
  if (host == 'abc.com' ||
      host.endsWith('.abc.com') ||
      host == 'iptvs.click' ||
      host.endsWith('.iptvs.click')) {
    return false;
  }
  return !(host == 'gchofficial.github.io' &&
      (uri.path == '/iptvs' || uri.path.startsWith('/iptvs/')));
}

/// The panel link the pairing screen turns into a QR code: [panelUrl] carrying
/// the device's [code] as a `code=` query parameter, which the panel reads to
/// prefill its Pair form (`panel/src/validate.js` `pairingCodeFromUrl`).
///
/// The primary device here is a TV: entering eight characters into a phone by
/// reading them off the screen across the room is the slowest step in pairing,
/// and it is the one step the app can hand over to a camera. Scanning lands the
/// user on the panel *and* fills the field.
///
/// Pure so it can be tested, and deliberately conservative:
///
/// - An unparseable [panelUrl] (a bad `PANEL_URL` define) returns it unchanged
///   rather than throwing — the QR is a convenience, and the printed link and
///   the code beside it are the real instructions.
/// - A blank [code] leaves the code absent while a supported [language] still
///   opens the panel in the language chosen during app onboarding.
/// - Any existing query is preserved; only `code` and a supported `lang` change.
String pairingPanelLink(String panelUrl, String code, {String? language}) {
  final trimmed = code.trim();
  final uri = Uri.tryParse(panelUrl);
  if (uri == null || !uri.hasScheme) return panelUrl;
  final supportedLanguage = language == 'en' || language == 'pl';
  if (trimmed.isEmpty && !supportedLanguage) return panelUrl;
  return uri
      .replace(
        queryParameters: {
          ...uri.queryParameters,
          if (trimmed.isNotEmpty) 'code': trimmed,
          if (supportedLanguage) 'lang': language!,
        },
      )
      .toString();
}
