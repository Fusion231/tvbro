import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_links.dart';
import 'package:iptvs/data/cloud_config.dart';
import 'package:iptvs/data/distribution_channel.dart';

void main() {
  test('cloud API requires an HTTPS origin without userinfo', () {
    for (final value in [
      '',
      'http://api.example.invalid',
      'http://localhost:3000',
      'https://user:password@api.example.invalid',
      'https://api.example.invalid/rest',
      'https://api.example.invalid/?x=1',
      'https://api.example.invalid/#x',
      ' https://api.example.invalid',
      'https://api.example.invalid:0',
    ]) {
      expect(isConfiguredApiUrl(value), isFalse, reason: value);
    }
    expect(isConfiguredApiUrl('https://api.example.invalid'), isTrue);
    expect(isConfiguredApiUrl('https://api.example.invalid:8443/'), isTrue);
  });
  test('panel configuration rejects placeholders and inherited services', () {
    for (final value in [
      '',
      'not a URL',
      'https://abc.com/',
      'https://www.abc.com/',
      'https://panel.abc.com/',
      'https://iptvs.click/',
      'https://panel.iptvs.click/',
      'https://gchofficial.github.io/iptvs/',
      'https://gchofficial.github.io/iptvs',
      'http://panel.tvbro.example/',
      'https://user:password@panel.tvbro.example/',
      'https://panel.tvbro.example/?code=old',
      'https://panel.tvbro.example/#account',
    ]) {
      expect(isConfiguredPanelUrl(value), isFalse, reason: value);
    }
    expect(isConfiguredPanelUrl('https://panel.tvbro.example/'), isTrue);
    expect(isConfiguredPanelUrl('https://panel.tvbro.example/tvbro'), isTrue);
  });

  test('project, documentation and support belong to TVBro', () {
    if (DistributionConfig.channel.isConsumptionOnly) {
      final base = CloudConfig.hasPanel
          ? Uri.parse(CloudConfig.panelUrl)
          : null;
      expect(
        AppLinks.repository,
        base == null
            ? null
            : panelAccountLink(
                base.resolve('support.html#source-code').toString(),
                DistributionConfig.channel,
              ),
      );
      expect(
        AppLinks.support,
        base == null
            ? null
            : panelAccountLink(
                base.resolve('support.html').toString(),
                DistributionConfig.channel,
              ),
      );
      expect(AppLinks.website, AppLinks.support);
    } else {
      expect(AppLinks.repository, 'https://github.com/Fusion231/tvbro');
      expect(AppLinks.website, 'https://github.com/Fusion231/tvbro#readme');
      expect(AppLinks.support, 'https://github.com/Fusion231/tvbro/issues');
    }
  });

  test('consumption-only builds map TVBro panel roots and preserve custom deployments', () {
    const panel = 'https://tvbro.online:8443/panel/';
    for (final channel in DistributionChannel.values) {
      expect(
        panelUrlForChannel(panel, channel),
        channel.isConsumptionOnly ? 'https://tvbro.online:8443/play/' : panel,
      );
    }
    expect(
      panelUrlForChannel(
        'https://panel.tvbro.example/play/',
        DistributionChannel.googlePlay,
      ),
      'https://panel.tvbro.example/play/',
    );
    expect(
      panelUrlForChannel('https://tvbro.online/', DistributionChannel.appStore),
      'https://tvbro.online/play/',
    );
    expect(
      panelUrlForChannel(
        'https://panel.tvbro.example:8443/custom/panel/',
        DistributionChannel.googlePlay,
      ),
      'https://panel.tvbro.example:8443/custom/panel/',
    );
    for (final invalid in ['', 'not a URL', 'https://iptvs.click/']) {
      final panel = panelUrlForChannel(invalid, DistributionChannel.googlePlay);
      expect(isConfiguredPanelUrl(panel), isFalse);
    }
  });

  test(
    'Play pairing keeps the code and language inside the account variant',
    () {
      final panel = panelUrlForChannel(
        'https://tvbro.online/',
        DistributionChannel.googlePlay,
      );
      expect(
        pairingPanelLink(panel, 'ABCD2345', language: 'pl'),
        'https://tvbro.online/play/?code=ABCD2345&lang=pl',
      );
    },
  );

  test('panel pages preserve the configured deployment path', () {
    if (CloudConfig.hasPanel) {
      final base = CloudConfig.panelUrl.trim().replaceFirst(RegExp(r'/+$'), '');
      if (DistributionConfig.channel.isConsumptionOnly) {
        final channelName = DistributionConfig.channel.name;
        expect(
          AppLinks.privacyPolicy,
          '$base/privacy.html?channel=$channelName',
        );
        expect(
          AppLinks.deleteCloudAccount,
          '$base/delete-account.html?channel=$channelName',
        );
      } else {
        expect(AppLinks.privacyPolicy, '$base/privacy');
        expect(AppLinks.deleteCloudAccount, '$base/delete-account');
      }
    } else {
      expect(AppLinks.privacyPolicy, isNull);
      expect(AppLinks.deleteCloudAccount, isNull);
      expect(CloudConfig.isConfigured, isFalse);
    }
  });

  test(
    'ordinary builds use TVBro native API and panel without build flags',
    () {
      const apiUrl = String.fromEnvironment('TVBRO_API_URL');
      const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
      if (apiUrl.isNotEmpty || supabaseUrl.isNotEmpty) return;

      expect(
        CloudConfig.url,
        'https://api.tvbro.online',
      );
      expect(CloudConfig.anonKey, 'tvbro_public_client');
      const panel = String.fromEnvironment('PANEL_URL');
      if (panel.isEmpty) {
        expect(
          CloudConfig.panelUrl,
          panelUrlForChannel(
            'https://tvbro.online/',
            DistributionConfig.channel,
          ),
        );
        expect(CloudConfig.hasPanel, isTrue);
        if (CloudConfig.enabled) {
          expect(CloudConfig.isConfigured, isTrue);
        }
      }
    },
  );

  test(
    'explicit backends keep their configuration and require their own panel',
    () {
      const apiUrl = String.fromEnvironment('TVBRO_API_URL');
      const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
      const panel = String.fromEnvironment('PANEL_URL');
      if (apiUrl.isEmpty && supabaseUrl.isEmpty) return;

      if (apiUrl.isNotEmpty) {
        expect(CloudConfig.url, apiUrl);
        expect(CloudConfig.anonKey, 'tvbro_public_client');
      } else {
        expect(CloudConfig.url, supabaseUrl);
        expect(
          CloudConfig.anonKey,
          const String.fromEnvironment('SUPABASE_ANON_KEY'),
        );
      }
      expect(
        CloudConfig.panelUrl,
        panelUrlForChannel(panel, DistributionConfig.channel),
      );
      if (panel.isEmpty) {
        expect(CloudConfig.hasPanel, isFalse);
        expect(CloudConfig.isConfigured, isFalse);
      } else if (CloudConfig.enabled &&
          isConfiguredPanelUrl(panel) &&
          isConfiguredApiUrl(CloudConfig.url) &&
          CloudConfig.anonKey.isNotEmpty) {
        expect(CloudConfig.isConfigured, isTrue);
      }
    },
  );

  test('supporter actions use the same configured panel as pairing', () {
    expect(CloudConfig.supporterPanelUrl, CloudConfig.panelUrl);
  });

  test(
    'Play account links preserve pairing parameters and deployment paths',
    () {
      expect(
        panelAccountLink(
          'https://tvbro.online/?code=ABCD2345',
          DistributionChannel.googlePlay,
        ),
        'https://tvbro.online/play/?code=ABCD2345&channel=googlePlay',
      );
      expect(
        panelAccountLink(
          'https://panel.example/tvbro/?lang=pl&code=ABCD2345',
          DistributionChannel.googlePlay,
        ),
        'https://panel.example/tvbro/?lang=pl&code=ABCD2345&channel=googlePlay',
      );
      expect(
        panelAccountLink(
          'https://tvbro.online/?code=ABCD2345',
          DistributionChannel.appStore,
        ),
        'https://tvbro.online/play/?code=ABCD2345&channel=appStore',
      );
      for (final channel in DistributionChannel.values.where(
        (value) => !value.isConsumptionOnly,
      )) {
        expect(
          panelAccountLink('https://panel.example/tvbro/', channel),
          'https://panel.example/tvbro/',
        );
      }
      expect(
        panelAccountLink('invalid', DistributionChannel.googlePlay),
        'invalid',
      );
    },
  );

  test('cloud opt-out overrides an otherwise usable deployment', () {
    const enabled = bool.fromEnvironment(
      'TVBRO_CLOUD_ENABLED',
      defaultValue: true,
    );
    expect(CloudConfig.enabled, enabled);
    if (!enabled) expect(CloudConfig.isConfigured, isFalse);
  });
}
