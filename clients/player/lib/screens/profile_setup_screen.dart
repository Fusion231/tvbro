import 'package:flutter/material.dart';

import '../app_brand.dart';
import '../data/cloud_config.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/app_appearance.dart';
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
    final name = profileName?.trim();
    return SetupContent(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            name == null || name.isEmpty
                ? tr('Choose how to get started')
                : tr('Set up {name}', {'name': name}),
            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            tr(
              'Connect your IPTV source, or explore {app} with '
              'sample channels and library content.',
              {'app': AppBrand.name},
            ),
            style: const TextStyle(color: AppColors.textLo),
          ),
          const SizedBox(height: 28),
          FocusTraversalGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SetupAction(
                  primary: true,
                  autofocus: true,
                  onPressed: () => onChoose(ProfileSetupChoice.addSource),
                  icon: Icons.add_link_rounded,
                  title: tr('Add an IPTV source'),
                  subtitle: tr('M3U playlist, Xtream Codes, or Stalker portal'),
                ),
                const SizedBox(height: 12),
                if (cloudAvailable ?? CloudConfig.isConfigured) ...[
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppAppearance.surface,
                      foregroundColor: AppColors.textHi,
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
                SetupAction(
                  onPressed: () => onChoose(ProfileSetupChoice.demo),
                  icon: Icons.play_circle_outline_rounded,
                  title: tr('Try Demo streams'),
                  subtitle: tr('Sample channels, movies, and series'),
                ),
              ],
            ),
          ),
          const BootAutostartSetting(),
        ],
      ),
    );
  }
}

class SetupAction extends StatelessWidget {
  const SetupAction({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.title,
    this.subtitle,
    this.primary = false,
    this.autofocus = false,
  });

  final VoidCallback onPressed;
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool primary;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final label = Row(
      children: [
        Icon(icon),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title),
              if (subtitle case final detail?)
                Text(detail, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        const Icon(Icons.chevron_right_rounded),
      ],
    );
    const size = Size.fromHeight(52);
    const padding = EdgeInsets.symmetric(horizontal: 14, vertical: 10);
    return primary
        ? FilledButton(
            autofocus: autofocus,
            onPressed: onPressed,
            style: FilledButton.styleFrom(minimumSize: size, padding: padding),
            child: label,
          )
        : OutlinedButton(
            autofocus: autofocus,
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(minimumSize: size, padding: padding),
            child: label,
          );
  }
}

/// Setup forms stay in one reading column on touch and sit beside artwork on TV.
class SetupContent extends StatelessWidget {
  const SetupContent({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => AppAppearance(
    child: DecoratedBox(
      decoration: AppAppearance.backdrop,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 800;
          final artwork = ClipRRect(
            borderRadius: BorderRadius.circular(AppAppearance.radius),
            child: Image.asset(
              'assets/home/live.jpg',
              width: wide ? double.infinity : 220,
              fit: BoxFit.contain,
              excludeFromSemantics: true,
            ),
          );
          return Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(wide ? 36 : 20),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: wide ? 1120 : 480),
                child: wide
                    ? Row(
                        children: [
                          Expanded(child: child),
                          const SizedBox(width: 40),
                          Expanded(child: artwork),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(child: artwork),
                          const SizedBox(height: 24),
                          child,
                        ],
                      ),
              ),
            ),
          );
        },
      ),
    ),
  );
}

/// First-run setup route. Backing out returns `null` and leaves the profile
/// without a source, so it can still be set up from Home later.
class ProfileSetupScreen extends StatelessWidget {
  final String? profileName;
  final bool? cloudAvailable;

  const ProfileSetupScreen({super.key, this.profileName, this.cloudAvailable});

  @override
  Widget build(BuildContext context) => AppAppearance(
    child: Scaffold(
      appBar: AppBar(title: Text(tr('Get started'))),
      body: SafeArea(
        top: false,
        child: ProfileSetupChoices(
          profileName: profileName,
          cloudAvailable: cloudAvailable,
          onChoose: (choice) => Navigator.of(context).pop(choice),
        ),
      ),
    ),
  );
}
