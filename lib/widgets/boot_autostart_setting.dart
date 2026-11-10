import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/device_class.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';

/// One device-wide preference shared by onboarding and settings.
class BootAutostartSetting extends StatefulWidget {
  const BootAutostartSetting({super.key, this.autofocus = false});

  final bool autofocus;

  @override
  State<BootAutostartSetting> createState() => _BootAutostartSettingState();
}

class _BootAutostartSettingState extends State<BootAutostartSetting>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('iptvs/device');
  bool? _enabled;
  bool? _permissionRequired;
  bool _loading = false;
  bool _busy = false;
  bool _focused = false;
  String? _error;

  bool get _canConfigureAutostart =>
      isTelevision && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    if (_canConfigureAutostart) {
      WidgetsBinding.instance.addObserver(this);
      _load();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    if (!_canConfigureAutostart || _loading) return;
    setState(() {
      _loading = true;
      _permissionRequired = null;
    });
    try {
      final status = await _channel.invokeMapMethod<String, dynamic>(
        'getBootAutostart',
      );
      if (status == null) throw StateError('Missing autostart status');
      if (!mounted) return;
      setState(() {
        _enabled = status['enabled'] as bool;
        _permissionRequired = status['permissionRequired'] as bool;
        _error = null;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not load autostart settings. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setEnabled(bool enabled) async {
    setState(() => _busy = true);
    try {
      await _channel.invokeMethod<void>('setBootAutostart', enabled);
      if (!mounted) return;
      setState(() {
        _enabled = enabled;
        _error = null;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not save autostart settings. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _requestPermission() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(tr('Allow TVBro to start automatically')),
        content: Text(
          tr(
            'Android needs your permission to open TVBro when your TV or box starts. In system settings, choose TVBro and turn on "Display over other apps", then return here. TVBro uses this permission for autostart.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr('Not now')),
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(tr('Open Android settings')),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _channel.invokeMethod<bool>('openBootAutostartPermission');
      if (mounted) await _load();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Open Android settings, then Apps > Special app access > Display over other apps, and allow TVBro.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_canConfigureAutostart) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          autofocus: widget.autofocus && !_loading && _enabled != null,
          onFocusChange: (value) => setState(() => _focused = value),
          tileColor: _focused ? AppColors.accent.withValues(alpha: 0.22) : null,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.tile),
            side: BorderSide(
              color: _focused ? AppColors.accent : Colors.transparent,
              width: 2,
            ),
          ),
          title: Text(tr('Start with the TV')),
          subtitle: Text(
            tr('Open TVBro automatically after your TV or box boots.'),
          ),
          value: _enabled ?? true,
          onChanged: _busy || _loading || _enabled == null ? null : _setEnabled,
        ),
        if (_enabled == true && _permissionRequired == true)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  tr(
                    'Permission required: allow TVBro to display over other apps so autostart can work.',
                  ),
                  style: const TextStyle(color: AppColors.textLo),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy || _loading ? null : _requestPermission,
                  icon: const Icon(Icons.settings_outlined),
                  label: Text(tr('Allow autostart')),
                ),
              ],
            ),
          ),
        if (_enabled == true && _permissionRequired == false)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(tr('Autostart is ready.')),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              tr(_error!),
              style: const TextStyle(color: AppColors.danger),
            ),
          ),
        if (_permissionRequired == null && _error != null)
          TextButton(
            autofocus: widget.autofocus,
            onPressed: _loading ? null : _load,
            child: Text(tr('Retry')),
          ),
      ],
    );
  }
}
