import 'package:flutter/material.dart';

import '../app_brand.dart';
import '../data/cloud_config.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/boot_autostart_setting.dart';

enum ProfileSetupChoice { addSource, cloud, demo }

/// Shared first-source choices for a new profile and its empty HomeShell.
class ProfileSetupChoices extends StatelessWidget {
  final String? profileName;
  final bool? cloudAvailable;
  final ValueChanged<ProfileSetupChoice> onChoose;

  const ProfileSetupChoices({
    super.key,
    this.profileName,
    this.cloudAvailable,
    required this.onChoose,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 520;
    final name = profileName?.trim();
    return SingleChildScrollView(
      padding: EdgeInsets.all(compact ? 20 : 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: AppColors.panel,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.line),
                ),
                child: const Icon(
                  Icons.live_tv_rounded,
                  size: 44,
                  color: AppColors.accent,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                name == null || name.isEmpty
                    ? tr('Choose how to get started')
                    : tr('Set up {name}', {'name': name}),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                tr(
                  'Connect your IPTV source, or explore {app} with '
                  'sample channels and library content.',
                  {'app': AppBrand.name},
                ),
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textLo),
              ),
              const SizedBox(height: 28),
              const BootAutostartSetting(),
              FocusTraversalGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(64),
                      ),
                      autofocus: true,
                      onPressed: () => onChoose(ProfileSetupChoice.addSource),
                      icon: const Icon(Icons.add_link_rounded),
                      label: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(tr('Add an IPTV source')),
                          Text(
                            tr('M3U playlist, Xtream Codes, or Stalker portal'),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (cloudAvailable ?? CloudConfig.isConfigured) ...[
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(64),
                        ),
                        onPressed: () => onChoose(ProfileSetupChoice.cloud),
                        icon: const Icon(Icons.cloud_download_outlined),
                        label: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(tr('Download from cloud')),
                            Text(
                              tr(
                                'Sign in and restore your saved profile, playlists, and settings.',
                              ),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(64),
                      ),
                      onPressed: () => onChoose(ProfileSetupChoice.demo),
                      icon: const Icon(Icons.play_circle_outline_rounded),
                      label: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(tr('Try Demo streams')),
                          Text(
                            tr('Sample channels, movies, and series'),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// First-run setup route. Backing out returns `null` and leaves the profile
/// without a source, so it can still be set up from Home later.
class ProfileSetupScreen extends StatelessWidget {
  final String? profileName;
  final bool? cloudAvailable;

  const ProfileSetupScreen({super.key, this.profileName, this.cloudAvailable});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr('Get started'))),
    body: SafeArea(
      top: false,
      child: ProfileSetupChoices(
        profileName: profileName,
        cloudAvailable: cloudAvailable,
        onChoose: (choice) => Navigator.of(context).pop(choice),
      ),
    ),
  );
}
