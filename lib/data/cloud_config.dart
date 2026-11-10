/// Configuration for the optional TVBro cloud source panel.
///
/// The API URL and public client identifier are safe to ship in the app:
/// access is gated entirely by row-level security in `supabase/migrations`. The
/// `service_role` key must never appear here. Values come from `--dart-define`
/// at build time (see `supabase/README.md`); when unset, cloud sync is simply
/// hidden and the app behaves exactly as before.
class CloudConfig {
  CloudConfig._();

  static const String _apiUrl = String.fromEnvironment('TVBRO_API_URL');
  static const String url = _apiUrl != ''
      ? _apiUrl
      : String.fromEnvironment('SUPABASE_URL');

  static const String anonKey = _apiUrl != ''
      ? 'tvbro_public_client'
      : String.fromEnvironment('SUPABASE_ANON_KEY');

  /// Where users go to manage their sources and claim a device's pairing code.
  ///
  /// Replace the placeholder with TVBro's deployed panel using `PANEL_URL`.
  /// Until then cloud initialization, pairing and panel links stay disabled.
  static const String panelUrl = String.fromEnvironment(
    'PANEL_URL',
    defaultValue: 'https://abc.com/',
  );

  /// Paid actions must use this build's own explicitly configured panel.
  static const String supporterPanelUrl = String.fromEnvironment('PANEL_URL');

  static bool get hasPanel => isConfiguredPanelUrl(panelUrl);

  /// A build must explicitly configure its own backend and a usable panel.
  static bool get isConfigured =>
      url.trim().isNotEmpty && anonKey.trim().isNotEmpty && hasPanel;
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
/// - A blank [code] returns the plain panel URL, so a QR rendered while the
///   code is still being requested points somewhere useful instead of
///   advertising an empty parameter.
/// - Any existing query is preserved; only `code` is replaced.
String pairingPanelLink(String panelUrl, String code) {
  final trimmed = code.trim();
  final uri = Uri.tryParse(panelUrl);
  if (uri == null || !uri.hasScheme) return panelUrl;
  if (trimmed.isEmpty) return panelUrl;
  return uri
      .replace(queryParameters: {...uri.queryParameters, 'code': trimmed})
      .toString();
}
