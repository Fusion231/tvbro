import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/distribution_channel.dart';

void main() {
  test('unknown or missing build channel fails to development mode', () {
    expect(parseDistributionChannel(''), DistributionChannel.development);
    expect(parseDistributionChannel('typo'), DistributionChannel.development);
  });

  test('altStore parses from its exact string', () {
    expect(parseDistributionChannel('altStore'), DistributionChannel.altStore);
  });

  test('appStore parses from its exact string', () {
    expect(parseDistributionChannel('appStore'), DistributionChannel.appStore);
  });

  test('only GitHub-direct builds own the in-app updater', () {
    expect(DistributionChannel.githubDirect.ownsDirectUpdates, isTrue);
    expect(DistributionChannel.development.ownsDirectUpdates, isFalse);
    expect(DistributionChannel.googlePlay.ownsDirectUpdates, isFalse);
    expect(DistributionChannel.microsoftStore.ownsDirectUpdates, isFalse);
    expect(DistributionChannel.altStore.ownsDirectUpdates, isFalse);
    expect(DistributionChannel.appStore.ownsDirectUpdates, isFalse);
  });

  test('Google Play and App Store consume existing access without purchase promotion', () {
    for (final channel in DistributionChannel.values) {
      expect(
        channel.isConsumptionOnly,
        channel == DistributionChannel.googlePlay ||
            channel == DistributionChannel.appStore,
      );
    }
  });

  test('Store builds are Store-managed; altStore is not', () {
    expect(DistributionChannel.googlePlay.isStoreManaged, isTrue);
    expect(DistributionChannel.microsoftStore.isStoreManaged, isTrue);
    expect(DistributionChannel.appStore.isStoreManaged, isTrue);
    expect(DistributionChannel.githubDirect.isStoreManaged, isFalse);
    expect(DistributionChannel.altStore.isStoreManaged, isFalse);
  });

  test('App Store builds do not advertise external purchases', () {
    expect(DistributionChannel.appStore.allowsExternalPurchases, isFalse);
  });

  test('altStore display name', () {
    expect(DistributionChannel.altStore.displayName, 'AltStore');
  });

  test('App Store display name', () {
    expect(DistributionChannel.appStore.displayName, 'App Store');
  });

  test('Store handoff is disabled until a listing is configured', () {
    for (final channel in DistributionChannel.values) {
      expect(channel.storeUpdateUri(), isNull);
    }
  });

  test('Google Play handoff targets only the configured application', () {
    expect(
      DistributionChannel.googlePlay.storeUpdateUri(
        googlePlayApplicationId: 'app.tvbro.player',
      ),
      Uri.parse(
        'https://play.google.com/store/apps/details?id=app.tvbro.player',
      ),
    );
    for (final invalid in [
      'player',
      'app.tvbro/player',
      'app.tvbro?id=other',
    ]) {
      expect(
        DistributionChannel.googlePlay.storeUpdateUri(
          googlePlayApplicationId: invalid,
        ),
        isNull,
      );
    }
  });

  test('Microsoft Store handoff uses only an explicit product ID', () {
    expect(
      DistributionChannel.microsoftStore.storeUpdateUri(
        microsoftStoreProductId: '9TESTTVBRO01',
      ),
      Uri.parse('ms-windows-store://pdp/?productid=9TESTTVBRO01'),
    );
    for (final invalid in ['not-an-id', '9TESTTVBRO01&productid=other']) {
      expect(
        DistributionChannel.microsoftStore.storeUpdateUri(
          microsoftStoreProductId: invalid,
        ),
        isNull,
      );
    }
    expect(
      DistributionChannel.githubDirect.storeUpdateUri(
        googlePlayApplicationId: 'app.tvbro.player',
        microsoftStoreProductId: '9TESTTVBRO01',
      ),
      isNull,
    );
  });

  test('update track parser is fail-safe stable', () {
    expect(parseUpdateTrack(null), UpdateTrack.stable);
    expect(parseUpdateTrack('unknown'), UpdateTrack.stable);
    expect(parseUpdateTrack('beta'), UpdateTrack.beta);
  });
}
