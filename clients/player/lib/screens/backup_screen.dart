import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_backup.dart';
import '../data/app_database.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/parental_gate.dart';
import '../widgets/tv_text_field.dart';

/// Portable, password-encrypted backups, independent of a cloud account.
/// Returns true after restoring so the owner can discard its old app state.
class BackupScreen extends StatefulWidget {
  final AppDatabase db;

  const BackupScreen({super.key, required this.db});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  late final _service = AppBackupService(db: widget.db);
  bool _busy = false;
  String? _error;
  String? _status;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      if (!await authorizeParentalSettings(context, always: true) || !mounted) {
        return;
      }
      await action();
    } on MissingPluginException {
      _setError(
        tr(
          'A system file picker is unavailable on this device. Connect a file manager or use another device to save or open a backup.',
        ),
      );
    } on PlatformException {
      _setError(
        tr(
          'Could not open or save the backup file. Check the file manager and storage permissions, then try again.',
        ),
      );
    } on FileSystemException {
      _setError(
        tr(
          'Could not open or save the backup file. Check the file manager and storage permissions, then try again.',
        ),
      );
    } on UnsupportedError {
      _setError(
        tr(
          'A system file picker is unavailable on this device. Connect a file manager or use another device to save or open a backup.',
        ),
      );
    } catch (_) {
      _setError(tr('The backup operation failed. Try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setError(String message) {
    if (mounted) {
      setState(() {
        _error = message;
        _status = null;
      });
    }
  }

  Future<String?> _password({required bool creating}) => showDialog<String>(
    context: context,
    builder: (_) => _BackupPasswordDialog(creating: creating),
  );

  Future<void> _export() => _run(() async {
    final password = await _password(creating: true);
    if (password == null || !mounted) return;
    final bytes = await _service.exportBackup(password);
    if (!mounted) return;
    final date = DateTime.now().toIso8601String().substring(0, 10);
    final destination = await FilePicker.saveFile(
      dialogTitle: tr('Save backup'),
      fileName: 'tvbro-backup-$date.tvbro',
      type: FileType.any,
      bytes: bytes,
    );
    if (destination == null) return;
    if (!mounted) return;
    setState(
      () => _status = tr(
        'Backup saved. Keep the file and its password somewhere safe.',
      ),
    );
  });

  Future<void> _import() => _run(() async {
    final file = await FilePicker.pickFile(
      dialogTitle: tr('Open backup'),
      type: FileType.any,
    );
    if (file == null || !mounted) return;
    if ((file.lengthSync() ?? 0) > AppBackupService.maxFileBytes) {
      _fileTooLarge();
      return;
    }
    // Bound the actual stream as well: picker metadata can be stale or wrong.
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream()) {
      if (buffer.length + chunk.length > AppBackupService.maxFileBytes) {
        _fileTooLarge();
        return;
      }
      buffer.add(chunk);
    }
    if (!mounted) return;
    final password = await _password(creating: false);
    if (password == null || !mounted) return;
    final AppBackupSnapshot snapshot;
    try {
      snapshot = await _service.readBackup(buffer.takeBytes(), password);
    } catch (_) {
      _setError(tr('Incorrect password or damaged backup file.'));
      return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.panelHi,
        title: Text(tr('Restore backup?')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_summary(snapshot)),
              const SizedBox(height: 16),
              Text(
                tr(
                  'This replaces the current sources, profiles, settings, favorites and viewing history with the backup. Cloud profiles are restored locally; select or pair a cloud profile to resume sync.',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr('Restore backup')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(
      () => _status = tr('Restoring… The app will reload when it is ready.'),
    );
    try {
      await _service.restoreBackup(snapshot);
    } catch (_) {
      _setError(
        tr(
          'Could not restore the backup. Stop playback and recording, check available storage, and try again.',
        ),
      );
      return;
    }
    if (mounted) Navigator.of(context).pop(true);
  });

  void _fileTooLarge() => _setError(
    tr('Backup files can be at most {size} MB.', {
      'size': AppBackupService.maxFileBytes ~/ (1024 * 1024),
    }),
  );

  String _summary(AppBackupSnapshot snapshot) {
    final local = snapshot.createdAt.toLocal();
    final material = MaterialLocalizations.of(context);
    return tr(
      'Created: {date} {time}\nSources: {sources}\nProfiles: {profiles}\nFavorites: {favorites}',
      {
        'date': material.formatMediumDate(local),
        'time': material.formatTimeOfDay(TimeOfDay.fromDateTime(local)),
        'sources': snapshot.sourceCount,
        'profiles': snapshot.profileCount,
        'favorites': snapshot.favoriteCount,
      },
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(
        title: Text(tr('Backup & restore')),
        automaticallyImplyLeading: !_busy,
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              tr(
                'Save your sources, profiles, settings, favorites and viewing history in an encrypted portable file.',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              tr(
                'Keep the backup outside the app, for example on a USB drive or cloud drive, so it survives reinstallation. Recordings and downloaded channel or guide data are not included.',
              ),
              style: TextStyle(color: AppColors.textLo),
            ),
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                autofocus: true,
                onPressed: _busy ? null : _export,
                icon: const Icon(Icons.save_alt),
                label: Text(tr('Create backup')),
              ),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _import,
                icon: const Icon(Icons.restore),
                label: Text(tr('Restore from file')),
              ),
            ),
            if (_busy) ...[
              const SizedBox(height: 24),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(tr('Working…')),
            ],
            if (_error != null) ...[
              const SizedBox(height: 20),
              Text(_error!, style: TextStyle(color: AppColors.danger)),
            ],
            if (_status != null) ...[
              const SizedBox(height: 20),
              Text(_status!),
            ],
          ],
        ),
      ),
    ),
  );
}

class _BackupPasswordDialog extends StatefulWidget {
  final bool creating;

  const _BackupPasswordDialog({required this.creating});

  @override
  State<_BackupPasswordDialog> createState() => _BackupPasswordDialogState();
}

class _BackupPasswordDialogState extends State<_BackupPasswordDialog> {
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  void _submit() {
    final password = _password.text;
    if (widget.creating && password.length < 8) {
      setState(() => _error = tr('Use at least 8 characters.'));
      return;
    }
    if (widget.creating && password != _repeat.text) {
      setState(() => _error = tr('Passwords do not match.'));
      return;
    }
    if (password.isEmpty) {
      setState(() => _error = tr('Enter the backup password.'));
      return;
    }
    Navigator.of(context).pop(password);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: AppColors.panelHi,
    title: Text(tr(widget.creating ? 'Create backup' : 'Open backup')),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr(
                widget.creating
                    ? 'Choose a password of at least 8 characters. You will need it to restore the backup; it cannot be recovered.'
                    : 'Enter the password used when this backup was created.',
              ),
            ),
            const SizedBox(height: 16),
            TvTextField(
              controller: _password,
              label: tr('Backup password'),
              hintText: tr('Backup password'),
              obscureText: true,
              autofocus: true,
              onSubmitted: widget.creating ? null : (_) => _submit(),
            ),
            if (widget.creating) ...[
              const SizedBox(height: 12),
              TvTextField(
                controller: _repeat,
                label: tr('Repeat password'),
                hintText: tr('Repeat password'),
                obscureText: true,
                onSubmitted: (_) => _submit(),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: AppColors.danger)),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(tr('Cancel')),
      ),
      FilledButton(onPressed: _submit, child: Text(tr('Continue'))),
    ],
  );
}
