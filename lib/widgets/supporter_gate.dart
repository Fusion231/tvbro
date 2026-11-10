import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/cloud_config.dart';
import '../data/supporter_access.dart';
import '../l10n/app_localizations.dart';

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
  bool _checking = false;
  bool _stillFree = false;

  Uri? get _panel {
    if (!widget.access.isConfigured) return null;
    final uri = Uri.tryParse(CloudConfig.supporterPanelUrl);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri.replace(
      queryParameters: {...uri.queryParameters, 'billing': 'plans'},
    );
  }

  Future<void> _refresh() async {
    setState(() => _checking = true);
    final allowed = await widget.access.allows(widget.feature);
    if (!mounted) return;
    if (allowed) {
      Navigator.of(context).pop(SupporterGateResult.allowed);
    } else {
      setState(() {
        _checking = false;
        _stillFree = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('Supporter features')),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('Support TVBro to unlock these conveniences:')),
        const SizedBox(height: 8),
        Text(tr('5 devices for PLN 24.99 per year, plus applicable tax')),
          const SizedBox(height: 12),
          Text(tr('Recurring recordings on selected weekdays')),
          Text(tr('Automatic settings and favorites sync between devices')),
          Text(tr('Resume movies and series from the saved position')),
          const SizedBox(height: 12),
          Text(
            tr(
              'Playback, playlists, EPG, manual recordings, one-off schedules and manual cloud sync stay free.',
            ),
          ),
          if (_panel == null) ...[
            const SizedBox(height: 12),
            Text(tr('Subscriptions are not configured in this build.')),
          ],
          if (_stillFree) ...[
            const SizedBox(height: 12),
            Text(
              tr(
                'No active supporter place on this device. Pair it and assign a place in the panel, then refresh.',
              ),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        autofocus: true,
        onPressed: () => Navigator.of(context).pop(SupporterGateResult.free),
        child: Text(
          widget.freeActionLabel ?? tr('Continue with free features'),
        ),
      ),
      if (_panel case final panel?)
        TextButton(
          onPressed: () async {
            await launchUrl(panel, mode: LaunchMode.externalApplication);
          },
          child: Text(tr('Subscription options')),
        ),
      FilledButton(
        onPressed: _checking ? null : _refresh,
        child: Text(tr(_checking ? 'Checking…' : 'Refresh access')),
      ),
    ],
  );
}
