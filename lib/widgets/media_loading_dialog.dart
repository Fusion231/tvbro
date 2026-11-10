import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// Covers provider work that happens before the details/player route exists.
/// Dismissing the dialog abandons navigation; late results and errors are ignored.
Future<T?> showMediaLoading<T>(
  BuildContext context, {
  required String message,
  required Future<T> Function() load,
}) async {
  final result = await showDialog<AsyncSnapshot<T>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _MediaLoadingDialog(message: message, load: load),
  );
  if (result == null) return null;
  if (result.hasError) {
    Error.throwWithStackTrace(result.error!, result.stackTrace!);
  }
  return result.data;
}

class _MediaLoadingDialog<T> extends StatefulWidget {
  final String message;
  final Future<T> Function() load;

  const _MediaLoadingDialog({required this.message, required this.load});

  @override
  State<_MediaLoadingDialog<T>> createState() => _MediaLoadingDialogState<T>();
}

class _MediaLoadingDialogState<T> extends State<_MediaLoadingDialog<T>> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _load() async {
    AsyncSnapshot<T> result;
    try {
      result = AsyncSnapshot.withData(
        ConnectionState.done,
        await widget.load(),
      );
    } catch (error, stack) {
      result = AsyncSnapshot.withError(ConnectionState.done, error, stack);
    }
    // A popped route remains mounted during its reverse transition. Never pop
    // the underlying series page when a request finishes just after Back.
    if (!mounted) return;
    final route = ModalRoute.of<AsyncSnapshot<T>>(context);
    if (route == null || !route.isActive) return;
    final navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop(result);
    } else {
      // An unrelated notice may be above us. Finish only this loading route.
      navigator.removeRoute(route, result);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 20),
        Text(widget.message, textAlign: TextAlign.center),
      ],
    ),
    actions: [
      TextButton(
        autofocus: true,
        onPressed: () => Navigator.of(context).pop(),
        child: Text(tr('Cancel')),
      ),
    ],
  );
}
