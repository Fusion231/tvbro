import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart' show KeyRepeatEvent;

import '../l10n/app_localizations.dart';
import '../data/app_database.dart';
import '../data/device_class.dart';
import '../data/distribution_channel.dart';
import '../data/cloud_config.dart';
import '../data/diagnostics_log.dart';
import '../data/expiry_cache.dart';
import '../data/local_profile_store.dart';
import '../data/metadata_config.dart';
import '../data/net.dart';
import '../data/source_store.dart';
import '../data/update_service.dart';
import '../data/update_store.dart';
import '../sources/source_config.dart';
import '../sources/source.dart';
import '../theme.dart';
import '../widgets/app_bar_action.dart';
import '../widgets/boot_autostart_setting.dart';
import '../widgets/focusable_card.dart';
import '../widgets/parental_gate.dart';
import '../widgets/tv_text_field.dart';
import 'backup_screen.dart';
import 'cloud_sync_screen.dart';
import 'diagnostics_screen.dart';
import 'legal_screen.dart';
import 'profile_pick_screen.dart';
import 'source_settings_screen.dart';
import 'update_flow.dart';

IconData _kindIcon(SourceKind k) {
  switch (k) {
    case SourceKind.stalker:
      return Icons.router_outlined;
    case SourceKind.xtream:
      return Icons.cloud_outlined;
    case SourceKind.m3u:
      return Icons.playlist_play;
    case SourceKind.demo:
      return Icons.play_circle_outline;
  }
}

Future<bool?> showAppSettingsPanel({
  required BuildContext context,
  required SourceStore store,
  required AppDatabase db,
  VoidCallback? onSourceSettings,
  VoidCallback? onEpgMapping,
}) => showGeneralDialog<bool>(
  context: context,
  barrierDismissible: true,
  barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
  barrierColor: Colors.black54,
  transitionDuration: appMotion(context, const Duration(milliseconds: 220)),
  pageBuilder: (context, animation, secondaryAnimation) {
    final width = MediaQuery.sizeOf(context).width;
    return Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        key: const ValueKey('app-settings-panel'),
        width: width < 720 ? width : 480,
        height: double.infinity,
        child: _AppSettingsScreen(
          store: store,
          db: db,
          onSourceSettings: onSourceSettings,
          onEpgMapping: onEpgMapping,
        ),
      ),
    );
  },
  transitionBuilder: (context, animation, secondaryAnimation, child) =>
      SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        ),
        child: child,
      ),
);

/// Lists saved providers; lets you add, edit, delete, and pick the active one.
class SourcesScreen extends StatefulWidget {
  final SourceStore store;
  final AppDatabase db;
  const SourcesScreen({super.key, required this.store, required this.db});

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  List<SourceConfig> _sources = const [];
  String? _activeId;
  bool _loading = true;

  // One focus node per source row, so we can land focus back on a specific
  // card after returning from the edit/add route (otherwise Navigator restores
  // focus to the Edit icon the user activated).
  final Map<String, FocusNode> _cardFocus = {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    for (final node in _cardFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  FocusNode _focusNodeFor(String id) =>
      _cardFocus.putIfAbsent(id, () => FocusNode());

  void _focusCard(String? id) {
    if (id == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _cardFocus[id]?.requestFocus();
    });
  }

  Future<void> _reload() async {
    final list = await widget.store.list();
    final active = await widget.store.activeId();
    if (!mounted) return;
    setState(() {
      _sources = list;
      _activeId = active;
      _loading = false;
    });
  }

  Future<void> _add() async {
    final before = _sources.map((s) => s.id).toSet();
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => EditSourceScreen(store: widget.store)),
    );
    if (saved != true) return;
    await _reload();
    // Land focus on the newly added source row (fall back to the first card).
    final added = _sources
        .map((s) => s.id)
        .firstWhere((id) => !before.contains(id), orElse: () => '');
    _focusCard(
      added.isNotEmpty
          ? added
          : (_sources.isNotEmpty ? _sources.first.id : null),
    );
  }

  Future<void> _edit(SourceConfig c) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EditSourceScreen(store: widget.store, existing: c),
      ),
    );
    if (saved != true) return;
    await _reload();
    _focusCard(c.id);
  }

  Future<void> _openSettings(SourceConfig c) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            SourceSettingsScreen(store: widget.store, db: widget.db, config: c),
      ),
    );
    // Settings are saved as they're toggled; refresh so the card reflects them.
    await _reload();
    _focusCard(c.id);
  }

  Future<void> _openAppSettings() async {
    final previousFocus = FocusManager.instance.primaryFocus;
    final restored = await showAppSettingsPanel(
      context: context,
      store: widget.store,
      db: widget.db,
    );
    // The old shell must discard its profile and source snapshots before
    // anything can write them over the restored state.
    if (!mounted) return;
    if (restored == true) {
      Navigator.of(context).pop(true);
      return;
    }
    await _reload();
    if (mounted && previousFocus?.context != null) {
      previousFocus!.requestFocus();
    }
  }

  Future<void> _activate(SourceConfig c) async {
    // Fail closed: never activate a source with missing credentials (e.g. a
    // cloud pull left it locked because this device is E2EE-locked, or the
    // secret was never provisioned). Playback would fail anyway.
    if (sourceCredentialsMissing(c)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              'This source is missing its credentials. Unlock this profile in '
              'the panel (or edit the source) before activating it.',
            ),
          ),
          duration: Duration(seconds: 4),
        ),
      );
      return;
    }
    await widget.store.setActive(c.id);
    await _reload();
  }

  /// Move a source one slot up (delta -1) or down (delta +1) and persist the new
  /// order. Keeps the active selection and refocuses the moved row. Note: cloud
  /// sync orders cloud-managed sources from the panel on the next pull, so this
  /// is most useful for the order among local-only sources.
  Future<void> _move(SourceConfig c, int delta) async {
    final i = _sources.indexWhere((s) => s.id == c.id);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= _sources.length) return;
    final list = List<SourceConfig>.of(_sources);
    list.insert(j, list.removeAt(i));
    await widget.store.setAll(list);
    await _reload();
    _focusCard(c.id);
  }

  Future<void> _delete(SourceConfig c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.panelHi,
        title: Text(tr('Delete source?')),
        content: Text(tr('Remove "{name}"?', {'name': c.label})),
        actions: [
          TextButton(
            // Autofocus the *non*-destructive action: on a D-pad an
            // unfocused dialog swallows the first OK press entirely, so the
            // user has to blind-hunt with arrows before anything responds.
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Delete')),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.store.delete(c.id);
      // The cached expiry describes a source that no longer exists. It would
      // age out on its own, but a re-added source can reuse nothing here (ids
      // are freshly minted) so there is no reason to keep it around.
      await const ExpiryCache().forget(c.id);
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Sources')),
        actions: [
          AppBarAction(
            label: tr('Settings'),
            icon: Icons.settings_outlined,
            onPressed: _openAppSettings,
          ),
          const SizedBox(width: 4),
        ],
      ),
      // A FilledButton (rather than a FAB) so it shows the same accent/white
      // focus ring as the "Save source" / "Save" buttons under a D-pad.
      // Autofocus it once loaded with no sources — the first source card
      // already autofocuses (see _buildSourceList), so this is the only
      // D-pad target on a fresh install's first "Sources" visit. Gated on
      // !_loading so it doesn't grab focus during the spinner frame and then
      // block the first card's own autofocus once sources arrive.
      floatingActionButton: FilledButton.icon(
        autofocus: !_loading && _sources.isEmpty,
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: Text(tr('Add source')),
      ),
      // Edge-to-edge (targetSdk 35+): the Scaffold already keeps the FAB clear of
      // the system bar, but the body underneath it does not inset itself.
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _sources.isEmpty
            ? Center(
                child: Text(
                  tr('No sources yet — add one'),
                  style: TextStyle(color: AppColors.textLo),
                ),
              )
            : _buildSourceList(),
      ),
    );
  }

  Widget _buildSourceList() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
      scrollCacheExtent: const ScrollCacheExtent.pixels(800),
      itemCount: _sources.length,
      itemBuilder: (context, i) {
        final c = _sources[i];
        return _SourceCard(
          key: ValueKey(c.id),
          config: c,
          active: c.id == _activeId,
          autofocus: i == 0,
          focusNode: _focusNodeFor(c.id),
          canMoveUp: i > 0,
          canMoveDown: i < _sources.length - 1,
          onActivate: () => _activate(c),
          onMoveUp: () => _move(c, -1),
          onMoveDown: () => _move(c, 1),
          onSettings: () => _openSettings(c),
          onEdit: () => _edit(c),
          onDelete: () => _delete(c),
        );
      },
    );
  }
}

class _AppSettingsScreen extends StatelessWidget {
  final SourceStore store;
  final AppDatabase db;
  final VoidCallback? onSourceSettings;
  final VoidCallback? onEpgMapping;

  const _AppSettingsScreen({
    required this.store,
    required this.db,
    this.onSourceSettings,
    this.onEpgMapping,
  });

  Future<void> _openBackup(BuildContext context) async {
    if (!await authorizeParentalSettings(context) || !context.mounted) return;
    final restored = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => BackupScreen(db: db)));
    if (restored == true && context.mounted) Navigator.of(context).pop(true);
  }

  Widget _link({
    required String title,
    required IconData icon,
    required VoidCallback onTap,
    String? subtitle,
    bool autofocus = false,
  }) => FocusableCard(
    autofocus: autofocus,
    centerOnFocus: false,
    onTap: onTap,
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: Icon(icon, color: AppColors.textLo),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style: const TextStyle(color: AppColors.textLo)),
      trailing: const Icon(Icons.chevron_right, color: AppColors.textLo),
    ),
  );

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
    child: Text(
      tr(title),
      style: const TextStyle(
        fontSize: 13,
        color: AppColors.textLo,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final hasAutostart =
        isTelevision && defaultTargetPlatform == TargetPlatform.android;
    return Scaffold(
      backgroundColor: AppColors.ink,
      appBar: AppBar(
        leading: BackButton(onPressed: () => Navigator.of(context).pop()),
        title: Text(tr('Settings')),
        backgroundColor: AppColors.ink,
        scrolledUnderElevation: 0,
        shape: const Border(bottom: BorderSide(color: AppColors.line)),
      ),
      body: SafeArea(
        top: false,
        child: FocusTraversalGroup(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              if (hasAutostart) ...[
                _section('Startup'),
                Material(
                  color: AppColors.panel,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.tile),
                    side: const BorderSide(color: AppColors.line),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: const BootAutostartSetting(autofocus: true),
                ),
              ],
              if (onSourceSettings != null || onEpgMapping != null)
                _section('Channels & EPG'),
              if (onSourceSettings case final open?)
                _link(
                  autofocus: !hasAutostart,
                  title: tr('Source settings'),
                  subtitle: tr('Channels, groups and playback'),
                  icon: Icons.tune,
                  onTap: open,
                ),
              if (onEpgMapping case final open?)
                _link(
                  autofocus: !hasAutostart && onSourceSettings == null,
                  title: tr('EPG mapping'),
                  subtitle: tr('Match guide data and correct programme times'),
                  icon: Icons.event_note_outlined,
                  onTap: open,
                ),
              _section('Profiles & data'),
              _link(
                autofocus:
                    !hasAutostart &&
                    onSourceSettings == null &&
                    onEpgMapping == null,
                title: tr('Profiles'),
                icon: Icons.switch_account_outlined,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (ctx) => ProfilePickScreen(
                      db: db,
                      store: store,
                      onDone: () => Navigator.of(ctx).pop(),
                    ),
                  ),
                ),
              ),
              if (CloudConfig.isConfigured)
                _link(
                  title: tr('Cloud sync'),
                  icon: Icons.cloud_sync_outlined,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => CloudSyncScreen(store: store, db: db),
                    ),
                  ),
                ),
              _link(
                title: tr('Backup & restore'),
                subtitle: tr('Save or restore an encrypted backup file'),
                icon: Icons.backup_outlined,
                onTap: () => _openBackup(context),
              ),
              _section('Help & updates'),
              if (DistributionConfig.updateEntryEnabled) const _UpdateCard(),
              _link(
                title: tr('Diagnostics'),
                icon: Icons.receipt_long_outlined,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DiagnosticsScreen()),
                ),
              ),
              _link(
                title: tr('Privacy & support'),
                icon: Icons.info_outline,
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const LegalScreen())),
              ),
              const SizedBox(height: 20),
              ExpansionTile(
                shape: const Border(),
                collapsedShape: const Border(),
                title: Text(tr('Advanced settings')),
                leading: const Icon(Icons.tune, color: AppColors.textLo),
                childrenPadding: const EdgeInsets.only(top: 4),
                children: [
                  _link(
                    title: tr('Metadata'),
                    subtitle: tr('Posters, ratings and descriptions'),
                    icon: Icons.auto_awesome_outlined,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            MetadataSettingsScreen(store: store, db: db),
                      ),
                    ),
                  ),
                  const _PickerStartupCard(),
                  if (DistributionConfig.directUpdaterEnabled)
                    const _UpdateTrackCard(),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SourceCard extends StatefulWidget {
  final SourceConfig config;
  final bool active;
  final bool autofocus;
  final FocusNode? focusNode;
  final bool canMoveUp;
  final bool canMoveDown;
  final VoidCallback onActivate;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onSettings;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _SourceCard({
    required this.config,
    required this.active,
    required this.autofocus,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onActivate,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onSettings,
    required this.onEdit,
    required this.onDelete,
    this.focusNode,
    super.key,
  });

  @override
  State<_SourceCard> createState() => _SourceCardState();
}

class _SourceCardState extends State<_SourceCard> {
  // Up/Down walk the source rows; Right opens access to the row's menu.
  final FocusNode _menuNode = FocusNode(skipTraversal: true);
  final MenuController _menuController = MenuController();
  LocalHistoryEntry? _menuHistory;

  final ExpiryCache _expiryCache = const ExpiryCache();

  /// Generation guard for [_fetchExpiry], following the same convention as
  /// `MediaTabController`/`LiveController` (CLAUDE.md, "Async publishes are
  /// generation-guarded").
  ///
  /// `didUpdateWidget` re-fetches whenever the config changes, so an edit can
  /// start a second fetch while the first is still in flight — and the first
  /// now describes credentials that are no longer current. Without this the
  /// slower of the two wins the badge *and* the cache entry, which is the
  /// worst possible pairing: a wrong answer, persisted.
  int _expiryGeneration = 0;

  SubscriptionExpiry _expiry = const SubscriptionExpiry.unknown();
  bool _expiryLoading = true;
  bool _expiryFailed = false;

  @override
  void initState() {
    super.initState();
    _fetchExpiry();
  }

  /// Loads the expiry badge, preferring the device-local cache.
  ///
  /// Every card builds its own `Source` and asks the provider directly, so an
  /// uncached sources screen is one full portal round trip *per card*, on every
  /// visit — and for Stalker that is now a handshake plus `get_profile` plus
  /// `get_main_info`, since the badge has to authorize before the portal will
  /// answer (see `StalkerSource.subscriptionExpiry`). A subscription end date
  /// changes when the user renews and at no other time, so re-asking on every
  /// screen open buys nothing.
  ///
  /// A fresh entry renders with no network at all. A stale one still renders
  /// immediately and is revalidated behind the badge: it is almost certainly
  /// still correct, and showing it beats a spinner on a screen whose whole job
  /// is to tell you about sources at a glance.
  Future<void> _fetchExpiry({bool force = false}) async {
    final generation = ++_expiryGeneration;
    bool current() => mounted && generation == _expiryGeneration;
    final config = widget.config;
    CachedExpiry? cached;
    try {
      cached = await _expiryCache.readAny(config);
    } catch (_) {
      // Cache unavailable (locked keychain, corrupt blob) — just ask.
    }
    if (!current()) {
      return;
    }
    final entry = cached;
    final fresh = canServeCachedExpiry(entry, force: force);
    setState(() {
      if (entry != null) _expiry = entry.expiry;
      // Only spin when there is nothing at all to show.
      _expiryLoading = entry == null;
      _expiryFailed = false;
    });
    if (fresh) {
      // Say that the badge came from the cache, and how old it is.
      //
      // Without this the cache is a silence amplifier, and it hid a real
      // investigation: a source whose lookup had once returned unknown served
      // that answer from cache on every subsequent visit *without calling the
      // provider*, so the source's own "here is why it was unknown" logging
      // never ran either. An exported log then showed a stubbornly unknown
      // badge and — correctly, but uselessly — nothing at all about it.
      // Non-null by `canServeCachedExpiry`, which returns false for a null
      // entry — the analyzer just can't see through the call.
      final served = entry!;
      final ageMinutes = DateTime.now().difference(served.fetchedAt).inMinutes;
      // The hint rides along only on `unknown`, the one kind where the reader
      // wants a different answer and the cache is what is standing in the way.
      // On a dated or unlimited entry it is pure noise on a line that repeats
      // per card per visit.
      final hint = served.expiry.kind == SubscriptionExpiryKind.unknown
          ? ' (save the source to force a re-check)'
          : '';
      DiagnosticsLog.instance.add(
        'library',
        'expiry from cache source=${config.label} '
            'kind=${served.expiry.kind.name} ageMin=$ageMinutes$hint',
      );
      return;
    }
    try {
      final value = await _expiryCache.refresh(config, force: force);
      if (!current()) return;
      setState(() {
        _expiry = value;
        _expiryLoading = false;
      });
    } catch (_) {
      if (!current()) return;
      setState(() {
        // A failed revalidation keeps the value already on screen rather than
        // replacing a good answer with an error.
        _expiryFailed = entry == null;
        _expiryLoading = false;
      });
    }
  }

  @override
  void didUpdateWidget(covariant _SourceCard old) {
    super.didUpdateWidget(old);
    if (old.config.fields.toString() != widget.config.fields.toString() ||
        old.config.settings.toString() != widget.config.settings.toString() ||
        old.config.kind != widget.config.kind) {
      // `force`: this only fires when the user actually changed the source, and
      // that is the moment they expect the badge to re-check. It is also the
      // only control the UI offers for doing so — the cache is otherwise
      // authoritative until it ages out, and an edit that leaves the
      // credentials alone (a label, a catch-up override) keeps the same
      // fingerprint, so without this a cached answer could not be dislodged at
      // all. Save the source to retry a lookup that came back unknown.
      _fetchExpiry(force: true);
    }
  }

  @override
  void dispose() {
    _menuHistory?.remove();
    _menuNode.dispose();
    super.dispose();
  }

  void _menuOpened() {
    final entry = LocalHistoryEntry(
      onRemove: () {
        _menuHistory = null;
        _menuController.close();
      },
    );
    _menuHistory = entry;
    ModalRoute.of(context)?.addLocalHistoryEntry(entry);
  }

  void _menuClosed() {
    final entry = _menuHistory;
    _menuHistory = null;
    entry?.remove();
  }

  // The menu is skip-traversal, so vertical movement finds adjacent row cards.
  List<FocusNode?> get _chain => [widget.focusNode, _menuNode];

  Object? _handleDirectional(DirectionalFocusIntent intent) {
    final focused = FocusManager.instance.primaryFocus;
    final chain = _chain;
    final idx = chain.indexOf(focused);
    switch (intent.direction) {
      case TraversalDirection.right:
        if (idx >= 0 && idx < chain.length - 1) {
          chain[idx + 1]?.requestFocus();
        }
        // On the last button there is nothing further right — consume.
        return null;
      case TraversalDirection.left:
        if (idx > 0) {
          chain[idx - 1]?.requestFocus();
        } else {
          // On the card (or unknown): leave the row leftwards.
          focused?.focusInDirection(intent.direction);
        }
        return null;
      case TraversalDirection.up:
      case TraversalDirection.down:
        focused?.focusInDirection(intent.direction);
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
          onInvoke: _handleDirectional,
        ),
      },
      child: FocusableCard(
        autofocus: widget.autofocus,
        focusNode: widget.focusNode,
        onTap: widget.onActivate,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.panelHi,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  _kindIcon(widget.config.kind),
                  color: widget.active ? AppColors.accent : AppColors.textLo,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            widget.config.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        if (widget.active) ...[
                          const SizedBox(width: 8),
                          const _ActivePill(),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    _ExpiryBadge(
                      loading: _expiryLoading,
                      failed: _expiryFailed,
                      expiry: _expiry,
                    ),
                    if (sourceCredentialsMissing(widget.config)) ...[
                      const SizedBox(height: 6),
                      const _NeedsAttentionBadge(),
                    ],
                  ],
                ),
              ),
              MenuAnchor(
                controller: _menuController,
                childFocusNode: _menuNode,
                onOpen: _menuOpened,
                onClose: _menuClosed,
                menuChildren: [
                  MenuItemButton(
                    autofocus: true,
                    onPressed: widget.onSettings,
                    child: Text(tr('Settings')),
                  ),
                  MenuItemButton(
                    onPressed: widget.onEdit,
                    child: Text(tr('Edit')),
                  ),
                  if (widget.canMoveUp)
                    MenuItemButton(
                      onPressed: widget.onMoveUp,
                      child: Text(tr('Move up')),
                    ),
                  if (widget.canMoveDown)
                    MenuItemButton(
                      onPressed: widget.onMoveDown,
                      child: Text(tr('Move down')),
                    ),
                  MenuItemButton(
                    onPressed: widget.onDelete,
                    child: Text(tr('Delete')),
                  ),
                ],
                builder: (context, controller, child) => IconButton(
                  focusNode: _menuNode,
                  tooltip: tr('Source options'),
                  icon: const Icon(Icons.more_vert, color: AppColors.textLo),
                  onPressed: () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExpiryBadge extends StatelessWidget {
  final bool loading;
  final bool failed;
  final SubscriptionExpiry expiry;
  const _ExpiryBadge({
    required this.loading,
    required this.failed,
    required this.expiry,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Container(
        height: 16,
        width: 90,
        decoration: BoxDecoration(
          color: AppColors.line.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(4),
        ),
      );
    }
    if (failed) {
      return _chip(
        Icons.error_outline,
        tr('Expiry unavailable'),
        AppColors.textLo,
      );
    }
    if (expiry.isUnlimited) {
      return _chip(
        Icons.all_inclusive_rounded,
        tr('Unlimited'),
        AppColors.textLo,
      );
    }
    final e = expiry.date;
    if (e == null) {
      return _chip(Icons.help_outline, tr('Expiry unknown'), AppColors.textLo);
    }
    final expired = e.isBefore(DateTime.now());
    final label =
        '${expired ? tr('Expired') : tr('Expires')} ${e.year}-${e.month.toString().padLeft(2, '0')}-${e.day.toString().padLeft(2, '0')}';
    return _chip(
      expired ? Icons.warning_amber_rounded : Icons.event_available,
      label,
      expired ? AppColors.danger : AppColors.textLo,
    );
  }

  Widget _chip(IconData icon, String label, Color color) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 13, color: color),
      const SizedBox(width: 4),
      Flexible(
        child: Text(
          label,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: color, fontSize: 12),
        ),
      ),
    ],
  );
}

/// A small chip flagging a source whose credentials are missing/locked (e.g. a
/// cloud pull left it locked on an E2EE-locked device). Explains that the source
/// can't be activated until it's unlocked in the panel or edited locally.
class _NeedsAttentionBadge extends StatelessWidget {
  const _NeedsAttentionBadge();

  @override
  Widget build(BuildContext context) {
    const color = AppColors.warning;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.lock_outline, size: 13, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            tr('Needs attention — credentials locked. Unlock in the panel.'),
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: color, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _ActivePill extends StatelessWidget {
  const _ActivePill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        tr('ACTIVE'),
        style: TextStyle(
          color: AppColors.accent,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _FieldSpec {
  final String key;
  final String label;
  final String? hint;
  final bool required;
  final bool obscure;
  const _FieldSpec(
    this.key,
    this.label, {
    this.hint,
    this.required = true,
    this.obscure = false,
  });
}

/// Field keys that carry a URL and get a light format check (parseable +
/// http/https scheme + non-empty host) on top of the plain presence check —
/// so a malformed portal/host/playlist URL is caught here rather than at
/// playback time.
const _urlFieldKeys = {'portal', 'host', 'playlistUrl'};

/// Same visual chrome as `channel_list_chrome.dart`'s `_DropdownFrame`
/// (accent-ring-on-focus, `KeyRepeatEvent` swallowed so D-pad auto-repeat
/// can't misbehave against the popup menu) reimplemented here rather than
/// imported, since `channel_list_chrome.dart` is owned by a concurrent
/// change. A future refactor should extract one shared widget.
class _SourceKindFieldFrame extends StatefulWidget {
  final Widget Function(FocusNode focusNode) builder;

  const _SourceKindFieldFrame({required this.builder});

  @override
  State<_SourceKindFieldFrame> createState() => _SourceKindFieldFrameState();
}

class _SourceKindFieldFrameState extends State<_SourceKindFieldFrame> {
  final FocusNode _node = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(_sync);
  }

  void _sync() {
    if (mounted && _focused != _node.hasFocus) {
      setState(() => _focused = _node.hasFocus);
    }
  }

  @override
  void dispose() {
    _node.removeListener(_sync);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: _focused ? AppColors.panelHi : AppColors.panel,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(
          color: _focused ? AppColors.accent : AppColors.line,
          width: _focused ? 2 : 1,
        ),
      ),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, event) => event is KeyRepeatEvent
            ? KeyEventResult.handled
            : KeyEventResult.ignored,
        child: DropdownButtonHideUnderline(child: widget.builder(_node)),
      ),
    );
  }
}

/// Add or edit a single source.
class EditSourceScreen extends StatefulWidget {
  final SourceStore store;
  final SourceConfig? existing;
  const EditSourceScreen({super.key, required this.store, this.existing});

  @override
  State<EditSourceScreen> createState() => _EditSourceScreenState();
}

class _EditSourceScreenState extends State<EditSourceScreen> {
  late SourceKind _kind;
  late final TextEditingController _label;
  final Map<String, TextEditingController> _fields = {};

  /// Field key → inline error message, cleared as soon as the user edits that
  /// field again. Rendered directly under the offending [TvTextField] rather
  /// than in a bottom SnackBar, so the problem is visible next to the field.
  Map<String, String> _fieldErrors = const {};

  /// Prevent duplicate writes while the source is being saved.
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _kind = widget.existing?.kind ?? SourceKind.stalker;
    _label = TextEditingController(text: widget.existing?.label ?? '');
  }

  @override
  void dispose() {
    _label.dispose();
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _controller(String key) => _fields.putIfAbsent(
    key,
    () => TextEditingController(text: widget.existing?.fields[key] ?? ''),
  );

  List<_FieldSpec> _specs(SourceKind kind) {
    switch (kind) {
      case SourceKind.stalker:
        return [
          _FieldSpec('portal', tr('Portal URL'), hint: 'http://host:port/c/'),
          _FieldSpec(
            'mac',
            tr('MAC address'),
            hint: '00:1A:79:..:..:..',
            obscure: true,
          ),
        ];
      case SourceKind.xtream:
        return [
          _FieldSpec('host', tr('Host'), hint: 'http://host:port'),
          // Username isn't shoulder-surfing-sensitive the way a password is,
          // and masking it makes a typo impossible to spot without a physical
          // keyboard — the exact problem TvTextField's show/hide toggle exists
          // to solve for fields that must stay masked. Leave it visible.
          _FieldSpec('username', tr('Username')),
          _FieldSpec('password', tr('Password'), obscure: true),
        ];
      case SourceKind.m3u:
        return [
          _FieldSpec(
            'playlistUrl',
            tr('Playlist URL'),
            hint: 'http://.../list.m3u',
          ),
          _FieldSpec(
            'epgUrl',
            tr('EPG / XMLTV URL (optional)'),
            required: false,
          ),
          _FieldSpec('userAgent', tr('User-Agent (optional)'), required: false),
        ];
      case SourceKind.demo:
        return const [];
    }
  }

  /// Presence + light URL-format validation, reported per-field (see
  /// [_fieldErrors]) rather than as a single bottom SnackBar for the first
  /// failure. Returns the errors found; empty means the form is valid.
  Map<String, String> _validate(List<_FieldSpec> specs) {
    final errors = <String, String>{};
    for (final s in specs) {
      final value = _controller(s.key).text.trim();
      if (s.required && value.isEmpty) {
        errors[s.key] = tr('{field} is required', {'field': s.label});
        continue;
      }
      if (value.isNotEmpty &&
          _urlFieldKeys.contains(s.key) &&
          !looksLikeValidUrl(value)) {
        errors[s.key] = tr(
          'Enter a valid URL starting with http:// or https://',
        );
      }
    }
    return errors;
  }

  Future<void> _save() async {
    if (_saving) return;
    final specs = _specs(_kind);
    final errors = _validate(specs);
    if (errors.isNotEmpty) {
      setState(() => _fieldErrors = errors);
      return;
    }
    setState(() {
      _fieldErrors = const {};
      _saving = true;
    });
    try {
      // Carry forward any stored field this form does not render, then let
      // the rendered ones win.
      //
      // The form rebuilds `fields` from its own controllers, so a key with no
      // `_FieldSpec` is destroyed by an unrelated edit — change the label,
      // press Save, and it is gone. That is the same bug the `settings`
      // comment below records, arriving through the other map: `epgUrls` (the
      // extra EPG guides, edited in `SourceSettingsScreen`) lives in `fields`
      // rather than `settings` because it is credential-bearing and has to
      // travel as a *secret* to the cloud. Written generally so the next such
      // key is safe by default rather than by remembering this.
      //
      // Kind-guarded for the same reason the settings carry-over is: field
      // keys are provider specific, so carrying them onto a different provider
      // would leave stale locators behind.
      final specKeys = {for (final s in specs) s.key};
      final fields = <String, String>{
        if (widget.existing?.kind == _kind)
          for (final entry in widget.existing!.fields.entries)
            if (!specKeys.contains(entry.key)) entry.key: entry.value,
        for (final s in specs) s.key: _controller(s.key).text.trim(),
      };
      final label = _label.text.trim().isEmpty
          ? _kind.name
          : _label.text.trim();
      final config = SourceConfig(
        id: widget.existing?.id ?? newSourceId(),
        kind: _kind,
        label: label,
        fields: fields,
        // Per-source preferences live on the same config but are managed by
        // `SourceSettingsScreen`, and this form rebuilds the config from its
        // own controllers — so without carrying them, editing a source (even
        // just to fix a typo in its label) silently wiped every hidden
        // category and catch-up override it had.
        //
        // Only when the kind is unchanged: hidden-category ids are provider
        // specific, so carrying them onto a different provider would hide
        // arbitrary categories rather than the ones the user picked.
        settings: widget.existing?.kind == _kind
            ? (widget.existing?.settings ?? const {})
            : const {},
      );
      await widget.store.save(config);
      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // New source: the Type selector picks the field set below it, so it
    // should be the first stop — otherwise a TV user has to go Up from Label,
    // cycle Type, then come back down past Label again. Editing an existing
    // source keeps no autofocus, matching the previous behaviour.
    final isNew = widget.existing == null;
    return Scaffold(
      appBar: AppBar(title: Text(isNew ? tr('Add source') : tr('Edit source'))),
      // Edge-to-edge (targetSdk 35+): keep the form — and especially the Save
      // button at its end — clear of the system bar.
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: kSettingsMaxContentWidth,
            ),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Label above the field, exactly like every `TvTextField`
                // below it. It used to be an `InputDecoration.labelText`, but
                // that decoration is also `isCollapsed`, which removes the
                // vertical space a floating label needs — so "Type" was drawn
                // *on top of* the kind icon and its value. Matching the
                // surrounding fields fixes the overlap and the inconsistency in
                // one move: this was the only field in the form with a floating
                // label at all.
                Padding(
                  padding: EdgeInsets.only(left: 4, bottom: 6),
                  child: Text(
                    tr('Type'),
                    style: TextStyle(
                      color: AppColors.textLo,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _SourceKindFieldFrame(
                  builder: (focusNode) => DropdownButtonFormField<SourceKind>(
                    focusNode: focusNode,
                    autofocus: isNew,
                    initialValue: _kind,
                    isDense: true,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      // No `labelText`: see the Text above.
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      isCollapsed: true,
                    ),
                    dropdownColor: AppColors.panelHi,
                    borderRadius: BorderRadius.circular(AppRadius.control),
                    items: SourceKind.values
                        .map(
                          (k) => DropdownMenuItem(
                            value: k,
                            child: Row(
                              children: [
                                Icon(
                                  _kindIcon(k),
                                  size: 18,
                                  color: AppColors.textLo,
                                ),
                                const SizedBox(width: 10),
                                Text(k.name.toUpperCase()),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (k) => setState(() => _kind = k ?? _kind),
                  ),
                ),
                const SizedBox(height: 16),
                TvTextField(
                  controller: _label,
                  label: tr('Label (optional)'),
                  hintText: tr('e.g. Living room IPTV'),
                  textInputAction: TextInputAction.next,
                ),
                for (final s in _specs(_kind)) ...[
                  const SizedBox(height: 16),
                  TvTextField(
                    controller: _controller(s.key),
                    label: s.label,
                    hintText: s.hint ?? '',
                    obscureText: s.obscure,
                    textInputAction: TextInputAction.next,
                    errorText: _fieldErrors[s.key],
                    onChanged: _fieldErrors.containsKey(s.key)
                        ? (_) => setState(
                            () =>
                                _fieldErrors = {..._fieldErrors}..remove(s.key),
                          )
                        : null,
                  ),
                ],
                const SizedBox(height: 28),
                SizedBox(
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(_saving ? tr('Saving') : tr('Save source')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MetadataSettingsScreen extends StatefulWidget {
  final SourceStore store;
  final AppDatabase db;

  const MetadataSettingsScreen({
    super.key,
    required this.store,
    required this.db,
  });

  @override
  State<MetadataSettingsScreen> createState() => _MetadataSettingsScreenState();
}

class _MetadataSettingsScreenState extends State<MetadataSettingsScreen> {
  final _tmdb = TextEditingController();
  final _tvdb = TextEditingController();
  final _tvdbPin = TextEditingController();
  final _mdblist = TextEditingController();
  String _provider = 'tmdb';
  bool _autoEnrich = true;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tmdb.dispose();
    _tvdb.dispose();
    _tvdbPin.dispose();
    _mdblist.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final config = await widget.store.metadataConfig();
    if (!mounted) return;
    setState(() {
      _provider = config.preferredVisualProvider;
      _tmdb.text = config.tmdbApiKey;
      _tvdb.text = config.tvdbApiKey;
      _tvdbPin.text = config.tvdbPin;
      _mdblist.text = config.mdblistApiKey;
      _autoEnrich = config.autoEnrich;
      _loading = false;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await widget.store.saveMetadataConfig(
      MetadataConfig(
        provider: _provider,
        tmdbApiKey: MetadataConfig.normalizeTmdbCredential(_tmdb.text),
        tvdbApiKey: _tvdb.text.trim(),
        tvdbPin: _tvdbPin.text.trim(),
        mdblistApiKey: _mdblist.text.trim(),
        autoEnrich: _autoEnrich,
      ),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr('Metadata settings saved'))));
  }

  Future<void> _clearMetadataCache() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.panelHi,
        title: Text(tr('Clear metadata cache?')),
        content: Text(
          tr(
            'This removes cached external metadata. Refresh the source afterward if you want provider titles/posters restored before re-enrichment.',
          ),
        ),
        actions: [
          TextButton(
            // Autofocus the *non*-destructive action: on a D-pad an
            // unfocused dialog swallows the first OK press entirely, so the
            // user has to blind-hunt with arrows before anything responds.
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Clear')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.db.clearExternalMetadata();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr('Metadata cache cleared'))));
  }

  Future<void> _resetMetadataAndDisplay() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.panelHi,
        title: Text(tr('Reset enriched display?')),
        content: Text(
          tr(
            'This clears external metadata and restores cached movie/series display fields from source-provided data where possible.',
          ),
        ),
        actions: [
          TextButton(
            // Autofocus the *non*-destructive action: on a D-pad an
            // unfocused dialog swallows the first OK press entirely, so the
            // user has to blind-hunt with arrows before anything responds.
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Reset')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.db.clearExternalMetadata();
    await widget.db.resetEnrichedMediaDisplayFields();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr('Metadata display reset'))));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Metadata'))),
      // Edge-to-edge (targetSdk 35+): keep the form clear of the system bar.
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: kSettingsMaxContentWidth,
                  ),
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text(
                        tr(
                          'TVmaze supplies series descriptions for everyone, free and without an API key. TMDB and TheTVDB are optional; TheTVDB also supports movies and requires a project API key.',
                        ),
                        style: TextStyle(color: AppColors.textLo),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        tr('Metadata provider'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        tr(
                          'Pick the preferred poster/details provider. The other configured visual provider is used as fallback; MDBList adds ratings when possible.',
                        ),
                        style: TextStyle(color: AppColors.textLo),
                      ),
                      const SizedBox(height: 16),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'tmdb', label: Text('TMDB')),
                          ButtonSegment(value: 'tvdb', label: Text('TVDB')),
                        ],
                        selected: {_provider},
                        onSelectionChanged: (value) =>
                            setState(() => _provider = value.first),
                      ),
                      const SizedBox(height: 16),
                      TvTextField(
                        controller: _tmdb,
                        label: tr('TMDB API credential'),
                        hintText: tr(
                          'Paste a v3 API key or v4 Read Access Token',
                        ),
                        obscureText: true,
                        autofocus: true,
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 12),
                      TvTextField(
                        controller: _tvdb,
                        label: tr('TVDB API key'),
                        hintText: tr(
                          'Used as preferred or fallback visual provider',
                        ),
                        obscureText: true,
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 12),
                      TvTextField(
                        controller: _tvdbPin,
                        label: tr('TVDB PIN'),
                        hintText: tr('Optional user-supported key PIN'),
                        obscureText: true,
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 12),
                      TvTextField(
                        controller: _mdblist,
                        label: tr('MDBList API key'),
                        hintText: tr('Optional ratings enrichment'),
                        obscureText: true,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _save(),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        tr('Changes apply after returning to the library.'),
                        style: TextStyle(color: AppColors.textLo, fontSize: 12),
                      ),
                      const SizedBox(height: 16),
                      SwitchListTile(
                        value: _autoEnrich,
                        contentPadding: EdgeInsets.zero,
                        title: Text(tr('Auto-enrich loaded lists')),
                        subtitle: Text(
                          tr(
                            'Fetch metadata in the background after movies or series load.',
                          ),
                          style: TextStyle(color: AppColors.textLo),
                        ),
                        onChanged: (value) =>
                            setState(() => _autoEnrich = value),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _clearMetadataCache,
                        icon: const Icon(Icons.delete_sweep_outlined),
                        label: Text(tr('Clear metadata cache')),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _resetMetadataAndDisplay,
                        icon: const Icon(Icons.restore_outlined),
                        label: Text(tr('Reset enriched display')),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 48,
                        child: FilledButton.icon(
                          onPressed: _saving ? null : _save,
                          icon: _saving
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.save_outlined),
                          label: Text(_saving ? tr('Saving') : tr('Save')),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

/// "OK to cycle" tri-state row for when the boot-time profile picker appears
/// (see [ProfilePickerStartup]). A single focus stop, so the D-pad passes over
/// it like any list row; OK/tap cycles Auto → Always → Never.
class _PickerStartupCard extends StatefulWidget {
  const _PickerStartupCard();

  @override
  State<_PickerStartupCard> createState() => _PickerStartupCardState();
}

class _PickerStartupCardState extends State<_PickerStartupCard> {
  static const _store = LocalProfileStore();
  ProfilePickerStartup? _mode; // null while loading

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final mode = await _store.pickerStartup();
    if (mounted) setState(() => _mode = mode);
  }

  Future<void> _cycle() async {
    final current = _mode ?? ProfilePickerStartup.auto;
    final next = ProfilePickerStartup
        .values[(current.index + 1) % ProfilePickerStartup.values.length];
    setState(() => _mode = next);
    await _store.setPickerStartup(next);
  }

  String get _valueLabel => switch (_mode) {
    ProfilePickerStartup.always => tr('Always'),
    ProfilePickerStartup.off => tr('Never'),
    _ => tr('Auto'),
  };

  String get _hint => switch (_mode) {
    ProfilePickerStartup.always => tr('Shown on every launch'),
    ProfilePickerStartup.off => tr('Never shown at startup'),
    _ => tr('Shown when more than one profile exists'),
  };

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      onTap: _cycle,
      scrollOnFocus: false,
      debugLabel: 'sources.pickerStartup',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Icon(
              Icons.switch_account_outlined,
              size: 20,
              color: AppColors.textLo,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('Profile picker at startup')),
                  Text(
                    _hint,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textLo,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              _valueLabel,
              style: const TextStyle(
                color: AppColors.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UpdateTrackCard extends StatefulWidget {
  const _UpdateTrackCard();

  @override
  State<_UpdateTrackCard> createState() => _UpdateTrackCardState();
}

class _UpdateTrackCardState extends State<_UpdateTrackCard> {
  UpdateTrack _track = UpdateTrack.stable;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final track = await const UpdateStore().track();
    if (mounted) setState(() => _track = track);
  }

  Future<void> _choose() async {
    final selected = await showDialog<UpdateTrack>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.panelHi,
        title: Text(tr('GitHub update track')),
        content: Text(
          tr(
            'Stable receives normal releases. Beta also receives signed GitHub '
            'prereleases intended for testing. Switching back to Stable never '
            'downgrades the app; it waits for a newer stable release.',
          ),
        ),
        actions: [
          TextButton(
            autofocus: _track == UpdateTrack.stable,
            onPressed: () => Navigator.pop(context, UpdateTrack.stable),
            child: Text(tr('Stable')),
          ),
          FilledButton(
            autofocus: _track == UpdateTrack.beta,
            onPressed: () => Navigator.pop(context, UpdateTrack.beta),
            child: Text(tr('Beta')),
          ),
        ],
      ),
    );
    if (selected == null || selected == _track) return;
    await const UpdateStore().setTrack(selected);
    if (mounted) setState(() => _track = selected);
  }

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      onTap: _choose,
      scrollOnFocus: false,
      debugLabel: 'sources.updateTrack',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Icon(
              Icons.science_outlined,
              size: 20,
              color: AppColors.textLo,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('GitHub update track')),
                  Text(
                    tr(_track.displayName),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textLo,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 20, color: AppColors.textLo),
          ],
        ),
      ),
    );
  }
}

/// "Check for updates" row. A single focus stop (like [_PickerStartupCard]);
/// OK/tap runs a direct update check or opens the configured Store. The hint shows
/// the running version (see [appVersion]).
class _UpdateCard extends StatefulWidget {
  const _UpdateCard();

  @override
  State<_UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<_UpdateCard> {
  String? _version; // null while loading
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final version = await appVersion();
      if (mounted) setState(() => _version = version);
    } catch (_) {
      // Leave the generic label if the platform version is unavailable.
    }
  }

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      await runUpdateCheck(context, manual: true);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      onTap: _check,
      scrollOnFocus: false,
      debugLabel: 'sources.checkUpdate',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Icon(
              Icons.system_update_outlined,
              size: 20,
              color: AppColors.textLo,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('Check for updates')),
                  Text(
                    _version == null
                        ? tr('Current version')
                        : tr('Version {version}', {'version': _version!}),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textLo,
                    ),
                  ),
                ],
              ),
            ),
            if (_checking)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const Icon(
                Icons.chevron_right,
                size: 20,
                color: AppColors.textLo,
              ),
          ],
        ),
      ),
    );
  }
}
