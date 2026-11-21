import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// Cycling avatar palette shared by the boot-time profile picker and the
/// channel list's AppBar avatar.
const kProfileAvatarColors = [
  Color(0xFF2D6BE4),
  Color(0xFFE34040),
  Color(0xFF2DBE8C),
  Color(0xFFE87C26),
  Color(0xFF8B5CF6),
  Color(0xFFE84393),
];

Color profileAvatarColor(int colorIndex) =>
    kProfileAvatarColors[colorIndex % kProfileAvatarColors.length];

/// Stable palette slot for a cloud profile, derived from its id so the colour
/// doesn't shift when the account's profile list is reordered. (Local profiles
/// store an explicit colorIndex instead.)
int profileColorIndexFor(String id) {
  var h = 0;
  for (final c in id.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return h % kProfileAvatarColors.length;
}

/// The AppBar avatar: the active profile's initial in its colour, opening a
/// dropdown with "Change profile" and (when wired) "Profile settings".
class ProfileAvatarButton extends StatelessWidget {
  final String? profileName;
  final int colorIndex;
  final VoidCallback? onChangeProfile;
  final VoidCallback? onProfileSettings;

  const ProfileAvatarButton({
    super.key,
    required this.profileName,
    required this.colorIndex,
    required this.onChangeProfile,
    required this.onProfileSettings,
  });

  @override
  Widget build(BuildContext context) {
    final name = profileName?.isNotEmpty == true ? profileName : null;
    final initial = name != null ? name[0].toUpperCase() : null;
    final color = profileAvatarColor(colorIndex);

    return PopupMenuButton<VoidCallback>(
      tooltip: name ?? tr('Profile'),
      offset: const Offset(0, 48),
      padding: EdgeInsets.zero,
      style: AppTheme.textButtonTheme.style!.copyWith(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      ),
      onSelected: (action) => action(),
      itemBuilder: (_) => [
        if (onChangeProfile case final change?)
          _ProfileMenuItem(
            autofocus: true,
            value: change,
            icon: Icons.switch_account_outlined,
            label: tr('Change profile'),
          ),
        if (onProfileSettings case final settings?)
          _ProfileMenuItem(
            autofocus: onChangeProfile == null,
            value: settings,
            icon: Icons.cloud_sync_outlined,
            label: tr('TVBro account'),
          ),
      ],
      icon: CircleAvatar(
        radius: 16,
        backgroundColor: color,
        child: initial != null
            ? Text(
                initial,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              )
            : const Icon(Icons.person_outline, color: Colors.white, size: 18),
      ),
    );
  }
}

class _ProfileMenuItem extends PopupMenuItem<VoidCallback> {
  final bool autofocus;
  final IconData icon;
  final String label;

  const _ProfileMenuItem({
    required this.autofocus,
    required this.icon,
    required this.label,
    required super.value,
  }) : super(child: null);

  @override
  PopupMenuItemState<VoidCallback, _ProfileMenuItem> createState() =>
      _ProfileMenuItemState();
}

class _ProfileMenuItemState
    extends PopupMenuItemState<VoidCallback, _ProfileMenuItem> {
  @override
  Widget build(BuildContext context) => TextButton.icon(
    autofocus: widget.autofocus,
    onPressed: handleTap,
    style: AppTheme.textButtonTheme.style!.copyWith(
      alignment: AlignmentDirectional.centerStart,
      minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
    ),
    icon: Icon(widget.icon, size: 18),
    label: Text(widget.label),
  );
}
