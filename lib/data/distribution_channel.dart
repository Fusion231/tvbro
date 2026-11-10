/// Who packaged the running build and therefore owns its update lifecycle.
enum DistributionChannel {
  development,
  githubDirect,
  googlePlay,
  microsoftStore,
  altStore,
  appStore,
}

DistributionChannel parseDistributionChannel(String value) {
  return switch (value.trim()) {
    'githubDirect' => DistributionChannel.githubDirect,
    'googlePlay' => DistributionChannel.googlePlay,
    'microsoftStore' => DistributionChannel.microsoftStore,
    'altStore' => DistributionChannel.altStore,
    'appStore' => DistributionChannel.appStore,
    _ => DistributionChannel.development,
  };
}

extension DistributionChannelPolicy on DistributionChannel {
  bool get ownsDirectUpdates => this == DistributionChannel.githubDirect;

  bool get allowsExternalPurchases =>
      this != DistributionChannel.googlePlay &&
      this != DistributionChannel.appStore;

  bool get isConsumptionOnly =>
      this == DistributionChannel.googlePlay ||
      this == DistributionChannel.appStore;

  bool get isStoreManaged =>
      this == DistributionChannel.googlePlay ||
      this == DistributionChannel.microsoftStore ||
      this == DistributionChannel.appStore;

  /// A published TVBro Store listing, explicitly configured by its publisher.
  /// Missing or malformed identifiers leave Store-managed updates to the OS.
  Uri? storeUpdateUri({
    String googlePlayApplicationId = '',
    String microsoftStoreProductId = '',
  }) {
    if (this == DistributionChannel.googlePlay) {
      final applicationId = googlePlayApplicationId.trim();
      if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$')
          .hasMatch(applicationId)) {
        return null;
      }
      return Uri.https('play.google.com', '/store/apps/details', {
        'id': applicationId,
      });
    }
    if (this == DistributionChannel.microsoftStore) {
      final productId = microsoftStoreProductId.trim().toUpperCase();
      if (!RegExp(r'^[A-Z0-9]{12}$').hasMatch(productId)) return null;
      return Uri(
        scheme: 'ms-windows-store',
        host: 'pdp',
        path: '/',
        queryParameters: {'productid': productId},
      );
    }
    return null;
  }

  String get displayName => switch (this) {
    DistributionChannel.development => 'Development',
    DistributionChannel.githubDirect => 'GitHub direct',
    DistributionChannel.googlePlay => 'Google Play',
    DistributionChannel.microsoftStore => 'Microsoft Store',
    DistributionChannel.altStore => 'AltStore',
    DistributionChannel.appStore => 'App Store',
  };
}

class DistributionConfig {
  const DistributionConfig._();

  static const rawChannel = String.fromEnvironment(
    'DISTRIBUTION_CHANNEL',
    defaultValue: 'development',
  );

  static final channel = parseDistributionChannel(rawChannel);

  static bool get directUpdaterEnabled => channel.ownsDirectUpdates;

  static Uri? get storeUpdateUri => channel.storeUpdateUri(
    googlePlayApplicationId: const String.fromEnvironment(
      'GOOGLE_PLAY_APPLICATION_ID',
    ),
    microsoftStoreProductId: const String.fromEnvironment(
      'MICROSOFT_STORE_PRODUCT_ID',
    ),
  );

  static bool get updateEntryEnabled =>
      directUpdaterEnabled || storeUpdateUri != null;
}

/// GitHub-direct users may opt into signed prereleases. Store builds use Play
/// testing tracks or Partner Center package flights instead.
enum UpdateTrack { stable, beta }

UpdateTrack parseUpdateTrack(String? value) =>
    value == 'beta' ? UpdateTrack.beta : UpdateTrack.stable;

extension UpdateTrackLabel on UpdateTrack {
  String get storageValue => name;
  String get displayName => this == UpdateTrack.beta ? 'Beta' : 'Stable';
}
