import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../sources/source.dart';
import '../theme.dart';

/// First-source preparation: null is loading, true saved, and false failed.
class LibraryPreloadProgress extends StatelessWidget {
  final Map<ContentKind, bool?> stages;
  final bool connecting;
  final String? error;
  final VoidCallback? onEditSource;
  final VoidCallback? onRetry;

  const LibraryPreloadProgress({
    super.key,
    required this.stages,
    this.connecting = false,
    this.error,
    this.onEditSource,
    this.onRetry,
  });

  static const _kinds = [
    ContentKind.live,
    ContentKind.movie,
    ContentKind.series,
  ];

  @override
  Widget build(BuildContext context) {
    final completed = _kinds.where((kind) => stages[kind] != null).length;
    final finished = completed == _kinds.length;
    final failed = _kinds.any((kind) => stages[kind] == false);
    final compact = MediaQuery.sizeOf(context).width < 520;
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(compact ? 20 : 32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: compact ? 52 : 72,
                    height: compact ? 52 : 72,
                    decoration: BoxDecoration(
                      color: AppColors.panel,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child:
                        connecting && !MediaQuery.disableAnimationsOf(context)
                        ? const Padding(
                            padding: EdgeInsets.all(14),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.accent,
                            ),
                          )
                        : Icon(
                            error != null
                                ? Icons.link_off_rounded
                                : finished && !failed
                                ? Icons.video_library_rounded
                                : Icons.downloading_rounded,
                            size: compact ? 30 : 38,
                            color: AppColors.accent,
                          ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  tr('Preparing your library'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: compact ? 24 : 30,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  tr(
                    error != null
                        ? 'Check your source address and try again.'
                        : 'Saving your content now for faster browsing later.',
                  ),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textLo),
                ),
                const SizedBox(height: 24),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    connecting
                        ? tr('Checking source connection…')
                        : error != null
                        ? tr('Could not connect to the source')
                        : tr('Finished {done} of {total}', {
                            'done': completed,
                            'total': _kinds.length,
                          }),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.textLo),
                  ),
                ),
                const SizedBox(height: 8),
                if (error == null)
                  TweenAnimationBuilder<double>(
                    tween: Tween(end: completed / _kinds.length),
                    duration: appMotion(
                      context,
                      const Duration(milliseconds: 300),
                    ),
                    builder: (context, value, child) => LinearProgressIndicator(
                      value: value,
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(3),
                      color: AppColors.accent,
                      backgroundColor: AppColors.panelHi,
                    ),
                  ),
                if (error != null) ...[
                  Text(
                    tr(error!),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.warning),
                  ),
                  const SizedBox(height: 12),
                ],
                const SizedBox(height: 20),
                for (final kind in _kinds) ...[
                  _stage(context, kind),
                  if (kind != _kinds.last) const SizedBox(height: 8),
                ],
                const SizedBox(height: 20),
                if (error != null) ...[
                  if (onEditSource != null)
                    FilledButton.icon(
                      autofocus: true,
                      onPressed: onEditSource,
                      icon: const Icon(Icons.edit_outlined),
                      label: Text(tr('Back and edit source')),
                    ),
                  if (onRetry != null) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(tr('Try again')),
                    ),
                  ],
                ] else
                  Text(
                    tr(
                      finished
                          ? failed
                                ? 'Unavailable content can be retried after setup.'
                                : 'Your library is ready.'
                          : 'The app will open when loading is finished.',
                    ),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.textLo,
                      fontSize: 13,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _stage(BuildContext context, ContentKind kind) {
    final state = stages[kind];
    final waiting = connecting || error != null;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final (title, loading, icon) = switch (kind) {
      ContentKind.live => (
        'TV channels',
        'Loading channels and categories…',
        Icons.live_tv_rounded,
      ),
      ContentKind.movie => (
        'Movies',
        'Loading movies and categories…',
        Icons.movie_outlined,
      ),
      _ => (
        'Series',
        'Loading series and categories…',
        Icons.video_library_outlined,
      ),
    };
    final status = state == null
        ? waiting
              ? 'Waiting for connection'
              : loading
        : state
        ? 'Saved on this device'
        : 'Could not load. Retry after setup.';
    final indicator = state == null
        ? reduceMotion || waiting
              ? Icon(
                  Icons.hourglass_top_rounded,
                  color: waiting ? AppColors.textLo : AppColors.accent,
                )
              : const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.accent,
                  ),
                )
        : Icon(
            state ? Icons.check_circle_rounded : Icons.refresh_rounded,
            color: state ? AppColors.success : AppColors.warning,
          );
    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.panel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.line),
        ),
        child: Row(
          children: [
            ExcludeSemantics(child: Icon(icon, color: AppColors.textLo)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr(title),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    tr(status),
                    style: const TextStyle(
                      color: AppColors.textLo,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            ExcludeSemantics(
              child: SizedBox.square(
                dimension: 24,
                child: AnimatedSwitcher(
                  duration: appMotion(
                    context,
                    const Duration(milliseconds: 220),
                  ),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(scale: animation, child: child),
                  ),
                  child: Center(key: ValueKey(state), child: indicator),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
