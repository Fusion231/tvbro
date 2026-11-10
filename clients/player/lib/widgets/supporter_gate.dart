import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/cloud_config.dart';
import '../data/distribution_channel.dart';
import '../data/supporter_access.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';

enum SupporterGateResult { allowed, free, cancelled }

Future<SupporterGateResult> requireSupporterFeature(
  BuildContext context,
  SupporterFeature feature, {
  SupporterAccess? access,
  String? freeActionLabel,
}) async {
  final service = access ?? SupporterAccess.instance;
  if (await service.allows(feature)) return SupporterGateResult.allowed;
  if (!context.mounted) return SupporterGateResult.cancelled;
  return await showDialog<SupporterGateResult>(
        context: context,
        builder: (_) => _SupporterGate(
          feature: feature,
          access: service,
          freeActionLabel: freeActionLabel,
        ),
      ) ??
      SupporterGateResult.cancelled;
}

Future<bool> requireSupporter(
  BuildContext context,
  SupporterFeature feature, {
  SupporterAccess? access,
}) async =>
    await requireSupporterFeature(context, feature, access: access) ==
    SupporterGateResult.allowed;

class _SupporterGate extends StatefulWidget {
  const _SupporterGate({
    required this.feature,
    required this.access,
    this.freeActionLabel,
  });
  final SupporterFeature feature;
  final SupporterAccess access;
  final String? freeActionLabel;

  @override
  State<_SupporterGate> createState() => _SupporterGateState();
}

class _SupporterGateState extends State<_SupporterGate> {
  bool get _consumptionOnly => DistributionConfig.channel.isConsumptionOnly;

  bool _checking = false;
  String? _message;
  final _refreshFocus = FocusNode();
  final _scope = FocusScopeNode(
    directionalTraversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
  );

  @override
  void dispose() {
    _refreshFocus.dispose();
    _scope.dispose();
    super.dispose();
  }

  Uri? get _panel {
    if (!widget.access.isConfigured) return null;
    final uri = Uri.tryParse(CloudConfig.supporterPanelUrl);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    if (_consumptionOnly) return Uri.parse(CloudConfig.accountPanelUrl);
    return uri.replace(
      queryParameters: {...uri.queryParameters, 'billing': 'plans'},
    );
  }

  Future<void> _refresh() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _message = null;
    });
    try {
      final allowed = await widget.access.refresh(widget.feature);
      if (!mounted) return;
      if (allowed) {
        Navigator.of(context).pop(SupporterGateResult.allowed);
        return;
      }
      _message = _consumptionOnly
          ? 'Assign an existing Supporter place to this device in the panel, then refresh access.'
          : 'Enable Supporter for this device in the panel under Devices.';
    } catch (_) {
      if (!mounted) return;
      _message = 'Could not check access. Check your connection and try again.';
    }
    setState(() => _checking = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_checking) _refreshFocus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return FocusScope(
      node: _scope,
      child: AlertDialog(
        scrollable: true,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.star_rounded, color: AppColors.warning),
            ),
            const SizedBox(width: 14),
            const Expanded(child: Text('Supporter')),
          ],
        ),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_consumptionOnly)
                Text(
                  tr(
                    'This feature requires existing Supporter access. Pair your account and assign an existing place to this device, then refresh access.',
                  ),
                  style: text.bodyMedium,
                )
              else ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr('5 devices · PLN 24.99/year'),
                        style: text.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        tr('Plus applicable tax'),
                        style: text.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _benefit(
                  Icons.event_repeat_rounded,
                  'Recurring recordings',
                  SupporterFeature.recurringRecordings,
                ),
                _benefit(
                  Icons.sync_rounded,
                  'Settings and favorites sync',
                  SupporterFeature.automaticFavorites,
                ),
                _benefit(
                  Icons.play_circle_outline_rounded,
                  'Movie and series resume',
                  SupporterFeature.vodResume,
                ),
              ],
              const SizedBox(height: 12),
              Text(
                tr('Watching stays free.'),
                style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
              if (_panel == null || _message != null) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    tr(
                      _message ??
                          (_consumptionOnly
                              ? 'Account connection is not configured in this build.'
                              : 'Subscriptions are not configured in this build.'),
                    ),
                    style: text.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(SupporterGateResult.free),
            child: Text(widget.freeActionLabel ?? tr('Not now')),
          ),
          if (_panel case final panel?)
            OutlinedButton(
              onPressed: () async {
                await launchUrl(panel, mode: LaunchMode.externalApplication);
              },
              child: Text(
                tr(_consumptionOnly ? 'Manage existing access' : 'Open panel'),
              ),
            ),
          FilledButton.icon(
            autofocus: true,
            focusNode: _refreshFocus,
            onPressed: _checking ? null : _refresh,
            icon: _checking
                ? SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.onSurfaceVariant,
                    ),
                  )
                : const Icon(Icons.refresh_rounded, size: 20),
            label: Text(tr(_checking ? 'Checking…' : 'Refresh access')),
          ),
        ],
      ),
    );
  }

  Widget _benefit(IconData icon, String label, SupporterFeature feature) {
    final colors = Theme.of(context).colorScheme;
    final selected = widget.feature == feature;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Icon(
            icon,
            size: 22,
            color: selected ? colors.primary : colors.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              tr(label),
              style: TextStyle(
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
