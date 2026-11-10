import 'cloud_config.dart';
import 'distribution_channel.dart';

/// TVBro's public project links and explicitly configured panel pages.
class AppLinks {
  AppLinks._();

  static const _repository = 'https://github.com/Fusion231/tvbro';
  static String? get repository => DistributionConfig.channel.isConsumptionOnly
      ? _panelPage('support#source-code')
      : _repository;
  static String? get support => DistributionConfig.channel.isConsumptionOnly
      ? _panelPage('support')
      : '$_repository/issues';
  static String? get website => DistributionConfig.channel.isConsumptionOnly
      ? _panelPage('support')
      : '$_repository#readme';

  /// These pages are served by TVBro's panel, never by the upstream project.
  static String? get privacyPolicy => _panelPage('privacy');
  static String? get deleteCloudAccount => _panelPage('delete-account');

  static String? _panelPage(String page) {
    if (!CloudConfig.hasPanel) return null;
    final panel = CloudConfig.panelUrl.trim();
    final base = Uri.parse(panel.endsWith('/') ? panel : '$panel/');
    final target = Uri.parse(page);
    return panelAccountLink(
      base
          .resolve(
            DistributionConfig.channel.allowsExternalPurchases
                ? page
                : target.replace(path: '${target.path}.html').toString(),
          )
          .toString(),
      DistributionConfig.channel,
    );
  }
}
