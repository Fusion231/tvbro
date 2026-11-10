import 'dart:async';

import 'package:flutter/material.dart';

import '../data/diagnostics_log.dart';
import '../data/expiry_cache.dart';
import '../data/playlist_expiry_notice.dart';
import '../l10n/app_localizations.dart';
import '../sources/source.dart';
import '../sources/source_config.dart';

/// Watches the active playlist without delaying catalog loading or playback.
class PlaylistExpiryNotice extends StatefulWidget {
  const PlaylistExpiryNotice({
    super.key,
    required this.config,
    required this.child,
    this.enabled = true,
    this.loadExpiry,
    this.now,
  });

  final SourceConfig config;
  final Widget child;
  final bool enabled;
  final Future<SubscriptionExpiry> Function()? loadExpiry;
  final DateTime Function()? now;

  @override
  State<PlaylistExpiryNotice> createState() => _PlaylistExpiryNoticeState();
}

class _PlaylistExpiryNoticeState extends State<PlaylistExpiryNotice>
    with WidgetsBindingObserver {
  final _cache = const ExpiryCache();
  final _store = const PlaylistExpiryNoticeStore();
  SubscriptionExpiry _expiry = const SubscriptionExpiry.unknown();
  Timer? _timer;
  int _generation = 0;
  bool _presenting = false;
  bool _refreshing = false;
  bool _paused = false;
  DialogRoute<bool>? _dialog;
  (DateTime, PlaylistExpiryNoticeKind)? _lastPresented;

  DateTime get _now => widget.now?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _paused =
        WidgetsBinding.instance.lifecycleState != null &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
    unawaited(_refresh());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ModalRoute notifies its dependents when a covering route is popped.
    if (ModalRoute.of(context)?.isCurrent ?? true) _queuePresentation();
  }

  @override
  void didUpdateWidget(PlaylistExpiryNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config.id != widget.config.id ||
        expiryConfigFingerprint(oldWidget.config) !=
            expiryConfigFingerprint(widget.config) ||
        expiryReminderDays(oldWidget.config) !=
            expiryReminderDays(widget.config) ||
        oldWidget.enabled != widget.enabled) {
      _closeDialog();
      _expiry = const SubscriptionExpiry.unknown();
      _lastPresented = null;
      unawaited(_refresh());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _paused = state != AppLifecycleState.resumed;
    if (_paused) {
      _generation++;
      _timer?.cancel();
    } else {
      if (_dialog == null) _lastPresented = null;
      unawaited(_refresh());
    }
  }

  void _closeDialog() {
    final dialog = _dialog;
    _dialog = null;
    if (dialog == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      dialog.navigator?.removeRoute(dialog);
    });
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    _closeDialog();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refresh({bool force = false}) async {
    final generation = ++_generation;
    _timer?.cancel();
    if (_paused || !widget.enabled) return;
    _refreshing = true;
    final config = widget.config;
    bool current() => mounted && generation == _generation;
    CachedExpiry? cached;
    try {
      cached = await _cache.readAny(config);
    } catch (_) {
      // Keychain failures must not prevent a live provider check.
    }
    if (!current()) return;
    var value = cached?.expiry ?? _expiry;
    final serveCached = canServeCachedExpiry(cached, force: force);
    if (serveCached) {
      DiagnosticsLog.instance.add(
        'source',
        'expiry notice from cache source=${config.label} kind=${value.kind.name}',
      );
    } else {
      try {
        final loaded = await _cache.refresh(
          config,
          force: force,
          loader: widget.loadExpiry,
        );
        if (!current()) return;
        // Revoked portal access often turns a known expiry into "unknown".
        // Keep the last dated answer until a date or explicit unlimited value
        // confirms a renewal.
        if (loaded.kind != SubscriptionExpiryKind.unknown ||
            value.date == null) {
          value = loaded;
        }
      } catch (error) {
        DiagnosticsLog.instance.add(
          'source',
          'expiry notice lookup failed: ${error.runtimeType}',
        );
      }
    }
    if (!current()) return;
    try {
      cached = await _cache.readAny(config);
    } catch (_) {}
    if (!current()) return;
    _expiry = value;
    _refreshing = false;
    _schedule(fetchedAt: cached?.fetchedAt, retryAfter: cached?.retryAfter);
    _queuePresentation();
  }

  void _schedule({DateTime? fetchedAt, DateTime? retryAfter}) {
    _timer?.cancel();
    if (_paused || !widget.enabled) return;
    final now = _now;
    var delay = _expiry.kind == SubscriptionExpiryKind.unknown
        ? kExpiryCacheUnknownTtl
        : kExpiryCacheTtl;
    final date = _expiry.date;
    if (date != null && date.difference(now) < kExpiryCacheRenewalWindow) {
      delay = kExpiryCacheUnknownTtl;
    }
    if (fetchedAt != null) delay -= now.difference(fetchedAt);
    if (retryAfter != null) delay = retryAfter.difference(now);
    if (date != null) {
      final days = expiryReminderDays(widget.config);
      for (final deadline in [
        if (days > 0) date.subtract(Duration(days: days)),
        date,
      ]) {
        final until = deadline.difference(now);
        if (until > Duration.zero && until < delay) delay = until;
      }
    }
    if (delay <= Duration.zero) delay = const Duration(seconds: 1);
    _timer = Timer(delay, () => unawaited(_refresh()));
  }

  void _queuePresentation() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_presentIfDue());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _presentIfDue() async {
    if (!widget.enabled ||
        _paused ||
        _refreshing ||
        _presenting ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }
    final config = widget.config;
    final date = _expiry.date;
    final kind = duePlaylistExpiryNotice(
      _expiry,
      reminderDays: expiryReminderDays(config),
      now: _now,
    );
    if (date == null || kind == null) return;
    if (_lastPresented == (date, kind)) return;
    final generation = _generation;
    _presenting = true;
    try {
      if (await _store.isAcknowledged(config, date, kind)) return;
      if (!mounted ||
          generation != _generation ||
          _paused ||
          !(ModalRoute.of(context)?.isCurrent ?? true)) {
        return;
      }
      final local = date.toLocal();
      final formattedDate = MaterialLocalizations.of(context)
          .formatMediumDate(local);
      final expired = kind == PlaylistExpiryNoticeKind.expired;
      final dialog = DialogRoute<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text(
            tr(expired ? 'Playlist expired' : 'Playlist expires soon'),
          ),
          content: Text(
            tr(
              expired
                  ? 'Playlist “{name}” expired on {date}.'
                  : 'Playlist “{name}” expires on {date}.',
              {'name': config.label, 'date': formattedDate},
            ),
          ),
          actions: [
            FilledButton(
              autofocus: true,
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(tr('OK')),
            ),
          ],
        ),
      );
      _dialog = dialog;
      _lastPresented = (date, kind);
      final acknowledged = await Navigator.of(
        context,
        rootNavigator: true,
      ).push(dialog);
      if (identical(_dialog, dialog)) _dialog = null;
      if (acknowledged == true) await _store.acknowledge(config, date, kind);
    } catch (error) {
      DiagnosticsLog.instance.add(
        'source',
        'expiry notice failed: ${error.runtimeType}',
      );
    } finally {
      _presenting = false;
      if (mounted && generation != _generation) _queuePresentation();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
