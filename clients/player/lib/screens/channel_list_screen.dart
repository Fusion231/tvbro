import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show
        HardwareKeyboard,
        KeyDownEvent,
        KeyEvent,
        KeyUpEvent,
        LogicalKeyboardKey,
        SystemNavigator;
import 'package:media_kit/media_kit.dart';

import '../data/device_class.dart';
import '../data/diagnostics_log.dart';
import '../data/library_repository.dart';
import '../data/dvr_runtime.dart';
import '../data/epg_models.dart';
import '../data/channel_organization.dart';
import '../data/parental_controls.dart';
import '../data/source_store.dart';
import '../data/recently_watched_store.dart';
import '../data/supporter_access.dart';
import '../dvr/dvr_service.dart';
import '../sources/source.dart';
import '../sources/source_config.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/app_bar_action.dart';
import '../widgets/app_logo.dart';
import '../widgets/supporter_gate.dart';
import '../widgets/provider_stream_warning.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/routed_focus_node.dart';
import '../widgets/parental_gate.dart';
import '../widgets/media_loading_dialog.dart';
import '../player/ios_engine.dart';
import '../player/linux_native_session.dart';
import '../player/playback_backend.dart';
import '../player/aspect_mode.dart' show aspectModeIndexOf;
import '../player/buffer_preset.dart';
import '../player/channel_variants.dart';
import '../player/episode_navigation.dart';
import '../player/live_zap_controller.dart';
import '../player/zap_quick_list.dart';
import '../player/player_screen.dart';
import '../player/playback_error.dart';
import 'channel_list_chrome.dart';
import 'epg_grid_screen.dart';
import 'epg_mapping_screen.dart';
import 'favorites_controller.dart';
import 'favorites_order.dart';
import 'favorites_tab_view.dart';
import 'global_favorites_controller.dart';
import 'global_search_view.dart';
import 'legal_screen.dart';
import 'live_controller.dart';
import 'live_focus_coordinator.dart';
import 'live_preview_controller.dart';
import 'live_tab_view.dart';
import 'library_home_view.dart';
import 'recently_watched_view.dart';
import 'media_tab_controller.dart';
import 'media_tab_view.dart';
import 'profile_pick_screen.dart';
import 'sources_screen.dart';
import 'source_settings_screen.dart';
import 'recording_schedule_dialog.dart';

/// True only when the active local recording belongs to this exact provider
/// channel. Channel IDs are provider-scoped and can collide across sources.
bool recordingMatchesChannel(
  DvrRecording? recording, {
  required String sourceId,
  required String channelId,
}) =>
    recording?.status == DvrRecordingStatus.recording &&
    recording?.sourceId == sourceId &&
    recording?.channelId == channelId;

/// The ways [_ChannelListScreenState._openLivePlayer] can reconcile a running
/// live preview with a fullscreen open, decided purely from state so the
/// branching is unit-testable without a widget tree or a real platform.
/// Pinned by `test/fullscreen_handoff_test.dart`.
///
/// - [adoptNative]: Android's fullscreen Activity adopts the running shared
///   ExoPlayer engine (`SharedEngine`) — seamless, preview left playing.
/// - [adoptEmbedded]: the fullscreen [PlayerScreen] adopts the preview's
///   media_kit engine directly and keeps it playing through the handoff —
///   seamless on every non-Android platform, including Linux for **SDR streams
///   and all of X11** (the native mpv window buys nothing there). The one
///   exception is a **Wayland HDR** source (see [stopResolveFresh]).
/// - [stopResolveFresh]: a same-channel handoff where the fullscreen player is
///   about to run on a **different engine than the preview**, so there is
///   nothing to adopt. Two cases reach it:
///   * **Linux Wayland HDR** — the native mpv *process* takes over
///     (`linuxNativeLikely` is Wayland-gated and `streamLikelyHdr` is true),
///     the one case where the native window earns its cost (real HDR
///     passthrough). SDR/X11 stay [adoptEmbedded].
///   * **iOS AVPlayer** (`crossEngineFullscreen`) — the preview always runs on
///     embedded media_kit/libmpv, but an AVPlayer-routed channel goes
///     fullscreen on a presented `AVPlayerLayer` controller. AVPlayer cannot
///     adopt an mpv session.
///   Either way the preview must be *stopped* outright — pausing it would
///   leave its provider connection open (a single-connection portal then sees
///   two), and the preview's already-resolved stream carries a spent
///   single-use Stalker `play_token` — so the channel is re-resolved fresh too.
/// - [pausePreview]: a same-channel handoff that isn't adopted and doesn't
///   need [stopResolveFresh]'s connection teardown (chiefly Android falling
///   back to its embedded media_kit preview) — paused and resumed on return.
/// - [stopPreview]: a different-channel preview (last-channel zap,
///   EPG-grid play) — stopped outright so it neither doubles audio nor a
///   provider connection; not restarted on return.
/// - [none]: no preview is running that needs reconciling.
enum FullscreenHandoff {
  adoptNative,
  adoptEmbedded,
  stopResolveFresh,
  pausePreview,
  stopPreview,
  none,
}

/// Pure decision function behind [FullscreenHandoff] — see there for what
/// each outcome means and why. [linuxNativeLikely] is the Wayland-gated
/// native-worth-using predicate ([LinuxNativeSession.nativeLikelyAvailable];
/// already false off Linux and on X11). [streamLikelyHdr] is true when the
/// preview is rendering a PQ/HLG/Dolby-Vision source — the only case where the
/// native mpv window earns its non-seamless fresh-resolve cost. Together they
/// select [FullscreenHandoff.stopResolveFresh] *only* for Wayland+HDR; every
/// other Linux same-channel handoff (SDR, or X11) stays the seamless
/// [FullscreenHandoff.adoptEmbedded]. (A source that starts SDR then turns out
/// HDR still escalates later, inside `PlayerScreen._maybeEscalateLinuxNative`.)
///
/// [crossEngineFullscreen] is the iOS analogue of that pair, collapsed into one
/// flag because the caller already knows the answer with no probe: the preview
/// runs on embedded media_kit/libmpv, and `selectIosEngine` says this channel
/// goes fullscreen on **AVPlayer**. AVPlayer cannot adopt an mpv session, and a
/// merely *paused* media_kit engine still holds its provider connection —
/// provider accounts are single-connection, so two live engines break playback.
/// Hence the same stop-and-re-resolve treatment Wayland HDR gets. Defaults
/// false, so every non-iOS caller and every existing case is unaffected.
FullscreenHandoff decideFullscreenHandoff({
  required bool reusePreview,
  required bool sameChannelPreview,
  required bool previewHasStream,
  required bool isAndroid,
  required bool nativePreviewActive,
  required bool linuxNativeLikely,
  required bool previewPlaying,
  bool streamLikelyHdr = false,
  bool crossEngineFullscreen = false,
}) {
  final adoptPreview = reusePreview && sameChannelPreview && previewHasStream;
  if (adoptPreview && isAndroid && nativePreviewActive) {
    return FullscreenHandoff.adoptNative;
  }
  if (adoptPreview &&
      !isAndroid &&
      (crossEngineFullscreen || (linuxNativeLikely && streamLikelyHdr))) {
    return FullscreenHandoff.stopResolveFresh;
  }
  if (adoptPreview && !isAndroid) {
    return FullscreenHandoff.adoptEmbedded;
  }
  if (!previewPlaying) return FullscreenHandoff.none;
  if (sameChannelPreview) return FullscreenHandoff.pausePreview;
  return FullscreenHandoff.stopPreview;
}

/// What an OK/click on a channel row does on a wide (split-pane) layout, given
/// the preview's state for that same channel. Pure so the branching is
/// unit-testable; pinned by `test/fullscreen_handoff_test.dart`.
///
/// The [awaitPreviewThenOpen] rung is the one that used to be missing, and it
/// is the whole point of this function. A second OK landing while the preview's
/// own `create_link` was still in flight fell through to "start a preview" and
/// **restarted the channel**: a new resolve superseding the in-flight one (both
/// burning single-use Stalker `play_token`s) and, on Android,
/// `SharedEngine.openPreview` → `ExoPlayerEngine.load()` on the running engine —
/// a visible stream reload, after which the user still had to press OK a third
/// time to actually go fullscreen. It is an Android-TV-shaped bug: there the
/// preview is deliberate (OK starts it, see `_deliberatePreview`) and a remote
/// invites a second press while a slow portal resolves, whereas a phone bypasses
/// the preview entirely on its narrow layout and a desktop preview auto-starts
/// on hover well before the click.
enum ChannelPlayAction {
  /// This channel is previewing and resolved — go fullscreen, adopting it.
  openFullscreen,

  /// This channel's preview is still resolving. Wait for *that* resolve and
  /// then go fullscreen; never start a second one.
  awaitPreviewThenOpen,

  /// Nothing is previewing this channel (or its preview failed) — start one.
  startPreview,
}

/// Whether the live list draws EPG lines inside its rows.
///
/// **The one input the row extent and the row contents must agree on.** The
/// extent drives the selection model's `index * extent` scroll maths and is
/// handed to `LiveTabView` as its `itemExtent`, while `LiveTabView` re-derives
/// the row layout from the same metrics — so a view that answers this
/// differently on the two sides scrolls by a height its rows aren't drawn at.
///
/// The two views are asked **different questions**, which is the whole point of
/// this being one function rather than a bare `hasEpg` read. [hasEpg] is
/// whether the *active* source has a guide; [hasCrossSourceEpg] is whether the
/// cross-source Favorites view has one of its own. Reading `hasEpg` in the
/// cross-source view laid its rows out at 68.1 px inside an itemExtent of
/// 105.9 — the active source having a guide says nothing about whether a
/// foreign row will draw one.
///
/// The cross-source view's guide is keyed by `(sourceId, channelId)` and
/// reaches the rows through `LiveTabView.epgFor`; it is deliberately *not* the
/// active source's maps, which are keyed by channel id alone and would print
/// another provider's programme against a foreign row.
///
/// Pure and top-level for the same reason as
/// [shouldLeaveCrossSourceFavoritesView]: the screen that uses it can only be
/// widget-tested with libmpv present, which no Windows dev box has.
/// [expectsEpg] is the active source saying a guide is on its way before one
/// has arrived — see `LiveController.expectsEpg`. It applies only to the
/// ordinary views: the cross-source Favorites view is fed by a different
/// controller with its own guide, and the active source's expectations say
/// nothing about whether a *foreign* row will draw one.
bool liveRowsShowEpg({
  required String? categoryId,
  required bool hasEpg,
  required bool hasCrossSourceEpg,
  required bool expectsEpg,
}) => categoryId == kAllSourcesFavoritesCategoryId
    ? hasCrossSourceEpg
    : hasEpg || expectsEpg;

/// Whether the live tab must fall back to "All" because the cross-source
/// Favorites view is selected but no longer offered.
///
/// Its category entry only appears while a favorite exists in a source other
/// than the active one, so unfavoriting the last foreign favorite — or
/// switching to a source where every remaining favorite is local — removes the
/// entry from the pane while the selection still points at it, leaving an empty
/// list selected on a category the user can neither see nor move off. The
/// per-source Favorites view has always had this fallback; this is the same
/// rule for the cross-source one.
bool shouldLeaveCrossSourceFavoritesView({
  required String? categoryId,
  required bool hasForeignFavorites,
}) => categoryId == kAllSourcesFavoritesCategoryId && !hasForeignFavorites;

ChannelPlayAction decideChannelPlayAction({
  required bool sameChannelPreview,
  required bool previewHasStream,
  required bool previewLoading,
}) {
  if (!sameChannelPreview) return ChannelPlayAction.startPreview;
  if (previewHasStream) return ChannelPlayAction.openFullscreen;
  if (previewLoading) return ChannelPlayAction.awaitPreviewThenOpen;
  // Same channel, not loading, no stream: the preview errored out. Retrying it
  // is the useful answer, and it's what a first OK would have done.
  return ChannelPlayAction.startPreview;
}

/// Native Linux discovery may spawn/version-check an external mpv process on
/// its first call. Pay that cost only when its result can change the handoff:
/// a same-channel HDR preview that would otherwise be adopted embedded.
/// Non-preview opens and SDR previews go straight through; if an initially SDR
/// stream later reports HDR, [PlayerScreen] still performs its one-shot
/// embedded-to-native escalation.
bool shouldProbeLinuxNativeForHandoff({
  required bool isLinux,
  required bool reusePreview,
  required bool sameChannelPreview,
  required bool previewHasStream,
  required bool streamLikelyHdr,
}) =>
    isLinux &&
    reusePreview &&
    sameChannelPreview &&
    previewHasStream &&
    streamLikelyHdr;

/// Every downstream boolean [_ChannelListScreenState._openLivePlayer] needs
/// from a [FullscreenHandoff], derived here instead of re-tested against the
/// raw inputs at the call site — a duplicate formula there previously could
/// (and once did) desync from the actual decision when preview state changed
/// across an `await`. Pinned by `test/fullscreen_handoff_test.dart`.
extension FullscreenHandoffDerived on FullscreenHandoff {
  /// The fullscreen player adopts a still-running preview engine — Android's
  /// shared native engine or the embedded media_kit one — and the preview
  /// keeps playing straight through the handoff.
  bool get seamless =>
      this == FullscreenHandoff.adoptNative ||
      this == FullscreenHandoff.adoptEmbedded;

  /// [PlayerScreen] should adopt the preview's embedded media_kit
  /// [Player]/`VideoController` directly. Never true on Android — that's
  /// [adoptsNativePreview] instead.
  bool get adoptsEmbeddedPreview => this == FullscreenHandoff.adoptEmbedded;

  /// Android's fullscreen Activity should adopt the running shared native
  /// preview engine.
  bool get adoptsNativePreview => this == FullscreenHandoff.adoptNative;

  /// Linux native mpv is about to take over: the preview must be stopped and
  /// the channel re-resolved fresh (a spent play_token) rather than adopted.
  bool get stopsAndResolvesFresh => this == FullscreenHandoff.stopResolveFresh;

  /// A same-channel, non-adopted handoff: pause the preview and resume it on
  /// return.
  bool get pausesPreview => this == FullscreenHandoff.pausePreview;

  /// A different-channel preview: stop it outright, not restarted on return.
  bool get stopsPreview => this == FullscreenHandoff.stopPreview;
}

/// What [_ChannelListScreenState._openLivePlayer] does with the live preview
/// once the fullscreen route has popped.
enum PreviewReturnAction {
  /// The player hot-swapped this player's video output onto the Windows native
  /// HDR surface, which has just been torn down — the engine can't be reused
  /// for the preview's texture.
  discardPlayer,

  /// Stop it outright and drop the selection.
  stop,

  /// Restart the *same* channel (the cross-engine stop-and-resolve-fresh case,
  /// where the preview was only stopped to free the connection).
  restartSameChannel,

  /// Resume an adopted engine that never stopped, restoring its mute.
  resumeAdopted,

  /// Resume a same-channel preview that was merely paused.
  resumePaused,

  /// The session zapped away from the launch channel: stop the preview (which
  /// is either the launch channel or an adopted engine in an unknown state)
  /// and start it fresh on the channel the session **ended** on.
  restartOnEndedChannel,

  /// Nothing to reconcile.
  none,
}

/// Pure counterpart of the return leg's branch chain, so the one rule that is
/// easy to get wrong can be pinned without a libmpv engine
/// (`test/fullscreen_handoff_test.dart`).
///
/// That rule is [zapped]: once an in-player zap has moved the session off the
/// launch channel, **no** resume is correct. Resuming would put the channel
/// the user navigated away from back in the panel — captioned as if it were
/// the one they were just watching — and on an adopted engine it is also the
/// thing still holding a single-connection account's only slot. Wherever the
/// un-zapped session would have brought a preview back, a zapped one
/// **restarts it on the ended channel** instead (stop first, then resolve, for
/// the single-connection reason), so backing out looks the same whether or not
/// the user zapped. It is checked after only the two cases that describe a
/// player which can no longer be used at all.
PreviewReturnAction decidePreviewReturn({
  required bool hotSwapped,
  required bool resumePreviewOnReturn,
  required bool zapped,
  required FullscreenHandoff decision,
  required bool previewHasStream,
}) {
  if (hotSwapped) return PreviewReturnAction.discardPlayer;
  // Phone sheet handoff: nothing shows the preview after fullscreen.
  if (!resumePreviewOnReturn) return PreviewReturnAction.stop;
  final PreviewReturnAction resume;
  if (decision.stopsAndResolvesFresh) {
    resume = PreviewReturnAction.restartSameChannel;
  } else if (decision.seamless && previewHasStream) {
    resume = PreviewReturnAction.resumeAdopted;
  } else if (decision.pausesPreview && previewHasStream) {
    resume = PreviewReturnAction.resumePaused;
  } else {
    resume = PreviewReturnAction.none;
  }
  if (!zapped) return resume;
  // An adopted engine is restarted on the ended channel whether or not the
  // preview still reports a stream. A zap that changed something baked into
  // the engine (a cross-source zap's headers, another source's buffer preset)
  // rebuilds it, and on Android that un-adopts through `previewEvent: lost`,
  // which clears the preview's stream behind the session's back — reading
  // that as "nothing to bring back" left the panel empty after exactly the
  // sessions that zapped furthest.
  if (decision.seamless) return PreviewReturnAction.restartOnEndedChannel;
  return resume == PreviewReturnAction.none
      ? PreviewReturnAction.stop
      : PreviewReturnAction.restartOnEndedChannel;
}

/// Lists a source's channels with in-memory search + category filtering, plus
/// now/next EPG (when the source provides it).
class ChannelListScreen extends StatefulWidget {
  final LibraryRepository repo;

  /// The active source's config, carrying per-source preferences (e.g. hidden
  /// categories). Read for presentation only — browsing filters key off it.
  final SourceConfig config;

  /// All configured sources. Needed by the cross-source Favorites view, which
  /// labels each row with its owning source and builds that source's
  /// repository on demand to play it — see [_ChannelListScreenState._repoFor].
  final SourceStore store;
  final VoidCallback? onManageSources;
  final Future<void> Function()? onRefreshSource;
  final Future<void> Function()? onOpenRecordings;
  final VoidCallback? onSourcePreferencesChanged;
  final Future<void> Function()? onBeforeSourcePreferences;

  /// The active profile's display name (used for the avatar initial) and its
  /// index into the avatar colour palette.
  final String? profileName;
  final int profileColorIndex;

  /// Avatar dropdown callbacks. "Profile settings" (cloud sync) is only wired
  /// when the build has cloud config; "Change profile" is always available.
  final VoidCallback? onChangeProfile;
  final VoidCallback? onProfileSettings;
  final String? initialWarning;

  const ChannelListScreen({
    super.key,
    required this.repo,
    required this.config,
    required this.store,
    this.onManageSources,
    this.onRefreshSource,
    this.onOpenRecordings,
    this.onSourcePreferencesChanged,
    this.onBeforeSourcePreferences,
    this.profileName,
    this.profileColorIndex = 0,
    this.onChangeProfile,
    this.onProfileSettings,
    this.initialWarning,
  });

  @override
  State<ChannelListScreen> createState() => _ChannelListScreenState();
}

class _ChannelListScreenState extends State<ChannelListScreen>
    with WidgetsBindingObserver {
  final _searchController = TextEditingController();
  final _parental = ParentalControlService.instance;

  List<Channel>? _organizedCache;
  (List<Channel>, SourceConfig, int)? _organizedKey;
  List<Channel> get _organizedChannels {
    final key = (_live.channels, widget.config, _parental.revision);
    if (_organizedKey == key) return _organizedCache!;
    _organizedKey = key;
    _programmeChannelIdsKey = null;
    _programmeChannelIdsCache = null;
    return _organizedCache = widget.config.channelOrganization
        .apply(_live.channels)
        .where((channel) => _channelAllowed(channel, widget.config))
        .toList();
  }

  List<GlobalFavoriteChannel>? _permittedFavoritesCache;
  (List<GlobalFavoriteChannel>, int)? _permittedFavoritesKey;
  List<GlobalFavoriteChannel> get _permittedGlobalFavorites {
    final key = (_globalFavorites.items, _parental.revision);
    if (_permittedFavoritesKey == key) return _permittedFavoritesCache!;
    _permittedFavoritesKey = key;
    return _permittedFavoritesCache = _globalFavorites.items
        .where(
          (item) =>
              !item.config.channelOrganization.hidden.contains(
                item.channel.id,
              ) &&
              _channelAllowed(item.channel, item.config),
        )
        .toList();
  }

  bool _channelAllowed(Channel channel, SourceConfig config) =>
      _parental.allows(config.id, channel.id, categoryId: channel.categoryId);

  bool _mediaAllowed(MediaItem item, [SourceConfig? owner]) => _parental.allows(
    (owner ?? widget.config).id,
    item.id,
    categoryId: item.categoryId,
    kind: item.kind,
  );

  void _parentalChanged() {
    if (!mounted) return;
    _visibleKey = null;
    _visibleMediaKey = null;
    if (_preview.channelId != null) {
      unawaited(_preview.stop(clearSelection: true));
    }
    setState(() {});
  }

  Future<void> _toggleProtectedContent() async {
    if (_parental.unlocked) {
      _parental.lock();
    } else {
      await unlockParentalContent(context);
    }
  }

  Future<void> _openAppSettings() async {
    if (!await authorizeParentalSettings(context) || !mounted) return;
    final previousFocus = FocusManager.instance.primaryFocus;
    await widget.onBeforeSourcePreferences?.call();
    if (!mounted) return;
    var restored = false;
    try {
      await _preview.stop();
      if (!mounted) return;
      restored =
          await showAppSettingsPanel(
            context: context,
            store: widget.store,
            db: widget.repo.db,
            onSourceSettings: _openChannelSettings,
            onEpgMapping: _openEpgMapping,
          ) ==
          true;
      if (!mounted) return;
      if (restored) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => ProfilePickScreen(
              db: widget.repo.db,
              store: widget.store,
              bootMode: true,
            ),
          ),
          (_) => false,
        );
        return;
      }
      if (previousFocus?.context != null) {
        previousFocus!.requestFocus();
      }
    } finally {
      // Resume pulls only after all settings pages close, and never write the
      // old profile state over a restored backup.
      if (mounted && !restored) {
        // Applying guide corrections refreshes through the active source.
        // Let it finish before the shell replaces and disposes that source.
        await widget.repo.pendingEpgRefresh;
        if (mounted) widget.onSourcePreferencesChanged?.call();
      }
    }
  }

  Future<void> _openChannelSettings() async {
    if (!await authorizeParentalSettings(context) || !mounted) return;
    final config = (await widget.store.list())
        .where((source) => source.id == widget.config.id)
        .firstOrNull;
    if (!mounted || config == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SourceSettingsScreen(
          store: widget.store,
          db: widget.repo.db,
          config: config,
        ),
      ),
    );
  }

  Future<void> _openEpgMapping() async {
    if (!await authorizeParentalSettings(context) || !mounted) return;
    await _preview.stop();
    if (!mounted) return;
    if (!_liveLoadStarted) {
      await _loadLive();
    } else {
      await _pendingLiveLoad;
    }
    if (!mounted) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EpgMappingScreen(
          repo: widget.repo,
          channels: _live.channels,
          initialChannelId: _resolvePreviewChannel(_visible)?.id,
        ),
      ),
    );
  }

  Future<void> _scheduleRecording(
    Channel channel, {
    Programme? programme,
  }) async {
    final config = _configForChannel(channel);
    if (!_channelAllowed(channel, config) &&
        !await unlockParentalContent(context)) {
      return;
    }
    if (!mounted) return;
    try {
      final profileId = await recordingProfileId(widget.repo.db);
      if (!mounted) return;
      await showRecordingScheduleDialog(
        context,
        sourceId: config.id,
        channel: channel,
        programme: programme,
        profileId: profileId,
      );
    } catch (_) {
      if (mounted) {
        _messenger.showSnackBar(
          SnackBar(
            content: Text(tr('The recording schedule could not be opened.')),
          ),
        );
      }
    }
  }

  Future<void> _openProgramme(ProgrammeSearchResult result) async {
    if (!_channelAllowed(result.channel, widget.config) &&
        !await unlockParentalContent(context)) {
      return;
    }
    if (!mounted) return;
    final channel = widget.config.channelOrganization.decorate(result.channel);
    final programme = result.programme;
    final now = DateTime.now();
    final ended = !programme.stop.isAfter(now);
    final current = !ended && !programme.start.isAfter(now);
    final canCatchup =
        ended &&
        channel.hasArchive &&
        programme.stop.isAfter(
          now.subtract(Duration(days: channel.archiveDays)),
        );
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(programme.title),
        content: SingleChildScrollView(
          child: Text(
            '${channel.name}\n${programme.start.toLocal()} – ${programme.stop.toLocal()}'
            '${programme.description == null ? '' : '\n\n${programme.description}'}',
          ),
        ),
        actions: [
          TextButton(
            autofocus: !current,
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Close')),
          ),
          if (!ended)
            TextButton.icon(
              onPressed: () => Navigator.pop(context, 'record'),
              icon: const Icon(Icons.fiber_manual_record, size: 18),
              label: Text(tr('Schedule recording')),
            ),
          if (current)
            FilledButton(
              onPressed: () => Navigator.pop(context, 'live'),
              autofocus: true,
              child: Text(tr('Play live')),
            ),
          if (canCatchup)
            FilledButton(
              onPressed: () => Navigator.pop(context, 'archive'),
              child: Text(tr('Watch catch-up')),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'record') {
      await _scheduleRecording(channel, programme: programme);
    }
    if (action == 'live') await _play(channel);
    if (action == 'archive') await _playCatchup(channel, programme);
  }

  ContentKind _tab = ContentKind.live;
  bool _showHome = true;
  int _homeVisit = 0;
  late RecentlyWatchedStore _recentlyWatched;
  bool _hasOpenedSection = false;
  final _sectionHomeFocusNode = RoutedFocusNode('library.home');
  // Search moves this toolbar out of the live pane; keep its editor focused.
  final _sectionToolbarKey = GlobalKey();
  bool _showFavorites = false;
  bool _hasVisitedFavorites = false;
  final _favoritesTabFocusNode = RoutedFocusNode('content.tab.favorites');
  final _favoritesBrowseFocusNode = FocusNode();
  final _favoritesFirstFocusNode = RoutedFocusNode('favorites.first');
  final _favoritesScrollController = ScrollController();
  FocusNode? _lastFavoritesFocus;
  int _favoritesRevision = 0;
  bool _guideMode = true;
  // Live channel/category/EPG data + load lifecycle live in a controller; the
  // screen keeps the live focus/D-pad state and preview player (see below).
  late LiveController _live;
  // Home and media sections do not need the complete cached channel catalog.
  bool _liveLoadStarted = false;
  Future<void>? _pendingLiveLoad;
  // Movies/series browsing state + async ops live in a controller per kind;
  // both persist for the screen's lifetime so state survives tab switches.
  late Map<ContentKind, MediaTabController> _mediaControllers;
  MediaTabController _media(ContentKind kind) => _mediaControllers[kind]!;
  // Favorited item ids per content kind (live channels / movies / series) live
  // in a controller; the "last favorite removed → fall back to All" handling
  // stays here (it's tied to _categoryId / the media controllers).
  late FavoritesController _favorites;

  /// The cross-source Favorites view's rows, and the per-source repositories
  /// built on demand to play them (see [_repoFor]).
  late GlobalFavoritesController _globalFavorites;
  StreamSubscription<void>? _favoritesReplacedSub;
  StreamSubscription<void>? _playbackPositionsReplacedSub;
  StreamSubscription<ContentKind>? _catalogChangedSub;
  final _pendingCatalogChanges = <ContentKind>{};
  bool _catalogReloadQueued = false;
  final Map<String, LibraryRepository> _foreignRepos = {};
  String? _categoryId;
  String _query = '';

  bool get _searchActive => _query.trim().isNotEmpty;

  bool _resolving = false;
  bool _openingMedia = false;
  bool _awaitingPreviewFullscreen = false;
  int _previewFullscreenRequest = 0;
  // Home/section/source changes invalidate pending opens without waiting for
  // the provider to finish. Their late finally blocks must not clear a new open.
  int _liveOpenGeneration = 0;

  bool _isLiveOpenCurrent(int generation) =>
      mounted && generation == _liveOpenGeneration;

  void _abandonLiveOpen() {
    _liveOpenGeneration++;
    _previewFullscreenRequest++;
    _awaitingPreviewFullscreen = false;
    _resolving = false;
    _livePlaybackEpgActive = false;
  }

  // One controller for whichever list/grid is mounted (only one exists per tab),
  // so a tab/category change can jump it back to the top.
  /// This screen owns its own [ScaffoldMessenger] (see [build]) so its
  /// snackbars can't outlive the route and paint over the pushed player.
  ///
  /// That messenger is created *inside* `build`, so it sits **below** this
  /// State's own context — `ScaffoldMessenger.of(context)` from here resolves
  /// to `MaterialApp`'s outer messenger instead, which no longer has a
  /// registered `Scaffold` and trips `assert(_scaffolds.isNotEmpty)` the
  /// moment anything tries to show a snackbar (the double-Back exit prompt was
  /// the first to hit it). Every snackbar this State shows goes through the
  /// key.
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  ScaffoldMessengerState get _messenger => _messengerKey.currentState!;

  final ScrollController _scrollController = ScrollController();
  // The live category sidebar's controller, so the focus coordinator can
  // jump-scroll an off-screen category into build range before focusing it
  // (a bare requestFocus on an unbuilt node silently no-ops).
  final ScrollController _categoryScrollController = ScrollController();
  final ValueNotifier<EpgGridSelection?> _guideSelection = ValueNotifier(null);
  // Live D-pad focus machinery (nodes, pane routing, down-hold lock, resume
  // bookkeeping) lives in the coordinator; see live_focus_coordinator.dart.
  late final LiveFocusCoordinator _focus;
  // Stable home-tile nodes restore the selected section on return. Keep one
  // flat scope with FocusTraversalGroups so D-pad movement can reach the header.
  final Map<ContentKind, FocusNode> _tabFocusNodes = {
    ContentKind.live: RoutedFocusNode('content.tab.live'),
    ContentKind.movie: RoutedFocusNode('content.tab.movie'),
    ContentKind.series: RoutedFocusNode('content.tab.series'),
  };
  final _browseFocusNodes = {
    for (final kind in [ContentKind.live, ContentKind.movie, ContentKind.series])
      kind: FocusNode(),
  };
  final _lastBrowseFocus = <ContentKind, FocusNode>{};
  final _lastMediaCategoryFocus = <ContentKind, FocusNode>{};
  final _returnToMediaCategories = <ContentKind>{};
  final _mediaTabBodies = <ContentKind, Widget>{};
  String? _lastPlayedLiveChannelId;
  // The channel played before the current one — the zap ("last channel")
  // target. Only meaningful within this screen's lifetime.
  String? _previousPlayedLiveChannelId;

  /// The last fullscreen session's "last channel" state, handed to the next
  /// session's zap controller. Each session builds its own controller, so
  /// without this the in-player recall key was dead until the user zapped
  /// *inside* the new session. Recorded only for a session whose route was
  /// actually pushed, and dropped with the repository it was played through.
  ZapRecall? _zapRecall;

  void _notePlayedChannel(String id) {
    if (_lastPlayedLiveChannelId != null && _lastPlayedLiveChannelId != id) {
      _previousPlayedLiveChannelId = _lastPlayedLiveChannelId;
    }
    _lastPlayedLiveChannelId = id;
  }

  // Live preview player + its state live in a controller; the screen keeps the
  // focus-driven preview trigger (below), fullscreen playback, and the phone
  // preview sheet, which drive it.
  late LivePreviewController _preview;
  // Focus-debounce for desktop auto-preview (stays here — it's focus timing).
  Timer? _tvIdleTimer;
  bool _tvBrowseResumed = true;
  bool _livePlaybackEpgActive = false;

  void _syncEpgRefreshActivity() {
    final liveVisible =
        _tvBrowseResumed &&
        !_showHome &&
        !_showFavorites &&
        _tab == ContentKind.live;
    final crossSource = _categoryId == kAllSourcesFavoritesCategoryId;
    _live.setEpgRefreshActive(
      _liveLoadStarted &&
          (_livePlaybackEpgActive || (liveVisible && !crossSource)),
    );
    _globalFavorites.setEpgRefreshActive(
      _livePlaybackEpgActive || (liveVisible && crossSource),
    );
  }

  Channel? get _tvIdlePreviewChannel {
    if (!mounted ||
        !isTelevision ||
        !_tvBrowseResumed ||
        _showHome ||
        !_isWide() ||
        _tab != ContentKind.live ||
        _showFavorites ||
        _searchActive ||
        _resolving ||
        _preview.loading ||
        _preview.error != null ||
        _preview.stream == null ||
        ModalRoute.of(context)?.isCurrent == false) {
      return null;
    }
    final channel = _resolvePreviewChannel(_visible);
    return channel != null && _isPreviewing(channel) ? channel : null;
  }

  void _syncTvIdleTimer() {
    if (_tvIdlePreviewChannel == null) {
      _tvIdleTimer?.cancel();
      _tvIdleTimer = null;
      return;
    }
    // Preview updates must not postpone an otherwise idle viewer's timeout.
    if (_tvIdleTimer?.isActive ?? false) return;
    _tvIdleTimer = Timer(const Duration(seconds: 30), () {
      _tvIdleTimer = null;
      final channel = _tvIdlePreviewChannel;
      if (channel != null) unawaited(_play(channel));
    });
  }

  void _resetTvIdleTimer() {
    _tvIdleTimer?.cancel();
    _tvIdleTimer = null;
    _syncTvIdleTimer();
  }

  bool _handleTvBrowseKey(KeyEvent event) {
    // Observe keys before child controls consume them, including held keys.
    _resetTvIdleTimer();
    return false;
  }

  // Controller notifications rebuild only the subtrees that read them (via
  // ListenableBuilder in build) — never the whole screen. [_dataListenable] is
  // everything except the preview; the preview's frequent loading/error ticks
  // during channel surfing only rebuild the body.
  //
  // [_focus] is deliberately **not** merged in here: it fires on every D-pad
  // press *and* every focus change, and rebuilding the whole live body for
  // those was the dominant per-frame cost under key auto-repeat. The live body
  // subscribes to the coordinator's narrow slices instead
  // (LiveFocusCoordinator.channelSelection / categorySelection / previewRegion
  // / digitEntry) — see docs/tv-navigation.md.
  late Listenable _dataListenable;
  late Listenable _bodyListenable;

  @override
  void initState() {
    super.initState();
    _tvBrowseResumed =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _createRepositoryControllers();
    _parental.addListener(_parentalChanged);
    _focus = LiveFocusCoordinator(
      scrollController: _scrollController,
      categoryScrollController: _categoryScrollController,
      visibleChannels: () => _visible,
      orderedCategoryIds: () => [
        null,
        for (final category in _liveCategoriesForUi) category.id,
      ],
      channelRowExtent: _liveChannelRowExtent,
      categoryRowExtent: _liveCategoryRowExtent,
      isWide: _isWide,
      isMounted: () => mounted,
      onChannelSelectionChanged: _onChannelSelectionChanged,
      onCategoryActivated: _selectCategory,
      onPlayChannel: _play,
      onToggleFavorite: (channel) =>
          unawaited(_toggleFavorite(ContentKind.live, channel.id)),
      onFocusTabs: _focusTabs,
      // The coordinator has no `BuildContext`, so it can't reach `appMotion`
      // itself — this callback is how the list reveal honours "remove
      // animations". Lazily evaluated (same shape as `isWide`/`isMounted`), so
      // reading `MediaQuery` here is safe despite running in `initState`.
      reduceMotion: () => mounted && MediaQuery.disableAnimationsOf(context),
    );
    _bodyListenable = Listenable.merge([_dataListenable, _preview]);
    _scrollController.addListener(_queueLiveEpgWindowRefresh);
    _focus.channelSelection.addListener(_queueLiveEpgWindowRefresh);
    FocusManager.instance.addListener(_rememberBrowseFocus);
    FocusManager.instance.addListener(_resetTvIdleTimer);
    HardwareKeyboard.instance.addHandler(_handleTvBrowseKey);
    WidgetsBinding.instance.addObserver(this);
    _globalFavorites.startEpgRefresh();
    final warning = widget.initialWarning;
    if (warning != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _messenger.showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 12),
            content: Text(warning),
          ),
        );
      });
    }
  }

  void _createRepositoryControllers() {
    _livePlaybackEpgActive = false;
    _recentlyWatched = RecentlyWatchedStore();
    _liveLoadStarted = false;
    _pendingLiveLoad = null;
    _live = LiveController(repo: widget.repo, epgChannelIds: _liveEpgWindowIds)
      ..setEpgRefreshActive(false);
    _preview = LivePreviewController(
      repo: widget.repo,
      onError: _showSnack,
      onStreamLimit: (limit) async =>
          mounted && await showProviderStreamWarning(context, limit),
    );
    _preview.addListener(_syncTvIdleTimer);
    _favorites = FavoritesController(repo: widget.repo);
    _mediaControllers = {
      for (final kind in const [ContentKind.movie, ContentKind.series])
        kind: MediaTabController(
          kind: kind,
          repo: widget.repo,
          onEnrichError: _showSnack,
        ),
    };
    _live.addListener(_reloadChangedCatalogs);
    for (final controller in _mediaControllers.values) {
      controller.addListener(_reloadChangedCatalogs);
    }
    _catalogChangedSub = widget.repo.catalogChanged.listen((kind) {
      _pendingCatalogChanges.add(kind);
      _reloadChangedCatalogs();
    });
    _globalFavorites = GlobalFavoritesController(
      db: widget.repo.db,
      store: widget.store,
    )..setEpgRefreshActive(false);
    // A cloud pull rewrites favorites without going through any controller, and
    // now runs unattended. Re-read every content kind when it does, or
    // the stars on screen keep showing the pre-pull state.
    _favoritesReplacedSub = widget.repo.db.favoritesReplaced.listen((_) {
      if (!mounted) return;
      for (final kind in const [
        ContentKind.live,
        ContentKind.movie,
        ContentKind.series,
      ]) {
        unawaited(_loadFavorites(kind));
      }
      unawaited(_globalFavorites.load());
    });
    _playbackPositionsReplacedSub = widget.repo.db.playbackPositionsReplaced
        .listen((_) {
          if (!mounted) return;
          for (final controller in _mediaControllers.values) {
            unawaited(controller.loadContinueWatching());
          }
        });
    _dataListenable = Listenable.merge([
      _live,
      _favorites,
      _globalFavorites,
      ..._mediaControllers.values,
    ]);
  }

  /// The repository that owns [sourceId] — the active one where it matches,
  /// otherwise a lightweight repository built on demand for a cross-source
  /// favorite and cached for this screen's lifetime.
  ///
  /// Share metadata clients for details, without automatically enriching
  /// another source's catalog. Each repository owns a [Source]
  /// (its provider client), so [_disposeForeignRepos] must dispose them.
  /// Takes the [SourceConfig] rather than looking one up by id: the caller
  /// already holds the row's own config, and a lookup here could throw if the
  /// cross-source list were reloaded between choosing a row and playing it.
  LibraryRepository _repoFor(SourceConfig config) {
    if (config.id == widget.repo.source.id) return widget.repo;
    return _foreignRepos.putIfAbsent(
      config.id,
      () => LibraryRepository(
        source: config.build(),
        db: widget.repo.db,
        metadataProviders: widget.repo.metadataProviders,
        autoEnrichMetadata: false,
      ),
    );
  }

  /// Remembers [label] as this source's aspect mode.
  ///
  /// Per *owning* source for a cross-source favorite, matching every other
  /// per-source lever (repository, EPG, buffering, reconnect) — a foreign row's
  /// framing belongs to its own provider, not to whichever source happens to be
  /// active.
  ///
  /// A label this build doesn't know is dropped rather than stored: it could
  /// only come from a newer build, and persisting it would keep handing this
  /// one a mode it cannot select.
  Future<void> _persistAspectMode(SourceConfig owner, String label) async {
    if (aspectModeIndexOf(label) < 0) return;
    await widget.store.saveSetting(owner.id, 'aspectMode', label);
  }

  /// The [SourceConfig] that owns [channel] — the active source's, or a
  /// cross-source favorite's own.
  SourceConfig _configForChannel(Channel channel) =>
      _crossSourceFavoriteFor(channel)?.config ?? widget.config;

  /// The buffering preset of the source that *owns* [channel].
  ///
  /// Mirrors [_repoForChannel]: a cross-source favorite plays through its own
  /// source's repository, so it must play with its own source's buffering too
  /// — reading the active source's would apply one provider's setting to
  /// another provider's stream.
  BufferPreset _bufferPresetForChannel(Channel channel) {
    final cross = _crossSourceFavoriteFor(channel);
    return bufferPresetFromName(
      (cross?.config ?? widget.config).bufferPresetName,
    );
  }

  /// The repository that owns [channel] *in the current view* — the active
  /// source's, or a cross-source favorite's owning source.
  ///
  /// Cheap outside the cross-source view: [_crossSourceFavoriteFor] returns
  /// null unless that category is selected.
  LibraryRepository _repoForChannel(Channel channel) {
    final cross = _crossSourceFavoriteFor(channel);
    return cross == null ? widget.repo : _repoFor(cross.config);
  }

  /// Whether the preview is showing (or loading) [channel] — asked with the
  /// owning source attached.
  ///
  /// Every one of these comparisons used to be `_preview.channelId ==
  /// channel.id`, which was sound only while the preview was guaranteed to be
  /// the active source's. Now that a cross-source favorite can preview, a bare
  /// id match can be a *different provider's* channel that happens to share it
  /// — and the consequences are all silent: going fullscreen on the wrong
  /// stream, suppressing a hover re-arm that should have fired, locking the
  /// panel to the wrong row.
  /// The id of the source that owns [channel] in the current view — **without
  /// building anything.**
  ///
  /// Deliberately not `_repoForChannel(channel).source.id`. That constructs a
  /// `LibraryRepository` *and* a live provider client as a side effect, and
  /// this is reached from `ListView.builder`'s item builder: scrolling the
  /// cross-source list would instantiate a provider client for every source
  /// whose row came into view, for channels the user never plays. Worse,
  /// `SourceConfig.build()` null-asserts its credential fields, so a
  /// credential-less source (an E2EE-locked device, or a cloud-pulled source
  /// whose secrets haven't arrived) would throw *inside build* and take the
  /// whole channel list down with it — where the play path catches the same
  /// throw and shows a snackbar.
  String _sourceIdForChannel(Channel channel) =>
      _crossSourceFavoriteFor(channel)?.sourceId ?? widget.repo.source.id;

  bool _isPreviewing(Channel channel) =>
      _preview.isPreviewing(_sourceIdForChannel(channel), channel.id);

  Future<void> _disposeForeignRepos() async {
    final repos = _foreignRepos.values.toList();
    _foreignRepos.clear();
    for (final repo in repos) {
      await repo.source.dispose();
    }
  }

  void _disposeRepositoryControllers() {
    _recentlyWatched.dispose();
    _pendingCatalogChanges.clear();
    unawaited(_catalogChangedSub?.cancel() ?? Future<void>.value());
    _catalogChangedSub = null;
    unawaited(_favoritesReplacedSub?.cancel() ?? Future<void>.value());
    _favoritesReplacedSub = null;
    unawaited(_playbackPositionsReplacedSub?.cancel() ?? Future<void>.value());
    _playbackPositionsReplacedSub = null;
    _live.dispose();
    _preview.removeListener(_syncTvIdleTimer);
    _preview.dispose();
    _favorites.dispose();
    _globalFavorites.dispose();
    // Fire-and-forget: each foreign repository owns a provider client whose
    // dispose is async, and neither `dispose()` nor the source-change rebuild
    // can await. Nothing reads them again — the map is cleared synchronously.
    unawaited(_disposeForeignRepos());
    for (final controller in _mediaControllers.values) {
      controller.dispose();
    }
  }

  /// The app going to the background (home button, back-exit, launcher) must
  /// not leave the preview engine running — its audio would keep playing
  /// behind the launcher (the shared native engine outlives the Flutter UI).
  /// Skipped while a fullscreen playback handoff is in flight ([_resolving]
  /// spans the whole player push): launching the native player also
  /// backgrounds this screen's lifecycle, and an adopted preview engine must
  /// keep playing through it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _tvBrowseResumed = state == AppLifecycleState.resumed;
    _syncEpgRefreshActivity();
    _resetTvIdleTimer();
    if (state != AppLifecycleState.paused) return;
    if (_resolving) return;
    if (_preview.channelId != null) {
      DiagnosticsLog.instance.add('library', 'lifecycle paused: preview stop');
      unawaited(_preview.stop(clearSelection: true));
    }
  }

  /// Guide reads follow rows on screen, retaining a little space for scrolling.
  List<String> _liveEpgWindowIds() {
    if (_categoryId == kAllSourcesFavoritesCategoryId) return const [];
    final visible = _visible;
    if (visible.isEmpty) return const [];
    final position = _scrollController.hasClients
        ? _scrollController.position
        : null;
    final extent = _liveChannelRowExtent();
    final first = position != null && position.hasContentDimensions
        ? (position.pixels / extent).floor()
        : _focus.selectedChannelIndex;
    final height = position != null && position.hasContentDimensions
        ? position.viewportDimension
        : MediaQuery.sizeOf(context).height;
    const buffer = 12;
    final start = (first - buffer).clamp(0, visible.length);
    final end = (first + (height / extent).ceil() + buffer).clamp(
      0,
      visible.length,
    );
    final preview = _resolvePreviewChannel(visible);
    return {
      for (var i = start; i < end; i++) visible[i].id,
      visible[_focus.selectedChannelIndex.clamp(0, visible.length - 1)].id,
      if (preview != null) preview.id,
    }.toList(growable: false);
  }

  bool _epgWindowRefreshScheduled = false;

  void _queueLiveEpgWindowRefresh() {
    if (_epgWindowRefreshScheduled) return;
    _epgWindowRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _epgWindowRefreshScheduled = false;
      if (!mounted ||
          _live.loading ||
          !_tvBrowseResumed ||
          _showHome ||
          _showFavorites ||
          _categoryId == kAllSourcesFavoritesCategoryId ||
          _tab != ContentKind.live) {
        return;
      }
      unawaited(_live.refreshNowNext(windowOnly: true));
    });
  }

  Future<void> _loadLive({bool forceRefresh = false}) async {
    _liveLoadStarted = true;
    _syncEpgRefreshActivity();
    final live = _live;
    live.startEpgRefresh();
    await (_pendingLiveLoad = live.load(forceRefresh: forceRefresh));
    if (!mounted || !identical(live, _live)) return;
    _focus.clampSelection();
    await _loadFavorites(ContentKind.live);
    if (!mounted || !identical(live, _live)) return;
    // Cross-source rows come from the cache, not from this source's load, so
    // this neither waits on nor blocks the active catalog.
    await _globalFavorites.load();
    if (mounted) _ensureCrossSourceCategoryStillOffered();
  }

  @override
  void didUpdateWidget(covariant ChannelListScreen old) {
    super.didUpdateWidget(old);
    if (!identical(old.repo, widget.repo)) {
      _abandonLiveOpen();
      _tvIdleTimer?.cancel();
      _tvIdleTimer = null;
      _lastBrowseFocus.clear();
      _lastMediaCategoryFocus.clear();
      _returnToMediaCategories.clear();
      _mediaTabBodies.clear();
      _guideSelection.value = null;
      _disposeRepositoryControllers();
      _createRepositoryControllers();
      _bodyListenable = Listenable.merge([_dataListenable, _preview]);
      _visibleKey = null;
      _visibleCache = null;
      _visibleMediaKey = null;
      _visibleMediaCache = null;
      _channelsByIdKey = null;
      _channelsByIdCache = null;
      _programmeChannelIdsKey = null;
      _programmeChannelIdsCache = null;
      _crossSourceIndexKey = null;
      _crossSourceIndexCache = null;
      _focus.resetChannelSelection();
      _zapRecall = null;
      if (!_showHome && !_showFavorites && _tab == ContentKind.live) {
        unawaited(_loadLive());
      }
      _globalFavorites.startEpgRefresh();
      if (!_showHome &&
          !_searchActive &&
          !_showFavorites &&
          _tab != ContentKind.live) {
        _loadMediaTab(_tab);
      }
    }
    // Source settings may have changed while we were away (the config is a fresh
    // object after a reload). If the category currently selected was just
    // disabled, fall back to "All" so we don't show an empty, unselectable view.
    if (!identical(old.config, widget.config)) {
      if (_hiddenCategories(ContentKind.live).contains(_categoryId)) {
        _categoryId = null;
      }
      for (final kind in const [ContentKind.movie, ContentKind.series]) {
        if (_hiddenCategories(kind).contains(_media(kind).categoryId)) {
          _loadMediaTab(kind, category: null, switchCategory: true);
        }
      }
    }
    _syncEpgRefreshActivity();
  }

  void _reloadChangedCatalogs() {
    if (_catalogReloadQueued || _pendingCatalogChanges.isEmpty) return;
    _catalogReloadQueued = true;
    scheduleMicrotask(() {
      _catalogReloadQueued = false;
      if (!mounted) return;
      for (final kind in _pendingCatalogChanges.toList()) {
        if (kind == ContentKind.live) {
          if (!_liveLoadStarted) {
            _pendingCatalogChanges.remove(kind);
            continue;
          }
          if (_live.loading) continue;
          _pendingCatalogChanges.remove(kind);
          unawaited(_loadLive());
        } else {
          final controller = _media(kind);
          if (controller.loading) continue;
          _pendingCatalogChanges.remove(kind);
          if (controller.snapshot != null) _loadMediaTab(kind);
        }
      }
    });
  }

  void _showSnack(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// Load a media tab and its favorites together (favorites live in the parent,
  /// not the controller). [category] optionally switches category first.
  void _loadMediaTab(
    ContentKind kind, {
    String? category,
    bool switchCategory = false,
    bool forceRefresh = false,
  }) {
    final controller = _media(kind);
    if (switchCategory) {
      unawaited(controller.setCategory(category));
    } else {
      unawaited(controller.load(forceRefresh: forceRefresh));
    }
    unawaited(_loadFavorites(kind));
  }

  @override
  void dispose() {
    _abandonLiveOpen();
    _scrollController.removeListener(_queueLiveEpgWindowRefresh);
    _focus.channelSelection.removeListener(_queueLiveEpgWindowRefresh);
    FocusManager.instance.removeListener(_rememberBrowseFocus);
    FocusManager.instance.removeListener(_resetTvIdleTimer);
    HardwareKeyboard.instance.removeHandler(_handleTvBrowseKey);
    _tvIdleTimer?.cancel();
    _parental.removeListener(_parentalChanged);
    WidgetsBinding.instance.removeObserver(this);
    _disposeRepositoryControllers();
    _focus.dispose();
    for (final node in _tabFocusNodes.values) {
      node.dispose();
    }
    for (final node in _browseFocusNodes.values) {
      node.dispose();
    }
    _searchController.dispose();
    _scrollController.dispose();
    _categoryScrollController.dispose();
    _guideSelection.dispose();
    _sectionHomeFocusNode.dispose();
    _favoritesTabFocusNode.dispose();
    _favoritesBrowseFocusNode.dispose();
    _favoritesFirstFocusNode.dispose();
    _favoritesScrollController.dispose();
    super.dispose();
  }

  /// Browsing must not open provider streams. On every platform the preview
  /// starts only on an explicit play/OK action and stays on that channel.
  bool get _deliberatePreview => true;

  DvrRecording? _recordingFor(Channel channel, LibraryRepository repo) {
    final recording = DvrService.instance.activeRecording;
    return recordingMatchesChannel(
          recording,
          sourceId: repo.source.id,
          channelId: channel.id,
        )
        ? recording
        : null;
  }

  void _onChannelSelectionChanged(Channel channel, bool hasFocus) {
    // Selection and pointer movement only browse. Playback requires play/OK.
  }

  Channel? _findChannelById(String id) => _channelsById[id];

  void _restoreListFocusAfterPlayback() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Only the visible top route may own the D-pad. When playback was
      // launched from a *pushed* route (e.g. the EPG grid), that route is
      // still on top after the player pops — requesting focus on the covered
      // channel list here would steal primaryFocus cross-route (FocusManager
      // has no notion of routes) and leave the visible screen's D-pad dead.
      // Flutter's own route focus restoration re-focuses that route's node.
      if (ModalRoute.of(context)?.isCurrent == false) return;
      if (_showHome) {
        _focusTabs();
        return;
      }
      // The route restores the selected search result.
      if (_searchActive) return;
      if (_showFavorites) {
        _restoreBrowseFocus();
        return;
      }
      if (_tab == ContentKind.live) {
        _focus.restoreSelectionToChannel(_lastPlayedLiveChannelId);
        return;
      }
      if (_tab == ContentKind.movie || _tab == ContentKind.series) {
        if (_visibleMedia(_tab).isEmpty) return;
        _media(_tab).firstFocusNode.requestFocus();
      }
    });
  }

  /// Modal routes normally restore focus, but that restoration is timing
  /// dependent when a sheet rebuilds the lazy list behind it. Keep an explicit
  /// handle to the browsing target and restore it after ordinary dismissal.
  /// A sheet action that immediately opens playback is excluded; the player
  /// return path owns focus in that case.
  void _restoreFocusAfterModal(FocusNode? previousFocus) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _resolving) return;
      if (ModalRoute.of(context)?.isCurrent == false) return;
      if (previousFocus?.context != null && previousFocus!.canRequestFocus) {
        previousFocus.requestFocus();
        return;
      }
      if (_showHome) {
        _focusTabs();
        return;
      }
      if (_searchActive) {
        _focus.focusSearch();
      } else if (_showFavorites) {
        if (!_restoreBrowseFocus()) _focusTabs();
      } else if (_tab == ContentKind.live) {
        _focus.focusChannels();
      } else if (_visibleMedia(_tab).isNotEmpty) {
        _media(_tab).firstFocusNode.requestFocus();
      } else {
        _focusTabs();
      }
    });
  }

  void _setQuery(String value) {
    final wasSearching = _searchActive;
    setState(() => _query = value);
    _resetTvIdleTimer();
    if (_searchActive && !wasSearching) {
      unawaited(_preview.stop());
    }
    _focus.resetChannelSelection();
    _focus.clampSelection();
    if (!_searchActive &&
        !_showFavorites &&
        _tab != ContentKind.live &&
        _media(_tab).snapshot == null &&
        !_media(_tab).loading) {
      _loadMediaTab(_tab);
    }
  }

  /// Category ids the user disabled for [kind] in source settings.
  Set<String> _hiddenCategories(ContentKind kind) => {
    ...widget.config.hiddenCategoryIds(kind),
    if (_parental.rules.enabled && !_parental.unlocked)
      ..._parental.rules.categoryIds(widget.config.id, kind),
  };

  Set<String> _favoriteIds(ContentKind kind) => _favorites.ids(kind);

  bool _isFavorite(ContentKind kind, String id) =>
      _favorites.isFavorite(kind, id);

  Future<void> _loadFavorites(ContentKind kind) => _favorites.load(kind);

  /// Set an absolute favorite state (used by the fullscreen player's overlay
  /// star, which reports the desired final state rather than a toggle). Reuses
  /// [_toggleFavorite] so the empty-Favorites-view fallback still applies.
  Future<void> _setLiveFavorite(String id, bool favorite) async {
    if (_isFavorite(ContentKind.live, id) == favorite) return;
    await _toggleFavorite(ContentKind.live, id);
  }

  /// Unfavorite (or re-favorite) a channel belonging to a source other than the
  /// active one, from the player's star.
  ///
  /// Writes straight to the cache: [FavoritesController] holds only the active
  /// source's ids, so routing this through it would toggle the wrong source's
  /// favorite — or, where the ids happen to collide, the wrong channel.
  Future<void> _setForeignFavorite(
    String sourceId,
    String channelId,
    bool favorite,
  ) async {
    await widget.repo.db.setFavorite(
      sourceId,
      ContentKind.live,
      channelId,
      favorite,
    );
    if (!mounted) return;
    if (favorite) {
      // Re-favorited from the player: re-read so the row comes back in order.
      await _globalFavorites.load();
    } else {
      _globalFavorites.removeLocally(sourceId, channelId);
    }
    if (mounted) _ensureCrossSourceCategoryStillOffered();
    if (mounted) _focus.clampSelection();
  }

  /// Flips a foreign channel's favorite state, in whichever direction it is
  /// currently in. Used where the control is a true toggle (the phone preview
  /// sheet) rather than the cross-source list's remove-only star.
  Future<void> _toggleForeignFavorite(String sourceId, String channelId) async {
    final favorited = _permittedGlobalFavorites.any(
      (item) => item.sourceId == sourceId && item.channel.id == channelId,
    );
    await _setForeignFavorite(sourceId, channelId, !favorited);
  }

  /// Star pressed on a row of the cross-source view.
  ///
  /// Every row there *is* a favorite, so the only meaningful action is removing
  /// it — and it has to be removed from the source that owns it. Matching the
  /// id against the visible rows keeps this correct when the same provider
  /// channel id exists in several sources.
  Future<void> _unfavoriteCrossSourceRow(String channelId) async {
    for (final item in _permittedGlobalFavorites) {
      if (item.channel.id != channelId) continue;
      // A row from the *active* source goes through the normal path so the
      // per-source Favorites view's in-memory set stays in step; only a truly
      // foreign row needs the direct write.
      if (item.sourceId == widget.repo.source.id) {
        await _toggleFavorite(ContentKind.live, channelId);
      } else {
        await _setForeignFavorite(item.sourceId, channelId, false);
      }
      return;
    }
  }

  Future<void> _toggleFavorite(ContentKind kind, String id) async {
    final nowEmpty = await _favorites.toggle(kind, id);
    if (!mounted) return;
    if (kind == ContentKind.live) {
      // The cross-source view reads the same `favorites` table through its own
      // controller, which this write goes nowhere near — so without this it only
      // caught up on the next full reload, and a channel starred from the
      // ordinary list simply wasn't in "Favorites · All sources" until the user
      // refreshed, while the per-source Favorites view updated instantly.
      //
      // Incremental (see `applyLocalChange`), because this is a star press: a
      // full reload would re-read the OS keychain and requery every contributing
      // source on every one.
      final channel = _channelsById[id];
      if (channel != null) {
        unawaited(
          _globalFavorites.applyLocalChange(
            config: widget.config,
            channel: channel,
            favorite: _isFavorite(ContentKind.live, id),
          ),
        );
      }
      _focus.clampSelection();
    }
    if (!nowEmpty) return;
    // Emptying the Favorites view leaves nothing to select — fall back to All.
    setState(() {
      if (kind == ContentKind.live && _categoryId == kFavoritesCategoryId) {
        _categoryId = null;
      } else if (kind != ContentKind.live) {
        _media(kind).resetFavoritesCategoryToAll();
      }
    });
  }

  /// True when the cross-source view has something the per-source one doesn't.
  /// Also decides whether its category entry is offered at all.
  bool get _hasForeignFavorites => _permittedGlobalFavorites.any(
    (item) => item.sourceId != widget.repo.source.id,
  );

  /// Falls back to "All" when the cross-source view is selected but no longer
  /// offered — unfavoriting the last foreign favorite, or switching to a source
  /// where every remaining favorite is local.
  ///
  /// Same reason the per-source Favorites view has this: the entry vanishes
  /// from the pane while `_categoryId` still points at it, leaving an empty
  /// list selected on a category the user cannot see or move off.
  void _ensureCrossSourceCategoryStillOffered() {
    if (!shouldLeaveCrossSourceFavoritesView(
      categoryId: _categoryId,
      hasForeignFavorites: _hasForeignFavorites,
    )) {
      return;
    }
    setState(() => _categoryId = null);
    _syncEpgRefreshActivity();
    _focus.resetChannelSelection();
    _focus.clampSelection();
    // Leaving the cross-source view also changes the row extent (those rows
    // carry no EPG, so they run on the shorter one — `liveRowsShowEpg`), which
    // makes the retained pixel offset mean a different row than it did a frame
    // ago. Every other category switch resets the cursor and the scroll for the
    // same reason; this fallback is a category switch too, just one the user
    // didn't press.
    _scrollToTop();
  }

  /// Live categories shown in the pane/dropdown: the Favorites entry (only when
  /// something is favorited) followed by the enabled provider categories.
  List<Category> get _liveCategoriesForUi {
    final cats = _visibleCategories;
    final hasOwn = _favoriteIds(ContentKind.live).isNotEmpty;
    // "All sources" only earns a row when it would actually show something the
    // per-source view doesn't: favorites living in a *different* source. With
    // one source configured (or favorites in only this one) the two lists are
    // identical, and a duplicate entry is just noise on a remote.
    final hasForeign = _hasForeignFavorites;
    if (!hasOwn && !hasForeign) return cats;
    return [
      if (hasOwn) Category(id: kFavoritesCategoryId, title: tr('Favorites')),
      if (hasForeign)
        Category(
          id: kAllSourcesFavoritesCategoryId,
          title: tr('Favorites · All sources'),
        ),
      ...cats,
    ];
  }

  List<MediaCategory> _mediaCategoriesForUi(ContentKind kind) {
    final cats = _visibleMediaCategories(kind);
    if (_favoriteIds(kind).isEmpty) return cats;
    return [
      MediaCategory(
        id: kFavoritesCategoryId,
        title: tr('Favorites'),
        kind: kind,
      ),
      ...cats,
    ];
  }

  /// Live categories with disabled ones removed (for the pane/dropdown).
  List<Category> get _visibleCategories {
    final hidden = _hiddenCategories(ContentKind.live);
    return [
      for (final group in widget.config.channelOrganization.groups)
        Category(id: group.id, title: group.name),
      for (final category in _live.categories)
        if (!hidden.contains(category.id) &&
            _parental.allowsCategory(
              widget.config.id,
              ContentKind.live,
              category.id,
            ))
          category,
    ];
  }

  /// Media categories for [kind] with disabled ones removed.
  List<MediaCategory> _visibleMediaCategories(ContentKind kind) {
    final all = _media(kind).snapshot?.categories ?? const <MediaCategory>[];
    final hidden = _hiddenCategories(kind);
    return all
        .where(
          (c) =>
              !hidden.contains(c.id) &&
              _parental.allowsCategory(widget.config.id, kind, c.id),
        )
        .toList();
  }

  // Memoized filtered channel list. [_visible] is read from the build path
  // *and* every D-pad key event (move-down, focus restore, prune), so on a
  // large playlist an unmemoized O(N) filter would run several times per key
  // repeat. The key fields compare by identity (List/Set/SourceConfig don't
  // override ==): the controllers reassign fresh collections on change, and
  // the config is a fresh object per reload.
  List<Channel>? _visibleCache;
  (
    String?,
    String,
    List<Channel>,
    Set<String>,
    SourceConfig,
    List<GlobalFavoriteChannel>, // cross-source rows, reassigned on change
  )?
  _visibleKey;

  // Preview and last-played resolution look channels up by id on every body
  // rebuild — which is every D-pad press — and they search the *unfiltered*
  // catalogue, so an unmemoized scan is O(N) per keypress on a large portal.
  // Keyed on the channel list's identity, like _visibleCache above: the
  // controller reassigns a fresh list on change.
  Map<String, Channel>? _channelsByIdCache;
  List<Channel>? _channelsByIdKey;

  Map<String, Channel> get _channelsById {
    final channels = _organizedChannels;
    if (identical(_channelsByIdKey, channels)) return _channelsByIdCache!;
    _channelsByIdKey = channels;
    return _channelsByIdCache = {for (final c in channels) c.id: c};
  }

  List<Channel> get _visible {
    final key = (
      _categoryId,
      _query.trim().toLowerCase(),
      _organizedChannels,
      _favoriteIds(ContentKind.live),
      widget.config,
      _permittedGlobalFavorites,
    );
    if (_visibleKey == key) return _visibleCache!;
    _visibleKey = key;
    return _visibleCache = _computeVisible();
  }

  List<Channel> _computeVisible() {
    final q = _query.trim().toLowerCase();
    if (_searchActive) {
      final hidden = _hiddenCategories(ContentKind.live);
      return _organizedChannels
          .where(
            (channel) =>
                !hidden.contains(channel.categoryId) &&
                channel.name.toLowerCase().contains(q),
          )
          .toList();
    }
    // The cross-source view is not a filter over the loaded catalog — its rows
    // come from the cache across every source, so it replaces the list rather
    // than narrowing it. Category hiding is per-source and deliberately not
    // applied: a favorite is an explicit pick, exactly as in the per-source
    // Favorites view.
    if (_categoryId == kAllSourcesFavoritesCategoryId) {
      return [
        for (final item in _permittedGlobalFavorites)
          if (q.isEmpty || item.channel.name.toLowerCase().contains(q))
            item.channel,
      ];
    }
    final favoritesView = _categoryId == kFavoritesCategoryId;
    final customGroup = widget.config.channelOrganization.group(_categoryId);
    final groupMembers = customGroup?.channelIds.toSet();
    final favs = favoritesView ? _favoriteIds(ContentKind.live) : null;
    final hidden = _hiddenCategories(ContentKind.live);
    final matched = _organizedChannels.where((c) {
      if (favoritesView) {
        // Favorites are explicit picks, shown even from a disabled category.
        if (!favs!.contains(c.id)) return false;
      } else {
        if (hidden.contains(c.categoryId)) return false;
        if (groupMembers != null) {
          if (!groupMembers.contains(c.id)) return false;
        } else if (_categoryId != null && c.categoryId != _categoryId) {
          return false;
        }
      }
      if (q.isNotEmpty && !c.name.toLowerCase().contains(q)) return false;
      return true;
    }).toList();
    if (!favoritesView) return matched;
    // Favorites read in catalog order: category order first, then the channel
    // order inside it — which `matched` already carries, having been filtered
    // straight out of the catalog. Every other category view is a single
    // category, so only this one has any grouping to do. Ranked against the
    // *full* category list rather than the visible one, because a favorite is
    // deliberately still shown when its category is disabled.
    final categoryRanks = catalogRanks(_live.categories.map((c) => c.id));
    return orderedByCatalog(
      matched,
      categoryRank: (c) => rankOf(categoryRanks, c.categoryId),
    );
  }

  // Memoized filtered media list, for the same reason as [_visible]: it is read
  // from both `_statusText` and `_buildBody`, which each listen to
  // `_dataListenable`, so a single notification re-filtered and re-allocated it
  // twice. Metadata enrichment is the worst case — the media controller
  // notifies once per 20-item chunk, and every live/favorites notification used
  // to pay for it too. Key fields compare by identity (MediaLibrarySnapshot,
  // List, Set and SourceConfig don't override ==) and the controller reassigns
  // fresh collections on every mutation (`_replaceItems` copies the snapshot and
  // the search results), so a stale hit is impossible.
  List<MediaItem>? _visibleMediaCache;
  (
    ContentKind,
    MediaTabController,
    String?, // controller.categoryId
    String, // trimmed query (the lowercased form is derived from it)
    String?, // controller.searchQuery
    MediaLibrarySnapshot?,
    List<MediaItem>, // controller.searchResults
    Set<String>, // favorites for this kind
    SourceConfig, // hidden categories
  )?
  _visibleMediaKey;

  List<MediaItem> _visibleMedia(ContentKind kind) {
    final controller = _media(kind);
    final key = (
      kind,
      controller,
      controller.categoryId,
      _query.trim(),
      controller.searchQuery,
      controller.snapshot,
      controller.searchResults,
      _favoriteIds(kind),
      widget.config,
    );
    if (_visibleMediaKey == key) return _visibleMediaCache!;
    _visibleMediaKey = key;
    return _visibleMediaCache = _computeVisibleMedia(kind);
  }

  List<MediaItem> _computeVisibleMedia(ContentKind kind) {
    final controller = _media(kind);
    final q = _query.trim().toLowerCase();
    final favoritesView = controller.categoryId == kFavoritesCategoryId;
    final favs = favoritesView ? _favoriteIds(kind) : null;
    final hidden = _hiddenCategories(kind);
    if (q.length >= 2 && controller.searchQuery == _query.trim()) {
      final results = controller.searchResults;
      return results.where((item) {
        if (!_mediaAllowed(item)) return false;
        if (favoritesView) return favs!.contains(item.id);
        return !hidden.contains(item.categoryId);
      }).toList();
    }
    final items = controller.snapshot?.items ?? const <MediaItem>[];
    final matched = items.where((item) {
      if (!_mediaAllowed(item)) return false;
      if (favoritesView) {
        if (!favs!.contains(item.id)) return false;
      } else {
        if (hidden.contains(item.categoryId)) return false;
      }
      if (q.isNotEmpty && !item.title.toLowerCase().contains(q)) return false;
      return true;
    }).toList();
    if (!favoritesView) return matched;
    // Same rule as the live Favorites view — see `_computeVisible`.
    final categoryRanks = catalogRanks(
      (controller.snapshot?.categories ?? const <MediaCategory>[]).map(
        (c) => c.id,
      ),
    );
    return orderedByCatalog(
      matched,
      categoryRank: (item) => rankOf(categoryRanks, item.categoryId),
    );
  }

  /// The cross-source favorite backing [channel], or null when this isn't the
  /// "All sources" view.
  ///
  /// Matched by **identity**, not by id: the same provider channel id can exist
  /// in several sources — the duplicate case this whole view has to handle —
  /// and the visible list holds the controller's own [Channel] instances, so
  /// identity is exact where an id would be ambiguous.
  /// Lookup tables for [_crossSourceFavoriteFor], rebuilt only when the
  /// controller republishes its list.
  ///
  /// That resolver runs for **every visible row on every rebuild** — now twice
  /// per row, once for the source chip and once for the guide — and the live
  /// list rebuilds on every D-pad press. Two linear scans of the whole
  /// favorites list per call is precisely the shape that makes a remote feel
  /// unresponsive, so it is a pair of maps instead. Keyed on the list's
  /// identity, like [_channelsById]: the controller assigns a fresh list on
  /// every change.
  ({
    Map<Channel, GlobalFavoriteChannel> byInstance,
    Map<String, GlobalFavoriteChannel> byId,
  })?
  _crossSourceIndexCache;
  List<GlobalFavoriteChannel>? _crossSourceIndexKey;

  ({
    Map<Channel, GlobalFavoriteChannel> byInstance,
    Map<String, GlobalFavoriteChannel> byId,
  })
  get _crossSourceIndex {
    final items = _permittedGlobalFavorites;
    if (identical(_crossSourceIndexKey, items)) return _crossSourceIndexCache!;
    _crossSourceIndexKey = items;
    // Explicitly identity-keyed: `Channel` has no `==` override today, and this
    // must not silently become a value lookup if one is ever added — the whole
    // point of the first probe is that it beats an ambiguous id.
    final byInstance = Map<Channel, GlobalFavoriteChannel>.identity();
    final byId = <String, GlobalFavoriteChannel>{};
    for (final item in items) {
      byInstance[item.channel] = item;
      // First match wins, as the scan it replaces did.
      byId.putIfAbsent(item.channel.id, () => item);
    }
    return _crossSourceIndexCache = (byInstance: byInstance, byId: byId);
  }

  GlobalFavoriteChannel? _crossSourceFavoriteFor(Channel channel) {
    if ((_searchActive && !_showFavorites) ||
        (!_showFavorites && _categoryId != kAllSourcesFavoritesCategoryId)) {
      return null;
    }
    final index = _crossSourceIndex;
    // Identity first — exact even when two sources carry the same channel id,
    // which is the duplicate case this view exists to disambiguate.
    //
    // Then by id. `load()` republishes fresh `Channel` instances (a re-favorite
    // from the player, a `_loadLive` refresh), so a reload between the frame
    // that built the row and this callback running would miss on identity
    // alone — and falling through would play a *foreign* channel through the
    // active source's repository. Ambiguous only when the same id exists in
    // several sources and the instance is stale, which is strictly better than
    // resolving against the wrong provider outright.
    return index.byInstance[channel] ?? index.byId[channel.id];
  }

  /// Now/next for [channel], resolved through whichever source owns it.
  ///
  /// A [foreign] row's guide lives under **its own** source id. Reading the
  /// active source's maps by channel id would show a *different* provider's
  /// programme against this channel, because provider ids are unique only
  /// within a provider — which is exactly the collision this view puts two of
  /// in one list.
  ///
  /// Every surface that prints a programme goes through here: the row, the
  /// preview panel, the phone preview sheet and the fullscreen player. They
  /// used to hand a foreign row `null` on all four, so a cross-source favorite
  /// showed no guide anywhere.
  ({Programme? now, Programme? next}) _epgFor(
    Channel channel, {
    required bool foreign,
    required String sourceId,
  }) => foreign || !_liveLoadStarted
      ? _globalFavorites.epgFor(sourceId, channel.id)
      : _live.epgForChannel(channel.id);

  /// Now/next for a row of the cross-source Favorites view.
  ///
  /// Resolved through the row's **owning** source, which is the entire reason
  /// this view can carry a guide at all: the active source's maps are keyed by
  /// channel id, and a foreign row's id can mean a different channel there — so
  /// reading them would print that provider's programme against this one.
  ///
  /// A foreign source's guide is only refreshed while that source is active, so
  /// it can be stale. That degrades to *nothing* rather than to something
  /// wrong: both halves of the query are bounded by the current instant, so an
  /// out-of-date guide simply stops matching and the row draws plain.
  ({Programme? now, Programme? next}) _crossSourceEpgFor(Channel channel) {
    final item = _crossSourceFavoriteFor(channel);
    if (item == null) return (now: null, next: null);
    return _globalFavorites.epgFor(item.sourceId, item.channel.id);
  }

  // ── In-player live zapping ─────────────────────────────────────────────────

  /// The channels an in-player zap may walk — the *launch range*.
  ///
  /// It is deliberately the list the user was looking at, not the whole
  /// source: Up/Down in the player should mean the same thing Up/Down meant in
  /// the list they came from. Three shapes:
  ///
  /// - the **cross-source Favorites** view contributes its own rows, each with
  ///   the `SourceConfig` that owns it — zapping across providers is the one
  ///   case where consecutive entries resolve through different repositories;
  /// - a **search** has no meaningful neighbours ("the next result" is not a
  ///   next channel), so it falls back to the whole active source, minus the
  ///   categories the user disabled;
  /// - otherwise the visible category, in catalog order.
  ///
  /// [explicit] overrides all of it — the EPG grid hands over the list it is
  /// showing, which is what its Up/Down already walks.
  ({List<ZapEntry> entries, int index, String categoryId, String label})
  _zapRangeFor(Channel channel, {List<Channel>? explicit}) {
    if ((!_searchActive || _showFavorites) &&
        explicit == null &&
        (_showFavorites || _categoryId == kAllSourcesFavoritesCategoryId)) {
      final items = _permittedGlobalFavorites;
      var index = items.indexWhere((item) => identical(item.channel, channel));
      if (index < 0) {
        index = items.indexWhere((item) => item.channel.id == channel.id);
      }
      if (index >= 0) {
        return (
          entries: [
            for (final item in items)
              ZapEntry(
                channel: item.channel,
                config: item.config,
                sourceName: item.sourceLabel,
              ),
          ],
          index: index,
          categoryId: '',
          label: tr('Favorites · All sources'),
        );
      }
    }
    final channels =
        explicit ??
        (_query.trim().isEmpty ? _visible : _unhiddenLiveChannels());
    // Indexed over the *channels*, before they are wrapped: the wrapper is
    // lazy precisely so an unfiltered 250k-channel range costs nothing, and
    // scanning wrapped entries would throw that away.
    var index = channels.indexWhere((c) => identical(c, channel));
    if (index < 0) index = channels.indexWhere((c) => c.id == channel.id);
    if (index < 0) {
      // Not in the range after all (a hidden category reached through search,
      // a list that moved under us). A one-entry range makes zapping an
      // honest no-op rather than walking a list this channel isn't in.
      return (
        entries: zapEntriesOf(
          [channel],
          config: _configForChannel(channel),
          sourceName: widget.repo.source.name,
        ),
        index: 0,
        categoryId: '',
        label: channel.name,
      );
    }
    // The quick list's channels-mode heading, and the category its own
    // categories mode opens pre-selected on. A search fallback and the EPG
    // grid's explicit list are both "everything" as far as re-ranging goes —
    // neither is a category the provider knows about, and both are ranges the
    // user can only have reached deliberately.
    final ranged = explicit == null && _query.trim().isEmpty;
    final categoryId = ranged ? (_categoryId ?? '') : '';
    return (
      entries: zapEntriesOf(
        channels,
        config: widget.config,
        sourceName: widget.repo.source.name,
      ),
      index: index,
      categoryId: categoryId,
      label: _categoryTitleFor(categoryId),
    );
  }

  /// Display title for a live category id, `''` meaning "All channels" — the
  /// same wording the sidebar's first row uses.
  String _categoryTitleFor(String categoryId) {
    if (categoryId.isEmpty) return tr('All channels');
    for (final category in _liveCategoriesForUi) {
      if (category.id == categoryId) return category.title;
    }
    return tr('All channels');
  }

  /// The active source's channels in one category, in catalog order, with no
  /// search filter — what the quick list re-ranges a session to.
  ///
  /// Deliberately the same rules [_computeVisible] applies (hidden categories
  /// dropped, a Favorites view ranked by the catalog) minus the query, so a
  /// range picked in the player is the range the list would have shown.
  List<Channel> _liveChannelsForCategory(String? categoryId) {
    final favoritesView = categoryId == kFavoritesCategoryId;
    final customGroup = widget.config.channelOrganization.group(categoryId);
    final groupMembers = customGroup?.channelIds.toSet();
    final favs = favoritesView ? _favoriteIds(ContentKind.live) : null;
    final hidden = _hiddenCategories(ContentKind.live);
    final matched = _organizedChannels
        .where((c) {
          if (favoritesView) return favs!.contains(c.id);
          if (hidden.contains(c.categoryId)) return false;
          if (groupMembers != null) {
            if (!groupMembers.contains(c.id)) return false;
          } else if (categoryId != null && c.categoryId != categoryId) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
    if (!favoritesView) return matched;
    final categoryRanks = catalogRanks(_live.categories.map((c) => c.id));
    return orderedByCatalog(
      matched,
      categoryRank: (c) => rankOf(categoryRanks, c.categoryId),
    );
  }

  /// The active source's channels minus the categories the user disabled —
  /// the search-launch zap range. Hidden categories are excluded because the
  /// user turned them off; a search *result* from one is still playable, it
  /// just isn't somewhere Up/Down should wander into.
  List<Channel> _unhiddenLiveChannels() {
    final hidden = _hiddenCategories(ContentKind.live);
    if (hidden.isEmpty) return _organizedChannels;
    return _organizedChannels
        .where((c) => !hidden.contains(c.categoryId))
        .toList(growable: false);
  }

  List<Channel>? _programmeChannelIdsKey;
  Set<String>? _programmeChannelIdsCache;

  Set<String> get _programmeChannelIds {
    // This list's identity already tracks the catalog, source settings and
    // parental revision. Reusing the set avoids scanning the whole catalog
    // and comparing two large sets on unrelated search-view rebuilds.
    final channels = _organizedChannels;
    if (identical(_programmeChannelIdsKey, channels)) {
      return _programmeChannelIdsCache!;
    }
    final hidden = _hiddenCategories(ContentKind.live);
    _programmeChannelIdsKey = channels;
    return _programmeChannelIdsCache = {
      for (final channel in channels)
        if (!hidden.contains(channel.categoryId)) channel.id,
    };
  }

  /// Builds the zap controller for one fullscreen session. Live only — VOD and
  /// catch-up have no channel neighbours.
  LiveZapController _zapControllerFor(
    Channel channel, {
    List<Channel>? explicit,
  }) {
    final range = _zapRangeFor(channel, explicit: explicit);
    final catalog = _ChannelListZapCatalog(this);
    final zap =
        LiveZapController(
            entries: range.entries,
            initialIndex: range.index,
            rangeCategoryId: range.categoryId,
            rangeLabel: range.label,
            recall: _zapRecall,
            catalog: catalog,
          )
          ..onChannelChanged = (entry) {
            unawaited(
              _recentlyWatched.record(
                entry.sourceId,
                ContentKind.live,
                entry.channelId,
              ),
            );
            // Keeps the toolbar's "last channel" target and the post-playback
            // selection restore pointed at the channel the session is really on.
            if (mounted) _notePlayedChannel(entry.channelId);
          };
    catalog.bind(zap);
    return zap;
  }

  /// A session the quick list re-ranged ends on a channel from the range it
  /// was re-ranged *to*, which the list it launched from may not contain —
  /// restoring selection there fell back to the first row. Follow the session
  /// into its category so the row it ended on is the one selected.
  ///
  /// Only an active-source category is followed. The cross-source Favorites
  /// range re-ranges by *owning source*, which is not a category this list
  /// has; every row of those sub-ranges is still in the view it launched from.
  void _followZapRange(LiveZapController zap) {
    if (_searchActive) return;
    if (!zap.zapped || !zap.reRanged) return;
    if (_showFavorites || _tab != ContentKind.live) return;
    if (_categoryId == kAllSourcesFavoritesCategoryId) return;
    final id = zap.rangeCategoryId;
    if (id.startsWith(_kZapSourcePrefix)) return;
    final categoryId = id.isEmpty ? null : id;
    if (categoryId == _categoryId) return;
    setState(() => _categoryId = categoryId);
    _focus.syncCategorySelection(categoryId);
  }

  Future<void> _play(Channel channel) async {
    final generation = _liveOpenGeneration;
    if (!_channelAllowed(channel, _configForChannel(channel))) {
      if (!await unlockParentalContent(context) || !mounted) return;
    }
    if (!_isLiveOpenCurrent(generation)) return;
    if (_resolving) {
      if (!_awaitingPreviewFullscreen || _isPreviewing(channel)) return;
      // A second OK waits for this preview, but choosing another channel
      // cancels that fullscreen intent instead of locking channel switching.
      ++_previewFullscreenRequest;
      _awaitingPreviewFullscreen = false;
      _resolving = false;
    }
    final isWide = isWideLayout(MediaQuery.sizeOf(context));
    // A cross-source favorite plays through *its own* source's repository, on
    // every path below — the preview, the resolve, the fullscreen route and
    // that route's reconnect re-resolve. Resolving it against the active
    // source would hand provider A a channel id that means something else
    // there (or nothing), and spend a single-use create_link doing it.
    final playRepo = _repoForChannel(channel);
    if (_showFavorites) {
      await _openFullscreenDirect(channel, playRepo);
      return;
    }
    final recording = _recordingFor(channel, playRepo);
    if (recording != null) {
      if (!isWide) {
        await _openFullscreenDirect(channel, playRepo);
        return;
      }
      try {
        // A preview is a separate provider connection. The local recording
        // owns this channel now, so close that preview before attaching the
        // player to the capture.
        if (_preview.channelId != null || _preview.nativeActive) {
          await _preview.stop(clearSelection: true);
        }
        final stream = await DvrService.instance.recordingPlayback(recording);
        if (!_isLiveOpenCurrent(generation)) return;
        await _openLivePlayer(
          channel,
          stream,
          reusePreview: false,
          repo: playRepo,
        );
      } catch (error) {
        if (_isLiveOpenCurrent(generation)) {
          _messenger.showSnackBar(
            SnackBar(
              content: Text(
                tr('Could not play: {error}', {'error': playbackErrorMessage(error)}),
              ),
            ),
          );
        }
      }
      return;
    }
    if (_searchActive || !isWide) {
      await _openFullscreenDirect(channel, playRepo);
      return;
    }

    // On wide screens, reconcile with whatever this channel's preview is doing.
    switch (decideChannelPlayAction(
      sameChannelPreview: _isPreviewing(channel),
      previewHasStream: _preview.stream != null,
      previewLoading: _preview.loading,
    )) {
      case ChannelPlayAction.openFullscreen:
        await _openLivePlayer(channel, _preview.stream!, repo: playRepo);
      case ChannelPlayAction.awaitPreviewThenOpen:
        await _openLivePlayerWhenPreviewReady(channel, repo: playRepo);
      case ChannelPlayAction.startPreview:
        // First OK starts the preview; on a TV remote it's deliberate, so
        // unmuted.
        if (isTelevision) {
          _focus.focusChannels();
        }
        await _preview.start(
          channel,
          muted: !_deliberatePreview,
          from: playRepo,
          bufferPreset: _bufferPresetForChannel(channel),
        );
    }
  }

  /// Resolve and open fullscreen with no preview involved, through [repo] —
  /// the active source's on a narrow screen, or the owning source's for a
  /// cross-source favorite.
  Future<void> _openFullscreenDirect(
    Channel channel,
    LibraryRepository repo,
  ) async {
    final generation = _liveOpenGeneration;
    if (!_channelAllowed(channel, _configForChannel(channel)) &&
        !await unlockParentalContent(context)) {
      return;
    }
    if (!_isLiveOpenCurrent(generation)) return;
    // A repository other than the active one means a cross-source favorite:
    // its EPG and favorite state live under its own source id, not the active
    // controllers' (which only ever hold the active source).
    final foreign = !identical(repo, widget.repo);
    // **Silence any running preview first.** This body used to be the
    // narrow-screen path only, where no preview exists — it is now also the
    // cross-source path on wide screens, where one may well be playing. A
    // non-adopted fullscreen that leaves the preview running doubles the audio
    // and holds a second provider connection open. Stopped, not paused: the
    // channel is by definition a different one, so its connection must go.
    if (_preview.channelId != null || _preview.nativeActive) {
      await _preview.stop();
    }
    if (!_isLiveOpenCurrent(generation)) return;
    {
      setState(() => _resolving = true);
      // Zapping is not a wide-layout privilege: a phone with a keyboard, and
      // any set-top box that fell to the narrow layout, reach this path too.
      final zap = _zapControllerFor(channel);
      ({ZapEntry entry, Programme programme})? pendingCatchup;
      var opened = false;
      try {
        (zap.catalog as _ChannelListZapCatalog).checkTargetAllowed(zap.current);
        if (!_isLiveOpenCurrent(generation)) return;
        DiagnosticsLog.instance.add(
          'library',
          'open live fullscreen source=${repo.source.name} channel=${channel.name} id=${channel.id}',
        );
        final recording = _recordingFor(channel, repo);
        final stream = recording == null
            ? await repo.resolve(channel)
            : await DvrService.instance.recordingPlayback(recording);
        if (!_isLiveOpenCurrent(generation)) return;
        _notePlayedChannel(channel.id);
        unawaited(
          _recentlyWatched.record(repo.source.id, ContentKind.live, channel.id),
        );
        opened = true;
        final epg = _epgFor(
          channel,
          foreign: foreign,
          sourceId: repo.source.id,
        );
        if (!mounted) return;
        await Navigator.of(context).push(
          PageRouteBuilder(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, _, _) => PlayerScreen(
              title: channel.name,
              stream: stream,
              sourceName: repo.source.name,
              dvrSourceId: repo.source.id,
              dvrChannelId: channel.id,
              dvrChannelName: channel.name,
              zap: zap,
              bufferPreset: _bufferPresetForChannel(channel),
              initialAspectLabel: _configForChannel(channel).aspectModeLabel,
              onAspectChanged: (label) => unawaited(
                _persistAspectMode(_configForChannel(channel), label),
              ),
              epgNow: epg.now,
              epgNext: epg.next,
              favoriteInitial: foreign
                  ? true
                  : _isFavorite(ContentKind.live, channel.id),
              onSetFavorite: (fav) => foreign
                  ? _setForeignFavorite(repo.source.id, channel.id, fav)
                  : _setLiveFavorite(channel.id, fav),
              // Live reloads (reconnect watchdog, "Go to live") re-resolve
              // through the source: Stalker create_link tokens are
              // single-use, so the originally resolved URL is dead after any
              // portal-side kill.
              resolveAgain: () => repo.resolve(channel),
              iosEngineKey: iosEngineMemoKeyForChannel(
                sourceId: repo.source.id,
                channelId: channel.id,
              ),
            ),
          ),
        );
        if (_isLiveOpenCurrent(generation)) _restoreListFocusAfterPlayback();
      } catch (e) {
        if (_isLiveOpenCurrent(generation)) {
          _messenger.showSnackBar(
            SnackBar(
              content: Text(
                tr('Could not play: {error}', {'error': playbackErrorMessage(e)}),
              ),
            ),
          );
        }
      } finally {
        pendingCatchup = zap.pendingCatchup;
        if (opened && _isLiveOpenCurrent(generation)) _zapRecall = zap.recall;
        (zap.catalog as _ChannelListZapCatalog).dispose();
        zap.dispose();
        if (_isLiveOpenCurrent(generation)) setState(() => _resolving = false);
      }
      if (_isLiveOpenCurrent(generation)) {
        await _runPendingZapRequest(pendingCatchup);
      }
    }
  }

  /// Second OK on a channel whose preview is still resolving: wait for the
  /// resolve already in flight and then hand it to fullscreen, rather than
  /// starting a competing one (see [ChannelPlayAction.awaitPreviewThenOpen]).
  ///
  /// Repeated OK on this channel shares the wait. Selecting another channel
  /// cancels this fullscreen intent and starts that channel's preview.
  Future<void> _openLivePlayerWhenPreviewReady(
    Channel channel, {
    LibraryRepository? repo,
  }) async {
    final request = ++_previewFullscreenRequest;
    _awaitingPreviewFullscreen = true;
    setState(() => _resolving = true);
    try {
      await _preview.pendingStart;
    } finally {
      if (request == _previewFullscreenRequest) {
        _awaitingPreviewFullscreen = false;
        if (mounted) setState(() => _resolving = false);
      }
    }
    if (!mounted || request != _previewFullscreenRequest) return;
    // The wait can end in something other than "this channel is playing": the
    // resolve failed, or a newer `start` superseded it. Open only what actually
    // came up, and never restart anything from here — a failed preview shows
    // its own error and the next OK retries it.
    if (!_isPreviewing(channel) || _preview.stream == null) return;
    await _openLivePlayer(channel, _preview.stream!, repo: repo);
  }

  /// Opens fullscreen playback for [channel]/[stream]. When [reusePreview] and
  /// the preview is already showing this exact channel, the fullscreen player
  /// *adopts* the running preview engine instead of resolving/opening fresh:
  /// on Android the native Activity takes over the shared ExoPlayer engine
  /// (only the video surface moves — audio and buffer never stop); elsewhere
  /// the same media_kit [Player] is handed to [PlayerScreen]. On Linux that
  /// covers SDR and all of X11; only a **Wayland HDR** source instead takes
  /// the non-seamless native mpv path (it can't adopt anything — see
  /// [FullscreenHandoff.stopResolveFresh]). Seamless adoption leaves the
  /// preview playing, not paused, around the handoff.
  ///
  /// [resumePreviewOnReturn] is false for the phone sheet (no panel to return
  /// to): the preview is stopped once fullscreen exits instead of resumed.
  Future<void> _openLivePlayer(
    Channel channel,
    StreamInfo stream, {
    bool reusePreview = true,
    bool resumePreviewOnReturn = true,
    LibraryRepository? repo,
    List<Channel>? zapChannels,
  }) async {
    final generation = _liveOpenGeneration;
    if (!_channelAllowed(channel, _configForChannel(channel)) &&
        !await unlockParentalContent(context)) {
      return;
    }
    if (!_isLiveOpenCurrent(generation)) return;
    // The owning source: the active one for an ordinary channel, another
    // provider's for a cross-source favorite. Everything the route needs from
    // "the source" comes from here — name, re-resolve, reconnect — and the
    // things that live only under the *active* source (EPG, the favorites set)
    // are answered differently when they disagree.
    final playRepo = repo ?? widget.repo;
    final foreign = !identical(playRepo, widget.repo);
    setState(() => _resolving = true);
    if (!mounted) return;
    final navigator = Navigator.of(context);
    final messenger = _messenger;
    var playbackStream = stream;
    // Set only while the Wayland+HDR stop-and-resolve-fresh path below has
    // torn the preview down but not yet completed the fullscreen push — if
    // resolve() or route setup throws in that window, the catch block
    // restarts the same preview so the pane doesn't sit dead until an
    // unrelated selection change.
    var restorePreviewOnFailure = false;
    // Assigned once `decision` is known (inside the try, after the await
    // below) — declared here so the catch block can still read it.
    var previewWasMuted = false;
    // The session's channel cursor. Owned here, not by the route: the route
    // reads through it while it is up, and the return leg below reads where
    // the session *ended* — which is not where it started as soon as the user
    // zaps.
    final zap = _zapControllerFor(channel, explicit: zapChannels);
    ({ZapEntry entry, Programme programme})? pendingCatchup;
    var opened = false;
    try {
      (zap.catalog as _ChannelListZapCatalog).checkTargetAllowed(zap.current);
      if (!_isLiveOpenCurrent(generation)) return;
      DiagnosticsLog.instance.add(
        'library',
        'open live fullscreen source=${playRepo.source.name} channel=${channel.name} id=${channel.id}',
      );
      _notePlayedChannel(channel.id);
      // Native discovery can require an external mpv version probe on its
      // first call. The result only matters for a same-channel HDR preview;
      // probing for SDR or a non-adoptable preview added avoidable latency to
      // ordinary opens after the Linux native path was introduced.
      final initialSameChannelPreview = _preview.isPreviewing(
        playRepo.source.id,
        channel.id,
      );
      final initialPreviewHasStream = _preview.stream != null;
      final initialStreamLikelyHdr = _preview.hasEmbeddedPlayer
          ? isHdrColorimetry(
              gamma: _preview.player.state.videoParams.gamma,
              primaries: _preview.player.state.videoParams.primaries,
              matrix: _preview.player.state.videoParams.colormatrix,
            )
          : false;
      final shouldProbeLinux = shouldProbeLinuxNativeForHandoff(
        isLinux: Platform.isLinux && !PlaybackBackend.isCustom,
        reusePreview: reusePreview,
        sameChannelPreview: initialSameChannelPreview,
        previewHasStream: initialPreviewHasStream,
        streamLikelyHdr: initialStreamLikelyHdr,
      );
      final linuxNative =
          shouldProbeLinux && await LinuxNativeSession.nativeLikelyAvailable();
      if (!_isLiveOpenCurrent(generation)) return;
      // Preview state is read exactly once, here — after every await that
      // precedes the decision — and every downstream boolean is derived from
      // `decision` alone. A previous version recomputed an "adoptPreview"
      // local from preview state read *before* the await above while
      // `decision` read it after; a preview-state change mid-await (e.g. the
      // native engine reporting mid-flight that a channel is unsupported)
      // could desync the two, risking double audio or a second provider
      // connection. Reading once also fixed a latent bug: the old duplicate
      // formula ignored the isAndroid gate baked into `decideFullscreenHandoff`,
      // so an Android same-channel *fallback* preview (native engine not
      // active) — correctly decided as pausePreview — was nonetheless treated
      // as adoptable at the `existingPlayer`/restore-mute call sites below.
      final previewChannelId = _preview.channelId;
      // Read here with the rest of the preview state, not via
      // `_preview.isPreviewing` — the read-once discipline above is the whole
      // point of this block, and a helper that re-reads the controller would
      // reintroduce exactly the desync it exists to prevent.
      final previewSourceId = _preview.previewSourceId;
      final previewNativeActive = _preview.nativeActive;
      final previewStream = _preview.stream;
      final previewStreamUrl = previewStream?.url;
      final previewHasExternalSubtitles =
          previewStream?.subtitles.isNotEmpty ?? false;
      final previewHasStream = previewStreamUrl != null;
      final previewMuted = _preview.isMuted;
      final previewPlaying = previewChannelId != null || previewNativeActive;
      // "Same channel" means same *source* too: the identical id in another
      // provider's list is a different channel, and adopting its engine would
      // put provider A's stream behind provider B's title.
      final sameChannelPreview =
          previewChannelId == channel.id &&
          previewSourceId == playRepo.source.id;
      // Read the preview engine's current colorimetry: only a Wayland *HDR*
      // source justifies the native mpv path's non-seamless fresh-resolve cost
      // (SDR/X11 stay embedded/seamless). The embedded preview player carries
      // media_kit's videoParams; guard on hasEmbeddedPlayer so we never
      // lazily spin one up (and it's always false on Android's native preview).
      final streamLikelyHdr = _preview.hasEmbeddedPlayer
          ? isHdrColorimetry(
              gamma: _preview.player.state.videoParams.gamma,
              primaries: _preview.player.state.videoParams.primaries,
              matrix: _preview.player.state.videoParams.colormatrix,
            )
          : false;
      // iOS: the preview is always embedded media_kit/libmpv, but an
      // AVPlayer-routed channel goes fullscreen on a presented AVPlayerLayer
      // controller — a different engine, so nothing can be adopted. Cheap to
      // decide (a pure function of the already-resolved preview URL, no probe),
      // so it's computed inline with the rest of the once-only preview read.
      final crossEngine =
          Platform.isIOS &&
          previewStreamUrl != null &&
          selectIosEngine(
                url: previewStreamUrl,
                memoKey: iosEngineMemoKeyForChannel(
                  sourceId: playRepo.source.id,
                  channelId: channel.id,
                ),
                hasExternalSubtitles: previewHasExternalSubtitles,
                forcedMpv: IosEngineMemo.forcedMpv,
              ) ==
              IosPlaybackEngine.avPlayer;
      final decision = decideFullscreenHandoff(
        reusePreview: reusePreview,
        sameChannelPreview: sameChannelPreview,
        previewHasStream: previewHasStream,
        isAndroid: Platform.isAndroid,
        nativePreviewActive: previewNativeActive,
        linuxNativeLikely: linuxNative,
        previewPlaying: previewPlaying,
        streamLikelyHdr: streamLikelyHdr,
        crossEngineFullscreen: crossEngine,
      );
      final adoptNative = decision.adoptsNativePreview;
      // Covers both cross-engine shapes: Linux Wayland-HDR native mpv and iOS
      // AVPlayer. Only the Linux one sets `preferLinuxNative` below.
      final stopResolveFresh = decision.stopsAndResolvesFresh;
      // Same channel (a media_kit-fallback preview going native-fullscreen):
      // pause and resume on return. A *different* channel (the "last channel"
      // zap / EPG-grid play, which resolve fresh with reusePreview: false and so
      // never adopt the engine previewing whatever else): stop it outright — not
      // just pause — so we neither double the audio nor hold a second provider
      // connection open (single-connection accounts would refuse the new stream).
      final pausedPreview = decision.pausesPreview;
      final stoppedPreview = decision.stopsPreview;
      // Fullscreen always plays at full volume; used to restore a muted
      // (desktop auto-hover) preview once we return. True for every decision
      // that adopts the running engine (seamlessly or via the Wayland+HDR
      // stop-and-resolve-fresh path) — not for a merely paused/stopped one.
      previewWasMuted =
          (decision.seamless || decision.stopsAndResolvesFresh) && previewMuted;
      DiagnosticsLog.instance.add(
        'library',
        'fullscreen open decision=${decision.name} linuxNative=$linuxNative '
            'hdr=$streamLikelyHdr crossEngine=$crossEngine',
      );
      if (stoppedPreview) {
        await _preview.stop();
      } else if (pausedPreview) {
        // A paused decoder still owns its provider connection. The fullscreen
        // engine cannot borrow it, so release it before opening another one.
        await _preview.stop();
      } else if (stopResolveFresh) {
        // The incoming engine (Linux native mpv process / iOS AVPlayer) opens
        // its own provider connection — a merely-paused media_kit engine would
        // still hold its connection open (a single-connection portal then sees
        // two, fighting each other in a create_link storm), and the preview's
        // already-resolved stream carries a spent single-use Stalker
        // play_token — so stop outright and re-resolve fresh instead of
        // reusing `stream`.
        await _preview.stop();
        // If resolve() or the route setup below throws before the push goes
        // through, the catch block restarts this same preview — otherwise it
        // would sit dead (channelId set, stream null) until an unrelated
        // selection change.
        restorePreviewOnFailure = true;
        playbackStream = await playRepo.resolve(channel);
      }
      if (!_isLiveOpenCurrent(generation)) return;
      final epg = _epgFor(
        channel,
        foreign: foreign,
        sourceId: playRepo.source.id,
      );
      // Context-independent on purpose — nothing in the player derives from
      // the route builder's element.
      Widget buildPlayer() => PlayerScreen(
        title: channel.name,
        stream: playbackStream,
        sourceName: playRepo.source.name,
        dvrSourceId: playRepo.source.id,
        dvrChannelId: channel.id,
        dvrChannelName: channel.name,
        // Live zapping: from here on the *controller* answers "which channel
        // is this?", including for the reconnect re-resolve, the favourite
        // star and the stored aspect mode. The fields around it stay as the
        // initial values.
        zap: zap,
        bufferPreset: _bufferPresetForChannel(channel),
        initialAspectLabel: _configForChannel(channel).aspectModeLabel,
        onAspectChanged: (label) =>
            unawaited(_persistAspectMode(_configForChannel(channel), label)),
        epgNow: epg.now,
        epgNext: epg.next,
        existingPlayer: decision.adoptsEmbeddedPreview ? _preview.player : null,
        existingController: decision.adoptsEmbeddedPreview
            ? _preview.controller
            : null,
        adoptNativePreview: adoptNative,
        providerStreamOwner:
            decision.adoptsEmbeddedPreview || adoptNative
            ? _preview.providerStreamOwner
            : null,
        // Wayland+HDR: open straight to native mpv (the preview was stopped and
        // `playbackStream` re-resolved fresh above). SDR/X11 open embedded and
        // escalate to native later only if the source turns out to be HDR.
        // Explicitly Linux-gated: iOS reaches `stopResolveFresh` too (the
        // AVPlayer cross-engine case), and must not ask for a Linux mpv process.
        preferLinuxNative:
            Platform.isLinux && !PlaybackBackend.isCustom && stopResolveFresh,
        // iOS: stable content id for the AVPlayer-failure memo, so a container
        // sniff that turns out wrong is remembered per channel.
        iosEngineKey: iosEngineMemoKeyForChannel(
          sourceId: playRepo.source.id,
          channelId: channel.id,
        ),
        // Windows: keep an adopted **SDR** preview on its embedded texture for a
        // seamless handoff both ways (no `vo` swap to the native HWND, preview
        // never disposed). HDR keeps the native HWND path for real D3D11 HDR —
        // the same SDR-embedded / HDR-dedicated split Linux uses.
        preferWindowsEmbedded:
            decision.adoptsEmbeddedPreview &&
            Platform.isWindows &&
            !streamLikelyHdr,
        // `FavoritesController` holds only the active source's ids, so a
        // foreign row's star has to be answered — and written — against its own
        // source. A cross-source row is by definition favorited.
        favoriteInitial: foreign
            ? true
            : _isFavorite(ContentKind.live, channel.id),
        onSetFavorite: (fav) => foreign
            ? _setForeignFavorite(playRepo.source.id, channel.id, fav)
            : _setLiveFavorite(channel.id, fav),
        // Live reloads (reconnect watchdog, "Go to live") re-resolve through
        // the source: Stalker create_link tokens are single-use, so the
        // originally resolved URL is dead after any portal-side kill.
        resolveAgain: () => playRepo.resolve(channel),
      );
      // Keep an adopted preview mounted under the route while PlayerScreen
      // paints a full-screen loader and the Activity takes its running engine.
      // Non-opaque is a lifecycle requirement here, not a transparent UI.
      // Start opening immediately. The default Material route animates for
      // ~300 ms while the player is already resolving/decoding, which makes
      // preview→fullscreen feel slower on every platform and delays the first
      // visible frame behind an opaque transition. Ordinary routes are opaque;
      // Android adoption retains the underlying preview without an animation.
      final route = PageRouteBuilder<bool>(
        opaque: !adoptNative,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => buildPlayer(),
      );
      unawaited(
        _recentlyWatched.record(playRepo.source.id, ContentKind.live, channel.id),
      );
      // The embedded seamless handoff hands `_preview.player` to the fullscreen
      // route, so from here until the pop that one engine has two live-EOF
      // watchdogs on it. Silence the preview's for the duration — the
      // fullscreen one owns recovery, and the preview's would reopen the stream
      // under it and reset the volume to the preview's mute state (see
      // [LivePreviewController.adoptedByFullscreen]).
      _preview.adoptedByFullscreen = decision.seamless;
      opened = true;
      final hotSwapped = await navigator.push<bool>(route) ?? false;
      // The push (and whatever PlayerScreen did while up) completed — a
      // failure past this point isn't the stop-and-resolve-fresh setup
      // failing, so the catch block no longer needs to restart the preview.
      restorePreviewOnFailure = false;
      DiagnosticsLog.instance.add(
        'library',
        'fullscreen returned hotSwapped=$hotSwapped mounted=$mounted '
            'previewStream=${_preview.stream != null}',
      );
      if (!_isLiveOpenCurrent(generation)) return;
      // The session left the channel it was launched on. Whatever the handoff
      // decision was, the preview must not come back on the *launch* channel:
      // it would caption and play something the user navigated away from
      // minutes ago, and on an adopted engine it would be the one still
      // holding this account's single connection.
      final zapped = zap.zapped;
      final endedRecording = _recordingFor(
        zap.playing.channel,
        _repoFor(zap.playing.config),
      );
      if (zapped && decision.seamless && endedRecording == null) {
        // The adopted engine really is playing the zapped-to channel, so say
        // so before anything acts on the controller's state — an EOF landing
        // in this window would otherwise restart the launch channel.
        _preview.adoptFullscreenChannel(
          zap.playing.channel,
          from: _repoFor(zap.playing.config),
          bufferPreset: _bufferPresetForChannel(zap.playing.channel),
        );
      }
      switch (decidePreviewReturn(
        hotSwapped: hotSwapped,
        resumePreviewOnReturn: resumePreviewOnReturn,
        zapped: zapped,
        decision: decision,
        previewHasStream: _preview.stream != null,
      )) {
        case PreviewReturnAction.discardPlayer:
          // The fullscreen player re-pointed this player's video output at the
          // Windows native HDR surface, which just tore down — no longer safe
          // to reuse for the preview's embedded texture.
          await _preview.discardPlayer();
        case PreviewReturnAction.stop:
          await _preview.stop(clearSelection: true);
        case PreviewReturnAction.restartOnEndedChannel:
          // Stop before starting: whatever the preview holds (the launch
          // channel, or the adopted engine the zap drove) owns the account's
          // one connection, and the fresh resolve needs it.
          final ended = zap.playing;
          await _preview.stop();
          if (!_isLiveOpenCurrent(generation)) break;
          final endedRepo = _repoFor(ended.config);
          if (_recordingFor(ended.channel, endedRepo) == null) {
            await _preview.start(
              ended.channel,
              muted: previewWasMuted,
              from: endedRepo,
              bufferPreset: _bufferPresetForChannel(ended.channel),
            );
          }
        case PreviewReturnAction.restartSameChannel:
          // Same-channel cross-engine stop is the one stop case that restarts:
          // the preview was stopped only to free the connection/token for the
          // other engine (Linux native mpv / iOS AVPlayer), not because the
          // user left the channel.
          if (_recordingFor(channel, playRepo) == null) {
            await _preview.start(
              channel,
              muted: previewWasMuted,
              from: playRepo,
              bufferPreset: _bufferPresetForChannel(channel),
            );
          }
        case PreviewReturnAction.resumeAdopted:
          if (_recordingFor(channel, playRepo) != null) {
            await _preview.stop(clearSelection: true);
          } else {
            await _preview.play();
            if (previewWasMuted) await _preview.setMuted(true);
          }
        case PreviewReturnAction.resumePaused:
          // This decoder was stopped to release its upstream connection.
          // Resolve/open again rather than trying to resume a stopped player.
          if (_recordingFor(channel, playRepo) != null) {
            await _preview.stop(clearSelection: true);
          } else {
            await _preview.start(
              channel,
              muted: previewMuted,
              from: playRepo,
              bufferPreset: _bufferPresetForChannel(channel),
            );
          }
        case PreviewReturnAction.none:
          break;
      }
      if (!_isLiveOpenCurrent(generation)) return;
      // Only now: the restore above is the preview's own re-entry, and
      // `PlayerScreen.dispose` (which pauses the adopted player and drops its
      // `completed` subscription) is not guaranteed to have finished when the
      // route popped. Handing recovery back any earlier lets a `completed`
      // landing in that window restart the channel underneath the restore — and
      // on the `hotSwapped` branch, restart a player about to be discarded.
      _preview.adoptedByFullscreen = false;
      _followZapRange(zap);
      _restoreListFocusAfterPlayback();
    } catch (e) {
      if (!_isLiveOpenCurrent(generation)) return;
      if (restorePreviewOnFailure && _recordingFor(channel, playRepo) == null) {
        DiagnosticsLog.instance.add(
          'library',
          'fullscreen stop-resolve failed — restarting preview '
              'channel=${channel.id}',
        );
        try {
          await _preview.start(
            channel,
            muted: previewWasMuted,
            from: playRepo,
            bufferPreset: _bufferPresetForChannel(channel),
          );
        } catch (_) {}
      }
      if (!_isLiveOpenCurrent(generation)) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            tr('Could not play: {error}', {'error': playbackErrorMessage(e)}),
          ),
        ),
      );
    } finally {
      // Belt-and-braces for the throw-before-pop path: a preview left marked as
      // adopted would never recover from an EOF again.
      if (_isLiveOpenCurrent(generation)) {
        _preview.adoptedByFullscreen = false;
      }
      // Outlives the route by exactly this block — `PlayerScreen.dispose`
      // unhooks itself, and the return leg above has finished reading it.
      pendingCatchup = zap.pendingCatchup;
      if (opened && _isLiveOpenCurrent(generation)) _zapRecall = zap.recall;
      (zap.catalog as _ChannelListZapCatalog).dispose();
      zap.dispose();
      if (_isLiveOpenCurrent(generation)) setState(() => _resolving = false);
    }
    if (_isLiveOpenCurrent(generation)) {
      await _runPendingZapRequest(pendingCatchup);
    }
  }

  /// Resolve [channel] and play it fullscreen directly, bypassing the preview
  /// flow (used by zap and the EPG grid).
  Future<void> _playChannelFullscreen(
    Channel channel, {
    List<Channel>? zapChannels,
  }) async {
    if (_resolving) return;
    final generation = _liveOpenGeneration;
    if (!_channelAllowed(channel, widget.config) &&
        !await unlockParentalContent(context)) {
      return;
    }
    if (!_isLiveOpenCurrent(generation)) return;
    // Set before the resolve (not just before the push): _openLivePlayer's
    // own guard only takes effect once it's called, and resolve() itself can
    // take a while (Stalker create_link), leaving a window for a second
    // activation to slip past the `if (_resolving) return` above and
    // double-push. _openLivePlayer's finally resets this once it runs; the
    // finally below only fires (i.e. `_resolving` is still true) when
    // resolve() itself threw before ever reaching it.
    setState(() => _resolving = true);
    final messenger = _messenger;
    try {
      final recording = _recordingFor(channel, widget.repo);
      final stream = recording == null
          ? await widget.repo.resolve(channel)
          : await DvrService.instance.recordingPlayback(recording);
      if (!_isLiveOpenCurrent(generation)) return;
      await _openLivePlayer(
        channel,
        stream,
        reusePreview: false,
        zapChannels: zapChannels,
      );
    } catch (e) {
      if (!_isLiveOpenCurrent(generation)) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            tr('Could not play: {error}', {'error': playbackErrorMessage(e)}),
          ),
        ),
      );
    } finally {
      if (_isLiveOpenCurrent(generation) && _resolving) {
        setState(() => _resolving = false);
      }
    }
  }

  /// Zap straight back to the previously played live channel — classic
  /// "last channel" recall.
  Future<void> _zapToPreviousChannel() async {
    final id = _previousPlayedLiveChannelId;
    final channel = id == null ? null : _findChannelById(id);
    if (channel != null) await _playChannelFullscreen(channel);
  }

  /// Open the TV-guide grid for the currently visible channels.
  void _openEpgGrid() {
    unawaited(_preview.stop());
    // The grid is single-source by construction: it takes one repository and
    // resolves every play through it, and its guide rows come from that
    // source's `programmes`. Handing it the cross-source list would show an
    // empty guide and then resolve a foreign channel against the wrong
    // provider, so that view opens the grid over the active source's channels
    // instead of its own rows.
    final channels = _categoryId == kAllSourcesFavoritesCategoryId
        ? _organizedChannels
        : _visible;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EpgGridScreen(
          repo: widget.repo,
          channels: channels,
          onPlayChannel: (channel) => unawaited(
            // The grid's Up/Down already walks this list; the player's should
            // walk the same one.
            _playChannelFullscreen(channel, zapChannels: channels),
          ),
          onPlayArchive: (channel, programme) =>
              unawaited(_playCatchup(channel, programme)),
          onScheduleRecording: (channel, programme) =>
              unawaited(_scheduleRecording(channel, programme: programme)),
        ),
      ),
    );
  }

  /// Phone-only: open a compact, audible preview of [channel] in a bottom
  /// sheet (tap on a tile still goes straight to fullscreen). Reuses the single
  /// preview player; the sheet's Play button hands off to fullscreen.
  Future<void> _showPreviewSheet(Channel channel) async {
    if (_resolving) return;
    if (!_channelAllowed(channel, _configForChannel(channel)) &&
        !await unlockParentalContent(context)) {
      return;
    }
    if (!mounted) return;
    // The owning source. This path used to resolve every row through the
    // *active* repository, including a cross-source favorite — the "never
    // preview a foreign row" rule was enforced on the OK and hover paths but
    // not here, so a long-press in the cross-source view asked provider A for
    // provider B's channel id.
    final previewRepo = _repoForChannel(channel);
    if (_recordingFor(channel, previewRepo) != null) {
      await _play(channel);
      return;
    }
    final foreign = !identical(previewRepo, widget.repo);
    final previousFocus = FocusManager.instance.primaryFocus;
    unawaited(
      _preview.start(
        channel,
        muted: false,
        from: previewRepo,
        bufferPreset: _bufferPresetForChannel(channel),
      ),
    );
    // Set when Play hands the preview to fullscreen — the handoff owns the
    // preview's lifecycle from there (stopped when fullscreen exits), so the
    // post-sheet cleanup below must leave it alone.
    var handedOff = false;
    final epg = _epgFor(
      channel,
      foreign: foreign,
      sourceId: previewRepo.source.id,
    );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => PhonePreviewSheet(
        preview: _preview,
        channel: channel,
        // A cross-source row's guide and favorite state live under its own
        // source id, not the active controllers' — see `_epgFor`.
        now: epg.now,
        next: epg.next,
        // A cross-source row is favorited by definition when the sheet opens,
        // so `true` is the right *initial* value — the sheet keeps its own
        // optimistic state from there.
        favorite: foreign ? true : _isFavorite(ContentKind.live, channel.id),
        // A real toggle, not the list row's unfavorite-only action: the sheet
        // flips its own star, so wiring the row's callback here left a second
        // tap unable to put the favorite back — the star read "not favorited"
        // and tapping it did nothing.
        onToggleFavorite: () => foreign
            ? unawaited(
                _toggleForeignFavorite(previewRepo.source.id, channel.id),
              )
            : _toggleFavorite(ContentKind.live, channel.id),
        onCatchup: channel.hasArchive ? () => _showCatchupSheet(channel) : null,
        onPlay: () {
          final stream = _preview.stream;
          Navigator.of(sheetContext).pop();
          if (stream != null && _isPreviewing(channel)) {
            handedOff = true;
            // A native preview hands off seamlessly (the fullscreen Activity
            // adopts its engine); the media_kit fallback still opens fresh.
            // Either way there's no panel to return to, so the preview is
            // stopped when fullscreen exits rather than resumed.
            unawaited(
              _openLivePlayer(
                channel,
                stream,
                reusePreview: _preview.nativeActive,
                resumePreviewOnReturn: false,
                repo: previewRepo,
              ),
            );
          } else {
            unawaited(_play(channel));
          }
        },
      ),
    );
    if (!handedOff) await _preview.stop(clearSelection: true);
    _restoreFocusAfterModal(previousFocus);
  }

  /// Open the catch-up picker for an archive-capable [channel]: list its cached
  /// past programmes and play the chosen one via [_playCatchup].
  Future<void> _showCatchupSheet(Channel channel) async {
    if (_resolving) return;
    final messenger = _messenger;
    final programmes = await widget.repo.archiveProgrammes(channel);
    if (!mounted) return;
    if (programmes.isEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(tr('No catch-up guide cached for this channel yet')),
        ),
      );
      return;
    }
    final previousFocus = FocusManager.instance.primaryFocus;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => CatchupSheet(
        channel: channel,
        // Most recent first.
        programmes: programmes.reversed.toList(),
        onPlay: (programme) {
          Navigator.of(sheetContext).pop();
          unawaited(_playCatchup(channel, programme));
        },
      ),
    );
    _restoreFocusAfterModal(previousFocus);
  }

  /// Resolve a past [programme] to a catch-up stream and open it fullscreen.
  ///
  /// [repo]/[config] name the **owning** source when the channel isn't the
  /// active one — a cross-source favorite, or a row the in-player quick list
  /// picked out of a re-ranged session. Everything about a catch-up open is
  /// per-owning-source for the same reasons a live open is (resolve, buffer
  /// preset, stored aspect).
  Future<void> _playCatchup(
    Channel channel,
    Programme programme, {
    LibraryRepository? repo,
    SourceConfig? config,
  }) async {
    if (_resolving) return;
    final generation = _liveOpenGeneration;
    final playRepo = repo ?? widget.repo;
    final playConfig = config ?? _configForChannel(channel);
    if (!_channelAllowed(channel, playConfig)) {
      if (!await unlockParentalContent(context) || !mounted) return;
    }
    if (!_isLiveOpenCurrent(generation)) return;
    setState(() => _resolving = true);
    final navigator = Navigator.of(context);
    final messenger = _messenger;
    try {
      await _preview.pause();
      if (!_isLiveOpenCurrent(generation)) return;
      DiagnosticsLog.instance.add(
        'library',
        'open catch-up source=${playRepo.source.name} channel=${channel.name} programme=${programme.title} start=${programme.start.toIso8601String()}',
      );
      _notePlayedChannel(channel.id);
      final stream = await playRepo.resolveArchive(channel, programme);
      if (!_isLiveOpenCurrent(generation)) return;
      await navigator.push(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            title: '${channel.name} · ${programme.title}',
            stream: stream,
            sourceName: playRepo.source.name,
            bufferPreset: bufferPresetFromName(playConfig.bufferPresetName),
            initialAspectLabel: playConfig.aspectModeLabel,
            onAspectChanged: (label) =>
                unawaited(_persistAspectMode(playConfig, label)),
            epgNow: programme,
            // Catch-up is deliberately memoised under its own key rather than
            // the live channel's: an archive URL can be a different container
            // than the live one, and conflating them would let a catch-up
            // AVPlayer failure permanently downgrade the live channel to SDR
            // (or vice versa).
            iosEngineKey: 'catchup:${channel.id}',
          ),
        ),
      );
      if (!_isLiveOpenCurrent(generation)) return;
      if (_preview.stream != null) await _preview.play();
      _restoreListFocusAfterPlayback();
    } catch (e) {
      if (!_isLiveOpenCurrent(generation)) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            tr('Could not play catch-up: {error}', {
              'error': playbackErrorMessage(e),
            }),
          ),
        ),
      );
    } finally {
      if (_isLiveOpenCurrent(generation)) setState(() => _resolving = false);
    }
  }

  /// Runs whatever the just-closed zap session asked for on its way out.
  ///
  /// Today that is exactly one thing: catch-up picked from the in-player
  /// quick list. The player ends its own live session (the controller calls
  /// `onExitRequested`) and the request is carried out *here*, after the
  /// route has popped and the preview return leg has run — see
  /// [LiveZapController.pendingCatchup] for why catch-up doesn't play in
  /// place on the live route.
  Future<void> _runPendingZapRequest(
    ({ZapEntry entry, Programme programme})? pending,
  ) async {
    if (pending == null || !mounted) return;
    await _playCatchup(
      pending.entry.channel,
      pending.programme,
      repo: _repoFor(pending.entry.config),
      config: pending.entry.config,
    );
  }

  Future<void> _openMedia(MediaItem item, {SourceConfig? owner}) async {
    if (_openingMedia) return;
    final config = owner ?? widget.config;
    if (!_mediaAllowed(item, config) &&
        (!await unlockParentalContent(context) || !mounted)) {
      return;
    }
    final messenger = _messenger;
    _openingMedia = true;
    try {
      final repo = _repoFor(config);
      DiagnosticsLog.instance.add(
        'library',
        'open ${item.kind.name} source=${repo.source.name} title=${item.title} id=${item.id}',
      );
      final detailed = await showMediaLoading(
        context,
        message: tr('Loading details…'),
        load: () async {
          if (config.id == widget.config.id) await _loadFavorites(item.kind);
          return repo.mediaDetails(item);
        },
      );
      if (!mounted || detailed == null) return;
      if (!_mediaAllowed(detailed, config) &&
          !await unlockParentalContent(context)) {
        return;
      }
      if (!mounted) return;
      if (config.id == widget.config.id) _replaceMediaItem(detailed);
      await _showMediaDetails(detailed, owner: config);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            tr('Could not open: {error}', {'error': playbackErrorMessage(e)}),
          ),
        ),
      );
    } finally {
      _openingMedia = false;
    }
  }

  void _replaceMediaItem(MediaItem replacement) {
    _media(replacement.kind).replaceItems({replacement.id: replacement});
  }

  /// Play a movie/episode fullscreen, auto-resuming from any saved position
  /// unless [fromStart]. The player persists the new position (periodically,
  /// on exit, and via the Android native player's close payload).
  Future<void> _playMedia(
    MediaItem item, {
    bool fromStart = false,
    SourceConfig? owner,
  }) async {
    final config = owner ?? widget.config;
    if (!_mediaAllowed(item, config) &&
        (!await unlockParentalContent(context) || !mounted)) {
      return;
    }
    if (_resolving) return;
    setState(() => _resolving = true);
    final navigator = Navigator.of(context);
    final messenger = _messenger;
    try {
      final repo = _repoFor(config);
      DiagnosticsLog.instance.add(
        'library',
        'resolve ${item.kind.name} source=${repo.source.name} title=${item.title} id=${item.id}',
      );
      List<MediaItem>? episodes;
      var playing = item;
      var playFromStart = fromStart;
      var useEpisodeResume = !fromStart;
      while (mounted) {
        final current = playing;
        var resume = playFromStart
            ? null
            : await repo.db.readPlaybackPosition(
                repo.source.id,
                current.kind,
                current.id,
              );
        if (!mounted) return;
        if (resume != null && resume.position > Duration.zero) {
          final access = await requireSupporterFeature(
            context,
            SupporterFeature.vodResume,
            freeActionLabel: tr('Watch from beginning'),
          );
          if (!mounted || access == SupporterGateResult.cancelled) return;
          if (access == SupporterGateResult.free) {
            resume = null;
            useEpisodeResume = false;
          }
        }
        final prepared = await showMediaLoading(
          context,
          message: tr('Loading stream…'),
          load: () async => (
            episodes: episodes ?? await loadPlaybackEpisodes(repo, current),
            stream: await repo.resolveMedia(current),
          ),
        );
        if (!mounted || prepared == null) return;
        episodes = prepared.episodes;
        if (config.id == widget.config.id) {
          _media(
            current.kind == ContentKind.episode
                ? ContentKind.series
                : current.kind,
          ).setLastPlayed(current.id);
        }
        final route = MaterialPageRoute<Object?>(
          builder: (_) => PlayerScreen(
            title: current.title,
            stream: prepared.stream,
            episodes: prepared.episodes,
            onPlaybackStarted: (started) => unawaited(
              _recentlyWatched.record(
                started.sourceId,
                started.kind,
                started.itemId,
              ),
            ),
            resolveEpisode: (playerContext, selected) async {
              // Native playback is above Flutter dialogs. Keep the initial
              // session choice, recheck entitlement silently, and never put a
              // hidden PIN/license modal beneath the player during Next.
              if (!_mediaAllowed(selected, config)) {
                throw EpisodeSelectionBlocked(
                  tr(
                    'This episode is locked. Return to the library to unlock protected content.',
                  ),
                );
              }
              final saved = useEpisodeResume
                  ? await repo.db.readPlaybackPosition(
                      repo.source.id,
                      selected.kind,
                      selected.id,
                    )
                  : null;
              if (!playerContext.mounted) return null;
              var position = saved?.position;
              if (position != null &&
                  position > Duration.zero &&
                  !await SupporterAccess.instance.allows(
                    SupporterFeature.vodResume,
                  )) {
                position = null;
              }
              if (!playerContext.mounted) return null;
              final stream = await repo.resolveMedia(selected);
              if (!playerContext.mounted) return null;
              if (config.id == widget.config.id) {
                _media(ContentKind.series).setLastPlayed(selected.id);
              }
              return PlayerEpisode(
                item: selected,
                stream: stream,
                playback: PlaybackContext(
                  db: repo.db,
                  sourceId: repo.source.id,
                  kind: selected.kind,
                  itemId: selected.id,
                  resumeFrom: position,
                ),
              );
            },
            sourceName: repo.source.name,
            bufferPreset: bufferPresetFromName(config.bufferPresetName),
            initialAspectLabel: config.aspectModeLabel,
            onAspectChanged: (label) =>
                unawaited(_persistAspectMode(config, label)),
            playback: PlaybackContext(
              db: repo.db,
              sourceId: repo.source.id,
              kind: current.kind,
              itemId: current.id,
              resumeFrom: resume?.position,
            ),
            iosEngineKey: config.id == widget.config.id
                ? current.id
                : '${config.id}:${current.id}',
          ),
        );
        final selected = await navigator.push(route);
        if (selected is! MediaItem || !mounted) break;
        await route.completed;
        if (!mounted) return;
        if (!_mediaAllowed(selected, config) &&
            (!await unlockParentalContent(context) || !mounted)) {
          break;
        }
        playing = selected;
        playFromStart = false;
      }
      // The rail reflects the position just saved by the player.
      unawaited(_media(ContentKind.movie).loadContinueWatching());
      unawaited(_media(ContentKind.series).loadContinueWatching());
      _restoreListFocusAfterPlayback();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            tr('Could not play: {error}', {'error': playbackErrorMessage(e)}),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _showMediaDetails(MediaItem item, {SourceConfig? owner}) async {
    final config = owner ?? widget.config;
    final repo = _repoFor(config);
    final foreign = config.id != widget.config.id;
    // Saved resume point (if any) drives the details' Resume / From-start pair.
    final resume =
        item.kind == ContentKind.movie || item.kind == ContentKind.episode
        ? await repo.db.readPlaybackPosition(repo.source.id, item.kind, item.id)
        : null;
    final favorite = await repo.db.isFavorite(
      repo.source.id,
      item.kind,
      item.id,
    );
    if (!mounted) return;
    final previousFocus = FocusManager.instance.primaryFocus;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.82),
      useSafeArea: false,
      traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
      animationStyle: AnimationStyle(
        duration: appMotion(context, const Duration(milliseconds: 180)),
        reverseDuration: appMotion(context, const Duration(milliseconds: 140)),
      ),
      builder: (context) => MediaDetailsSheet(
        repo: repo,
        item: item,
        favorite: favorite,
        onToggleFavorite: () async {
          if (!foreign) {
            await _toggleFavorite(item.kind, item.id);
          } else {
            final wasFavorite = await repo.db.isFavorite(
              repo.source.id,
              item.kind,
              item.id,
            );
            await repo.db.setFavorite(
              repo.source.id,
              item.kind,
              item.id,
              !wasFavorite,
            );
          }
        },
        onChanged: (replacement) {
          if (!foreign) _replaceMediaItem(replacement);
        },
        resume: resume,
        // Episodes picked in the series browser play through the same path as
        // movies, so "Continue watching" reloads on return (the details used to
        // push its own player, which skipped that reload — the series rail then
        // went stale until a manual refresh).
        onPlayEpisode: (episode) => _playMedia(
          episode.categoryId == null && item.kind == ContentKind.series
              ? episode.copyWith(categoryId: item.categoryId)
              : episode,
          owner: config,
        ),
        onPlay:
            item.kind == ContentKind.movie || item.kind == ContentKind.episode
            ? () {
                Navigator.of(context).pop();
                _playMedia(item, owner: config);
              }
            : null,
        onPlayFromStart: resume != null
            ? () {
                Navigator.of(context).pop();
                _playMedia(item, fromStart: true, owner: config);
              }
            : null,
      ),
    );
    _restoreFocusAfterModal(previousFocus);
  }

  // Jump the active list/grid back to the top after a tab/category change so the
  // new content isn't shown scrolled to the previous position. Post-frame so the
  // new list has attached before we move it.
  void _scrollToTop() {
    final controller = _showFavorites
        ? _favoritesScrollController
        : _tab == ContentKind.live
        ? _scrollController
        : _media(_tab).scrollController;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (controller.hasClients) controller.jumpTo(0);
    });
  }

  void _selectTab(ContentKind kind) {
    if (!_showHome && _tab == kind && !_showFavorites) return;
    _abandonLiveOpen();
    final previous = _tab;
    if (previous == ContentKind.live && kind != ContentKind.live) {
      unawaited(_preview.stop());
    }
    setState(() {
      _tab = kind;
      _showFavorites = false;
      _showHome = false;
      _hasOpenedSection = true;
      _exitArmedAt = null;
    });
    if (kind == ContentKind.live && _liveLoadStarted) {
      // A retained Live controller can return before its list reattaches.
      // Read once with the real viewport, rather than first with fallback
      // screen geometry and then again after layout.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncEpgRefreshActivity();
      });
    } else {
      _syncEpgRefreshActivity();
    }
    _resetTvIdleTimer();
    DiagnosticsLog.instance.add(
      'library',
      'tab source=${widget.repo.source.name} ${previous.name}->${kind.name}',
    );
    if (kind == ContentKind.live && !_liveLoadStarted) {
      unawaited(_loadLive());
    }
    if (!_searchActive && kind != ContentKind.live) {
      if (_media(kind).snapshot == null) _loadMediaTab(kind);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _showHome || _showFavorites || _tab != kind) return;
      if (_searchActive) {
        _focus.focusSearch();
        return;
      }
      // Let the first row's autofocus run when an in-flight load mounts it.
      if (kind == ContentKind.live ? _live.loading : _media(kind).loading) {
        return;
      }
      if (!_restoreBrowseFocus()) _focusTabs();
    });
  }

  void _selectFavorites() {
    if (!_showHome && _showFavorites) return;
    _abandonLiveOpen();
    unawaited(_preview.stop());
    setState(() {
      _showFavorites = true;
      _hasVisitedFavorites = true;
      _showHome = false;
      _hasOpenedSection = true;
      _exitArmedAt = null;
    });
    _syncEpgRefreshActivity();
    _resetTvIdleTimer();
    if (!_liveLoadStarted) unawaited(_loadFavorites(ContentKind.live));
    unawaited(_globalFavorites.load());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _showHome || !_showFavorites) return;
      if (!_restoreBrowseFocus()) _focusTabs();
    });
  }

  void _refreshFavorites() {
    setState(() => _favoritesRevision++);
    unawaited(_globalFavorites.load());
  }

  /// The two-column (TV/desktop) layout, which is the only one with a category
  /// sidebar and preview panel. The coordinator routes the D-pad off this.
  bool _isWide() => mounted && isWideLayout(MediaQuery.sizeOf(context));

  /// The live tab's geometry, read from the **window** `MediaQuery`.
  ///
  /// This is the authority for the two lists' `itemExtent`s *and* for the
  /// coordinator's `index * extent` scroll maths (via [_liveChannelRowExtent] /
  /// [_liveCategoryRowExtent]). `LiveTabView.build` constructs the same metrics
  /// again to size the row *contents*; both must pass identical arguments —
  /// same window size, same `compactWideLayout`, same text scale — or the
  /// selection model scrolls by a height the rows aren't drawn at. A
  /// debug-only assert in `LiveTabView.build` compares the two.
  LiveLayoutMetrics get _liveLayoutMetrics => LiveLayoutMetrics.forSize(
    mounted ? MediaQuery.sizeOf(context) : const Size(1280, 720),
    compactWideLayout: defaultTargetPlatform == TargetPlatform.android,
    textScale: mounted ? MediaQuery.textScalerOf(context).scale(1) : 1.0,
  );

  bool get _liveRowsShowEpg => liveRowsShowEpg(
    categoryId: _categoryId,
    hasEpg: _live.hasEpg || _live.now.isNotEmpty,
    hasCrossSourceEpg: _globalFavorites.hasEpg,
    expectsEpg: _live.expectsEpg,
  );

  bool get _usesIntegratedGuide =>
      !_showFavorites &&
      _guideMode &&
      _isWide() &&
      _categoryId != kAllSourcesFavoritesCategoryId;

  void _toggleLiveGuide() {
    setState(() => _guideMode = !_guideMode);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.focusChannels();
    });
  }

  double _liveChannelRowExtent() => _usesIntegratedGuide
      ? 52 * _liveLayoutMetrics.textScale
      : _liveLayoutMetrics.channelRowExtent(_liveRowsShowEpg);

  /// The row extent the live list was last built with, so a change in it can
  /// re-reveal the selection.
  double? _lastLiveRowExtent;

  /// Re-reveal the selected row when the row *height* changes underneath it.
  ///
  /// The live list scrolls by exact `index * itemExtent` arithmetic, so the
  /// offset is only correct for the extent it was computed against. Rows are
  /// 72px without an EPG line and 112 with one, and **`_liveRowsShowEpg` can
  /// flip after the rows are already on screen** — most visibly in the
  /// cross-source Favorites view, whose guide is fetched separately
  /// (`GlobalFavoritesController.hasEpg`) and lands after the list is built.
  ///
  /// The symptom is precise and was reported as such: the cursor is on the
  /// right channel, the list is scrolled to the wrong place, and one press of
  /// Up or Down snaps it back — because that press re-reveals against the
  /// extent the rows now actually have. The error grows with the row index,
  /// which is why it reads as "the highlighted channel isn't centred".
  ///
  /// Deliberately post-frame: the reveal has to run *after* the list has been
  /// rebuilt with the new `itemExtent`, or it computes against the old geometry
  /// again. The first observation only records the extent — there is nothing to
  /// correct before a list exists.
  void _resyncLiveRowExtent() {
    final extent = _liveChannelRowExtent();
    final previous = _lastLiveRowExtent;
    if (previous == extent) return;
    _lastLiveRowExtent = extent;
    if (previous == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.revealSelectedChannel();
    });
  }

  double _liveCategoryRowExtent() => _liveLayoutMetrics.categoryRowExtent;

  /// The last geometry line written, so an unchanged window logs once rather
  /// than once per build.
  String? _loggedLayout;

  /// Deliberately **not** called from `build`. `DiagnosticsLog` is a
  /// `ChangeNotifier` and the diagnostics screen listens to it, so writing a
  /// line mid-build can `markNeedsBuild` a widget this frame has already
  /// built — the classic "setState called during build" assertion, reachable
  /// by resizing the window while the diagnostics screen is open. Dependency
  /// changes are exactly when the geometry moves, and this hook runs outside
  /// the build phase.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _logLayoutGeometry();
    _syncTvIdleTimer();
  }

  /// Records the window geometry the layout decisions are made from.
  ///
  /// Everything about which browsing UI appears turns on **logical** width
  /// ([kWideLayoutMinWidth], 950): the category side-pane, the live preview
  /// panel, and therefore whether the shared-engine preview path exists at all.
  /// Logical width is physical pixels divided by the device pixel ratio, which
  /// is exactly the quantity a screenshot cannot show — a 3840 px TV reports
  /// 960 at dpr 4.0 and 873 at dpr 4.4, and only one of those gets the two-pane
  /// layout. An export that says the app rendered the phone layout, without
  /// saying what it measured to decide that, sends the reader looking for a
  /// missing category list that was never missing.
  void _logLayoutGeometry() {
    final size = MediaQuery.sizeOf(context);
    final line =
        'layout window=${size.width.toStringAsFixed(0)}x'
        '${size.height.toStringAsFixed(0)} '
        'dpr=${MediaQuery.devicePixelRatioOf(context).toStringAsFixed(2)} '
        'textScale=${MediaQuery.textScalerOf(context).scale(1).toStringAsFixed(2)} '
        'wide=${isWideLayout(size)} tv=$isTelevision';
    if (line == _loggedLayout) return;
    _loggedLayout = line;
    DiagnosticsLog.instance.addAndPrint('library', line);
  }

  /// The section's Home control is the top of the browsing Back ladder.
  void _focusTabs() {
    if (!_showHome) {
      _sectionHomeFocusNode.requestFocus();
    } else if (_showFavorites) {
      _favoritesTabFocusNode.requestFocus();
    } else {
      _tabFocusNodes[_tab]?.requestFocus();
    }
  }

  void _focusMediaCategories(ContentKind kind) {
    if (_isWide()) {
      final previous = _lastMediaCategoryFocus[kind];
      if (previous?.context != null && previous!.canRequestFocus) {
        previous.requestFocus();
        return;
      }
      final route = 'media.category.${_media(kind).categoryId ?? 'all'}';
      for (final node in _browseFocusNodes[kind]!.descendants) {
        if (focusRouteKey(node) == route && node.canRequestFocus) {
          node.requestFocus();
          return;
        }
      }
    }
    _focusTabs();
  }

  void _returnHome() {
    _abandonLiveOpen();
    unawaited(_preview.stop(clearSelection: true));
    setState(() {
      _showHome = true;
      _homeVisit++;
      _exitArmedAt = null;
    });
    _syncEpgRefreshActivity();
    _resetTvIdleTimer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _showHome) _focusTabs();
    });
  }

  void _rememberBrowseFocus() {
    final node = FocusManager.instance.primaryFocus;
    if (!mounted ||
        node == null ||
        node is FocusScopeNode ||
        _showHome ||
        _searchActive) {
      return;
    }
    if (_showFavorites) {
      if (node.ancestors.contains(_favoritesBrowseFocusNode)) {
        _lastFavoritesFocus = node;
      }
      return;
    }
    if (!node.ancestors.contains(_browseFocusNodes[_tab])) return;
    if (focusRouteKey(node).startsWith('media.category.')) {
      _lastMediaCategoryFocus[_tab] = node;
      _returnToMediaCategories.add(_tab);
      return;
    }
    _returnToMediaCategories.remove(_tab);
    // The sidebar is a route to the menu; Down returns to the selected channel.
    if (_tab == ContentKind.live && node != _focus.channelsFocusNode) return;
    _lastBrowseFocus[_tab] = node;
  }

  bool _restoreBrowseFocus() {
    if (_searchActive) return false;
    if (_showFavorites) {
      final node = _lastFavoritesFocus?.context != null
          ? _lastFavoritesFocus
          : _favoritesFirstFocusNode;
      if (node?.context != null && node!.canRequestFocus) {
        node.requestFocus();
        return true;
      }
      return false;
    }
    if (_tab == ContentKind.live && _visible.isNotEmpty) {
      _focus.focusChannels();
      return true;
    }
    final target = _lastBrowseFocus[_tab];
    // Detached nodes keep their context after a category reload, but cannot
    // receive focus until attached to the current browsing tree again.
    if (target?.context != null &&
        target!.canRequestFocus &&
        _browseFocusNodes[_tab]!.descendants.contains(target)) {
      target.requestFocus();
      return true;
    }
    if (_tab != ContentKind.live) {
      final first = _media(_tab).firstFocusNode;
      if (first.context != null &&
          first.canRequestFocus &&
          _browseFocusNodes[_tab]!.descendants.contains(first)) {
        first.requestFocus();
        return true;
      }
      // Error views have a retry button instead of the catalogue's first tile.
      for (final node in _browseFocusNodes[_tab]!.traversalDescendants) {
        if (node is! FocusScopeNode &&
            !focusRouteKey(node).startsWith('media.category.')) {
          node.requestFocus();
          return true;
        }
      }
    }
    return false;
  }

  Widget _buildSectionToolbar(BuildContext context) => Focus(
    key: _sectionToolbarKey,
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: (_, event) {
      if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
          _focus.searchCellFocusNode.hasPrimaryFocus) {
        if (event is KeyDownEvent) _focusTabs();
        return KeyEventResult.handled;
      }
      if (event.logicalKey != LogicalKeyboardKey.arrowDown || _searchActive) {
        return KeyEventResult.ignored;
      }
      if (event is KeyUpEvent) return KeyEventResult.handled;
      if (!_showFavorites && _tab != ContentKind.live && _isWide()) {
        if (_returnToMediaCategories.contains(_tab) || !_restoreBrowseFocus()) {
          _focusMediaCategories(_tab);
        }
        return KeyEventResult.handled;
      }
      return _restoreBrowseFocus()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    },
    child: Row(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 12),
          child: IconButton(
            focusNode: _sectionHomeFocusNode,
            tooltip: tr('Home'),
            icon: const Icon(Icons.home_outlined),
            onPressed: _returnHome,
          ),
        ),
        Expanded(child: _buildToolbar(context)),
      ],
    ),
  );

  bool get _toolbarInLivePane =>
      _isWide() &&
      _tab == ContentKind.live &&
      !_showFavorites &&
      !_searchActive &&
      !_parental.unavailable;

  /// Apply a live category filter: OK on a sidebar row, a tap, or the phone
  /// dropdown. The channel cursor restarts at the top of the new list. The
  /// focus coordinator moves OK activation into a non-empty channel list;
  /// pointer/dropdown callers retain their natural focus behavior.
  void _selectCategory(String? categoryId) {
    setState(() => _categoryId = categoryId);
    _syncEpgRefreshActivity();
    _focus.syncCategorySelection(categoryId);
    _focus.resetChannelSelection();
    _focus.clampSelection();
    _scrollToTop();
  }

  /// Double-Back exit confirmation: the first Back at the top of the ladder
  /// arms this and shows "Press Back again to exit"; a second Back inside the
  /// window actually exits.
  DateTime? _exitArmedAt;
  static const _exitConfirmWindow = Duration(seconds: 2);

  /// Peels exactly one rung per Back press. The live ladder, in order:
  ///
  ///   channel list (cursor not on the first row) → **first channel**
  ///     → **categories** (wide) → **first category** ("All channels")
  ///     → **search box** → **Home control** → **home** → exit (double-Back).
  ///
  /// Because the live lists are a selection model, each rung is a plain check on
  /// the coordinator's region + selected index — no focus-label archaeology.
  /// Media: deep grid → top of the grid → Home control → home. The app exits
  /// from home only, on a second Back within [_exitConfirmWindow].
  void _handleRootBack(bool didPop, Object? result) {
    if (didPop) return;
    _resetTvIdleTimer();
    final label = focusRouteKey(FocusManager.instance.primaryFocus);
    // Flutter invokes every registered PopScope when a pop is blocked, so defer
    // entirely to TvTextField's own PopScope while its inner field is actually
    // being edited — it already exits edit mode on Back.
    if (label == 'TvTextField.field') return;

    if (_showHome) {
      _handleHomeBack();
      return;
    }
    if (_sectionHomeFocusNode.hasFocus) {
      _returnHome();
      return;
    }

    if (_searchActive) {
      if (_focus.searchCellFocusNode.hasFocus ||
          _sectionHomeFocusNode.hasFocus) {
        _searchController.clear();
        _setQuery('');
        _focusTabs();
      } else {
        _focus.focusSearch();
      }
      return;
    }

    if (_showFavorites) {
      if (_favoritesScrollController.hasClients &&
          _favoritesScrollController.offset >
              _favoritesScrollController.position.viewportDimension) {
        _favoritesScrollController.jumpTo(0);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _favoritesFirstFocusNode.requestFocus();
        });
      } else {
        _focusTabs();
      }
      return;
    }

    final wideLive = _tab == ContentKind.live && _isWide();

    if (!_showFavorites && _tab == ContentKind.live) {
      switch (_focus.region) {
        case LiveFocusRegion.channels:
          if (_usesIntegratedGuide) {
            _focus.focusCategories();
            return;
          }
          // Rung 0: with the intra-row cursor on the favorite star, Back
          // mirrors Left — it peels the cursor back onto the row body.
          if (_focus.channelColumn == ChannelRowColumn.favorite) {
            _focus.resetChannelColumn();
            return;
          }
          // Rung 1: climbing out of the list starts from its top.
          if (!_focus.onFirstChannel) {
            _focus.selectChannel(0);
            return;
          }
          // Rung 2: out of the list into the sidebar (wide) — phones have no
          // sidebar, so they peel straight to the search box.
          if (wideLive) {
            _focus.focusCategories();
          } else {
            _focus.focusSearch();
          }
          return;
        case LiveFocusRegion.previewControls:
          // The preview controls sit between the search box and the list.
          if (wideLive) {
            _focus.focusCategories();
          } else {
            _focus.focusSearch();
          }
          return;
        case LiveFocusRegion.categories:
          // Rung 3: move the *highlight* to "All channels" — this deliberately
          // does not change the active filter (OK does that).
          if (!_focus.onFirstCategory) {
            _focus.selectCategory(0);
            return;
          }
          // Rung 4: out of the sidebar into the search box.
          _focus.focusSearch();
          return;
        case LiveFocusRegion.search:
          // Rung 5: search → the section tabs.
          _focusTabs();
          return;
        case LiveFocusRegion.none:
          break; // fall through to the shared handling below
      }
    }

    // Movies/series grid — same top-of-list rung as the channel list, then
    // the tabs.
    if (label.startsWith('media.category.')) {
      _focusTabs();
      return;
    }
    if (label.startsWith('media.')) {
      final controller = _media(_tab);
      final scroll = controller.scrollController;
      if (scroll.hasClients &&
          scroll.position.pixels > scroll.position.viewportDimension) {
        scroll.jumpTo(0);
        // The first tile may not be built until the frame after the jump —
        // focus post-frame with one retry (same pattern as the coordinator's
        // focusFirstChannel).
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (controller.firstFocusNode.context != null) {
            controller.firstFocusNode.requestFocus();
            return;
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) controller.firstFocusNode.requestFocus();
          });
        });
      } else {
        _focusTabs();
      }
      return;
    }
    // The media tabs' own search cell peels to the tabs (live's search box is
    // handled by the region ladder above).
    if (label == 'TvTextField.cell' || _focus.searchCellFocusNode.hasFocus) {
      _focusTabs();
      return;
    }
    // The search field's clear (Ă—) button is its own focusable stop beside the
    // cell (see TvTextField); Back peels it to the search cell (live) / the
    // tabs (media) instead of falling through to the exit prompt.
    if (label == 'TvTextField.clear') {
      if (_tab == ContentKind.live) {
        _focus.focusSearch();
      } else {
        _focusTabs();
      }
      return;
    }
    // Other section actions and transient route focus recover to Home.
    _focusTabs();
  }

  void _handleHomeBack() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      return;
    }
    final now = DateTime.now();
    final armed =
        _exitArmedAt != null &&
        now.difference(_exitArmedAt!) <= _exitConfirmWindow;
    if (!armed) {
      _exitArmedAt = now;
      _messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(tr('Press Back again to exit')),
            duration: _exitConfirmWindow,
          ),
        );
      return;
    }
    // Exiting must not leave the preview engine playing behind the launcher
    // (Android's back-exit only moves the task back — the engine would keep
    // its audio running).
    if (_preview.channelId != null || _preview.nativeActive) {
      unawaited(_preview.stop(clearSelection: true));
    }
    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    // **A messenger scoped to this screen**, not `MaterialApp`'s.
    //
    // The app-level messenger lives *above* the Navigator, so anything it is
    // showing survives a route push and keeps painting over whatever comes
    // next — the Continue-watching "Undo" snackbar was observed sitting on top
    // of fullscreen live TV on an unrelated channel, offering to undo
    // something the user could no longer see. Owning a messenger here puts
    // these snackbars *below* the route that pushes `PlayerScreen`, so opening
    // the player covers them instead of carrying them along, and returning
    // still finds one that hasn't timed out.
    final screen = ScaffoldMessenger(
      key: _messengerKey,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: _handleRootBack,
        child: Scaffold(
          appBar: _showHome
              ? AppBar(
                  toolbarHeight: isTelevision ? 48 : null,
                  title: const AppLogo(height: 30),
                  leading:
                      (widget.onChangeProfile != null ||
                          widget.onProfileSettings != null)
                      ? ProfileAvatarButton(
                          profileName: widget.profileName,
                          colorIndex: widget.profileColorIndex,
                          onChangeProfile: widget.onChangeProfile,
                          onProfileSettings: widget.onProfileSettings,
                        )
                      : null,
                  // Group the actions so D-pad traversal treats them as one cluster (reached
                  // by going up to the bar), rather than the toolbar's "right" jumping
                  // straight to the rightmost icon.
                  actions: [
                    FocusTraversalGroup(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.onProfileSettings != null)
                            _isWide()
                                ? TextButton.icon(
                                    onPressed: widget.onProfileSettings,
                                    icon: const Icon(Icons.cloud_sync_outlined),
                                    label: Text(tr('TVBro account')),
                                  )
                                : IconButton(
                                    onPressed: widget.onProfileSettings,
                                    tooltip: tr('TVBro account'),
                                    icon: const Icon(Icons.cloud_sync_outlined),
                                  ),
                          if (_isWide())
                            _headerAction(
                              label: tr('Settings'),
                              icon: Icons.settings_outlined,
                              onPressed: _openAppSettings,
                            ),
                          if (!_isWide() ||
                              _parental.rules.enabled ||
                              (!_showFavorites &&
                                  _tab == ContentKind.live &&
                                  _visible.isNotEmpty))
                            PopupMenuButton<String>(
                              tooltip: _isWide()
                                  ? tr('Channel tools')
                                  : tr('Menu'),
                              icon: Icon(
                                _isWide() ? Icons.tune : Icons.more_vert,
                              ),
                              position: _isWide()
                                  ? PopupMenuPosition.over
                                  : PopupMenuPosition.under,
                              onSelected: _selectHeaderAction,
                              itemBuilder: (_) => [
                                if (!_isWide())
                                  _headerMenuItem(
                                    'settings',
                                    tr('Settings'),
                                    Icons.settings_outlined,
                                  ),
                                if (!_showFavorites &&
                                    _tab == ContentKind.live &&
                                    _visible.isNotEmpty)
                                  PopupMenuItem(
                                    value: 'record',
                                    child: Text(tr('Schedule recording')),
                                  ),
                                if (_parental.rules.enabled)
                                  PopupMenuItem(
                                    value: 'unlock',
                                    child: Text(
                                      _parental.unlocked
                                          ? tr('Lock protected content')
                                          : tr('Unlock protected content'),
                                    ),
                                  ),
                                if (!_isWide()) ...[
                                  const PopupMenuDivider(),
                                  if (widget.onOpenRecordings != null)
                                    _headerMenuItem(
                                      'recordings',
                                      tr('Recordings'),
                                      Icons.video_library_outlined,
                                    ),
                                  if (!_showFavorites &&
                                      _tab == ContentKind.live &&
                                      _previousPlayedLiveChannelId != null)
                                    _headerMenuItem(
                                      'last',
                                      tr('Last channel'),
                                      Icons.swap_horiz_rounded,
                                    ),
                                  if (widget.onManageSources != null)
                                    _headerMenuItem(
                                      'sources',
                                      tr('Sources'),
                                      Icons.dns_outlined,
                                    ),
                                  _headerMenuItem(
                                    'help',
                                    tr('Help & about'),
                                    Icons.help_outline,
                                  ),
                                  _headerMenuItem(
                                    'refresh',
                                    tr('Refresh'),
                                    Icons.refresh,
                                    enabled: _headerCanRefresh,
                                  ),
                                ],
                              ],
                            ),
                          if (_isWide()) ...[
                            if (widget.onOpenRecordings != null)
                              _headerAction(
                                label: tr('Recordings'),
                                icon: Icons.video_library_outlined,
                                onPressed: () =>
                                    _selectHeaderAction('recordings'),
                              ),
                            if (!_showFavorites &&
                                _tab == ContentKind.live &&
                                _previousPlayedLiveChannelId != null)
                              _headerAction(
                                label: tr('Last channel'),
                                icon: Icons.swap_horiz_rounded,
                                onPressed: () => _selectHeaderAction('last'),
                              ),
                            if (widget.onManageSources != null)
                              _headerAction(
                                label: tr('Sources'),
                                icon: Icons.dns_outlined,
                                onPressed: () => _selectHeaderAction('sources'),
                              ),
                            _headerAction(
                              label: tr('Help'),
                              tooltip: tr('Help & about'),
                              icon: Icons.help_outline,
                              onPressed: () => _selectHeaderAction('help'),
                            ),
                            ListenableBuilder(
                              listenable: _dataListenable,
                              builder: (context, _) => _headerAction(
                                label: tr('Refresh'),
                                tooltip: tr('Refresh from source'),
                                icon: Icons.refresh,
                                onPressed: _headerCanRefresh
                                    ? () => _selectHeaderAction('refresh')
                                    : null,
                              ),
                            ),
                          ],
                          const SizedBox(width: 4),
                        ],
                      ),
                    ),
                  ],
                  bottom: _resolving
                      ? const PreferredSize(
                          preferredSize: Size.fromHeight(2),
                          child: LinearProgressIndicator(minHeight: 2),
                        )
                      : null,
                )
              : null,
          // Section controls belong to the body; global actions stay on home.
          //
          // Edge-to-edge (targetSdk 35+): SafeArea shrinks the body's constraints,
          // so the live list's Expanded viewport ends above/beside the system bar.
          // That is what keeps LiveFocusCoordinator._reveal correct — it scrolls a
          // selected row to `viewportDimension`, so the viewport itself must
          // exclude the inset or the selected row lands underneath the bar.
          // Insets are zero on Android TV, so this is a no-op there.
          body: SafeArea(
            top: !_showHome,
            child: FocusTraversalGroup(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (_hasOpenedSection)
                    Offstage(
                      offstage: _showHome,
                      child: ExcludeFocus(
                        excluding: _showHome,
                        child: TickerMode(
                          enabled: !_showHome,
                          child: Column(
                            children: [
                              ListenableBuilder(
                                listenable: _dataListenable,
                                builder: (context, _) => _toolbarInLivePane
                                    ? const SizedBox.shrink()
                                    : _buildSectionToolbar(context),
                              ),
                              Expanded(
                                child: ListenableBuilder(
                                  listenable: _bodyListenable,
                                  builder: (context, _) => _buildBody(context),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (_showHome)
                    LibraryHomeView(
                      onSelected: _selectTab,
                      focusNodes: _tabFocusNodes,
                      autofocusKind: _tab,
                      onFavoritesSelected: _selectFavorites,
                      favoritesFocusNode: _favoritesTabFocusNode,
                      autofocusFavorites: _showFavorites,
                      recentlyWatched: RecentlyWatchedView(
                        key: ValueKey((widget.repo, _homeVisit)),
                        repo: widget.repo,
                        store: _recentlyWatched,
                        channelAllowed: (channel) =>
                            _channelAllowed(channel, widget.config) &&
                            !widget.config.channelOrganization.hidden.contains(
                              channel.id,
                            ) &&
                            !_hiddenCategories(
                              ContentKind.live,
                            ).contains(channel.categoryId),
                        mediaAllowed: (item) =>
                            _mediaAllowed(item) &&
                            !_hiddenCategories(
                              item.kind == ContentKind.episode
                                  ? ContentKind.series
                                  : item.kind,
                            ).contains(item.categoryId),
                        onPlayChannel: (channel) {
                          if (_resolving) return;
                          _selectTab(ContentKind.live);
                          unawaited(_openFullscreenDirect(channel, widget.repo));
                        },
                        onPlayMedia: (item) async {
                          final previousFocus =
                              FocusManager.instance.primaryFocus;
                          await _playMedia(item);
                          if (mounted && _showHome) {
                            _recentlyWatched.refresh();
                            _restoreFocusAfterModal(previousFocus);
                          }
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final screenWithTvBack = PlaybackBackend.isCustom
        ? CallbackShortcuts(
            bindings: {
              // Tizen reports the Samsung remote's Back button as goBack.
              // Reuse PopScope's existing Back ladder without changing Linux
              // desktop, Android, or Windows key handling.
              const SingleActivator(LogicalKeyboardKey.goBack): () =>
                  _handleRootBack(false, null),
            },
            child: screen,
          )
        : screen;
    return isTelevision
        ? Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _resetTvIdleTimer(),
            onPointerUp: (_) => _resetTvIdleTimer(),
            onPointerMove: (_) => _resetTvIdleTimer(),
            onPointerHover: (_) => _resetTvIdleTimer(),
            onPointerSignal: (_) => _resetTvIdleTimer(),
            child: ColoredBox(
              color: AppColors.ink,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                child: screenWithTvBack,
              ),
            ),
          )
        : screenWithTvBack;
  }

  bool get _headerCanRefresh => _showFavorites
      ? !_globalFavorites.loading
      : (!_liveLoadStarted || !_live.loading) &&
            (_tab == ContentKind.live || !_media(_tab).loading);

  PopupMenuItem<String> _headerMenuItem(
    String value,
    String label,
    IconData icon, {
    bool enabled = true,
  }) => PopupMenuItem(
    value: value,
    enabled: enabled,
    child: Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Flexible(child: Text(label)),
      ],
    ),
  );

  Future<void> _selectHeaderAction(String action) async {
    switch (action) {
      case 'settings':
        await _openAppSettings();
      case 'unlock':
        await _toggleProtectedContent();
      case 'record':
        final selection = _usesIntegratedGuide ? _guideSelection.value : null;
        final channel = selection?.channel ?? _resolvePreviewChannel(_visible);
        if (channel != null) {
          await _scheduleRecording(channel, programme: selection?.programme);
        }
      case 'recordings':
        await _preview.stop();
        if (!mounted) return;
        await widget.onOpenRecordings?.call();
      case 'last':
        await _zapToPreviousChannel();
      case 'sources':
        unawaited(_preview.stop());
        widget.onManageSources?.call();
      case 'help':
        await _preview.stop();
        if (!mounted) return;
        await Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const LegalScreen()));
      case 'refresh':
        if (!_headerCanRefresh) return;
        if (_showFavorites) {
          _refreshFavorites();
        } else if (widget.onRefreshSource case final refresh?) {
          await _preview.stop();
          if (!mounted) return;
          await refresh();
        } else if (_tab == ContentKind.live) {
          await _loadLive(forceRefresh: true);
        } else {
          _loadMediaTab(_tab, forceRefresh: true);
        }
    }
  }

  /// Keeps the utility row visually quiet at rest on TV while revealing the
  /// full action name as soon as the remote focuses it. The label remains in
  /// semantics and the tooltip for screen readers and pointer users.
  Widget _headerAction({
    required String label,
    String? tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    if (!_isWide()) {
      return AppBarAction(
        label: label,
        tooltip: tooltip,
        icon: icon,
        onPressed: onPressed,
      );
    }
    return _FocusedLabelIconButton(
      label: label,
      tooltip: tooltip,
      icon: icon,
      onPressed: onPressed,
    );
  }

  Widget _buildToolbar(BuildContext context) {
    return ChannelToolbar(
      singleRow: _isWide(),
      searchController: _searchController,
      query: _query,
      hintText: _showFavorites
          ? tr('Search favorites across all sources')
          : switch (_tab) {
              ContentKind.live => tr(
                'Search channels and programmes in this source',
              ),
              ContentKind.movie => tr('Search movies in this source'),
              _ => tr('Search series in this source'),
            },
      onQueryChanged: _setQuery,
      onClearQuery: () {
        _searchController.clear();
        _setQuery('');
      },
      searchCellFocusNode: _focus.searchCellFocusNode,
      onSearchCellKeyEvent: !_searchActive &&
              !_showFavorites &&
              _tab == ContentKind.live
          ? _focus.handleSearchCellKey
          : null,
      categoryControl:
          _searchActive || _showFavorites || _isWide()
          ? null
          : (_tab == ContentKind.live
                ? ChannelCategoryDropdown(
                    categories: _liveCategoriesForUi,
                    value: _categoryId,
                    onChanged: _selectCategory,
                  )
                : MediaCategoryDropdown(
                    categories: _mediaCategoriesForUi(_tab),
                    value: _media(_tab).categoryId,
                    onChanged: (v) {
                      final kind = _tab;
                      _loadMediaTab(kind, category: v, switchCategory: true);
                      _scrollToTop();
                    },
                  )),
      actionControl: _searchActive || _showFavorites
          ? null
          : _tab == ContentKind.live
          ? ChannelToolbarIconButton(
              tooltip: _usesIntegratedGuide
                  ? tr('Channel list')
                  : tr('TV guide'),
              busy: false,
              icon: _usesIntegratedGuide
                  ? Icons.view_list_rounded
                  : Icons.calendar_view_day_rounded,
              onPressed:
                  _isWide() && _categoryId != kAllSourcesFavoritesCategoryId
                  ? _toggleLiveGuide
                  : _openEpgGrid,
            )
          : !widget.repo.canEnrichMetadata
          ? null
          : ChannelToolbarIconButton(
              tooltip: _media(_tab).enriching
                  ? tr('Cancel metadata refresh')
                  : tr('Refresh displayed metadata'),
              busy: _media(_tab).enriching,
              icon: _media(_tab).enriching
                  ? Icons.stop_rounded
                  : Icons.auto_awesome_outlined,
              onPressed: _media(_tab).loading || _media(_tab).searching
                  ? null
                  : _media(_tab).enriching
                  ? _media(_tab).cancelEnrich
                  : () => _media(_tab).enrichVisible(_visibleMedia(_tab)),
            ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_parental.unavailable) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            tr(
              'Parental controls could not be loaded. Content remains locked. Restart TVBro after device storage is available.',
            ),
          ),
        ),
      );
    }
    if (_searchActive && !_showFavorites) {
      return GlobalSearchView(
        key: ObjectKey(widget.repo),
        repo: widget.repo,
        kind: _tab,
        query: _query.trim(),
        channels: _tab == ContentKind.live ? _visible : const [],
        channelsLoading: _live.loading,
        channelsError: _live.error,
        hiddenMovieCategories: _hiddenCategories(ContentKind.movie),
        hiddenSeriesCategories: _hiddenCategories(ContentKind.series),
        isMediaAllowed: _mediaAllowed,
        onPlayChannel: _play,
        onOpenMedia: _openMedia,
        programmeChannelIds: _tab == ContentKind.live
            ? _programmeChannelIds
            : null,
        onOpenProgramme: (result) => unawaited(_openProgramme(result)),
        channelNames: widget.config.channelOrganization.names,
      );
    }
    // Keep inactive media widgets unchanged so preview/EPG ticks only filter
    // the active catalogue, while their focus nodes and shelf scroll survive.
    if (!_showFavorites && _tab != ContentKind.live) {
      _mediaTabBodies[_tab] = _buildMediaBody(_tab);
    }
    return Stack(
      key: ObjectKey(widget.repo),
      fit: StackFit.expand,
      children: [
        for (final kind in _tabFocusNodes.keys)
          if ((kind == ContentKind.live && kind == _tab) ||
              _mediaTabBodies.containsKey(kind))
            Offstage(
              key: ValueKey(kind),
              offstage: _showFavorites || kind != _tab,
              child: ExcludeFocus(
                excluding: _showFavorites || kind != _tab,
                child: TickerMode(
                  enabled: !_showFavorites && kind == _tab,
                  child: Focus(
                    focusNode: _browseFocusNodes[kind],
                    canRequestFocus: false,
                    skipTraversal: true,
                    child: kind == ContentKind.live
                        ? _withDigitEntryChip(_buildLiveBody(_visible))
                        : _mediaTabBodies[kind]!,
                  ),
                ),
              ),
            ),
        if (_hasVisitedFavorites)
          Offstage(
            offstage: !_showFavorites,
            child: ExcludeFocus(
              excluding: !_showFavorites,
              child: Focus(
                focusNode: _favoritesBrowseFocusNode,
                canRequestFocus: false,
                skipTraversal: true,
                child: TickerMode(
                  enabled: _showFavorites,
                  child: FavoritesTabView(
                    key: ValueKey((widget.repo, _favoritesRevision)),
                    active: _showFavorites,
                    query: _query.trim(),
                    db: widget.repo.db,
                    store: widget.store,
                    channels: _permittedGlobalFavorites,
                    channelsLoading: _globalFavorites.loading,
                    isMediaAllowed: (item, config) =>
                        _mediaAllowed(item, config),
                    onPlayChannel: (entry) => _play(entry.channel),
                    onOpenMedia: (item, config) =>
                        _openMedia(item, owner: config),
                    scrollController: _favoritesScrollController,
                    firstFocusNode: _favoritesFirstFocusNode,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildMediaBody(ContentKind kind) {
    final controller = _media(kind);
    final media = MediaTabView(
      kind: kind,
      visible: _visibleMedia(kind),
      snapshot: controller.snapshot,
      loading: controller.loading,
      loadingMore: controller.loadingMore,
      error: controller.error,
      showingSearch: _query.trim().length >= 2,
      categoryFilterActive: controller.categoryId != null,
      onFocusTabs: () => _focusMediaCategories(kind),
      onFocusToolbar: _focusTabs,
      lastPlayedId: controller.lastPlayedId,
      scrollController: controller.scrollController,
      firstFocusNode: controller.firstFocusNode,
      isFavorite: (id) => _isFavorite(kind, id),
      onOpenMedia: _openMedia,
      onLoadMore: controller.loadMore,
      onRetry: () => _loadMediaTab(kind, forceRefresh: true),
      continueWatching: controller.continueWatching
          .where((entry) => _mediaAllowed(entry.item))
          .toList(),
      onResume: _playMedia,
    );
    if (!_isWide()) return media;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Row(
        children: [
          MediaCategoryBar(
            key: ValueKey('media.${kind.name}.categoryPane'),
            categories: _mediaCategoriesForUi(kind),
            value: controller.categoryId,
            onChanged: (value) {
              _loadMediaTab(kind, category: value, switchCategory: true);
              _scrollToTop();
            },
            onFocusContent: _restoreBrowseFocus,
            onFocusTabs: _focusTabs,
          ),
          const SizedBox(width: 12),
          Expanded(child: media),
        ],
      ),
    );
  }

  /// Overlays the digit-entry "Ch 123" chip while the user is typing a
  /// channel number on the remote (see [LiveFocusCoordinator.digitBuffer]).
  ///
  /// [body] is passed through as the builder's `child`, so typing digits
  /// repaints the chip only — never the channel list underneath it.
  Widget _withDigitEntryChip(Widget body) {
    return ListenableBuilder(
      listenable: _focus.digitEntry,
      child: body,
      builder: (context, child) {
        if (_focus.digitBuffer.isEmpty) return child!;
        return Stack(
          children: [
            child!,
            Positioned(
              top: 8,
              right: 16,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.panel.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(AppRadius.tile),
                  border: Border.all(color: AppColors.accent, width: 2),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  child: Text(
                    tr('Ch {number}', {'number': _focus.digitBuffer}),
                    style: const TextStyle(
                      color: AppColors.textHi,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildLiveBody(List<Channel> visible) {
    _queueLiveEpgWindowRefresh();
    final crossSourceView = _categoryId == kAllSourcesFavoritesCategoryId;
    // Row height can change under a selection that never moved — see
    // [_resyncLiveRowExtent]. Checked here because this is the one place that
    // knows the extent the list is about to be built with.
    _resyncLiveRowExtent();
    return LiveTabView(
      header: _toolbarInLivePane ? _buildSectionToolbar(context) : null,
      loading: _live.loading,
      error: _live.error,
      onRetry: () => _loadLive(forceRefresh: true),
      visible: visible,
      searchActive: _query.trim().length >= 2,
      // Only the cross-source view labels its rows; elsewhere every row belongs
      // to the active source and the chip would say the same thing on all of
      // them.
      sourceLabelFor: _categoryId == kAllSourcesFavoritesCategoryId
          ? (channel) => _crossSourceFavoriteFor(channel)?.sourceLabel
          : null,
      // Resolved inside the preview pane's own rebuild: on a TV remote the
      // panel follows the channel cursor, and the cursor now moves without
      // rebuilding this method.
      resolvePreviewChannel: () => _resolvePreviewChannel(visible),
      // These maps are the *active* source's, keyed by channel id — which a
      // foreign row can collide with, so the cross-source view must never be
      // handed them. Its own guide arrives through `epgFor` below, keyed by
      // (source, channel), where there is no collision to have.
      //
      // Gated on the *same* predicate as the row extent, not a parallel test —
      // `LiveTabView` asserts that its `itemExtent` matches the layout it
      // computes from `showsEpg`, so these must be incapable of drifting apart
      // rather than merely agreeing today.
      now: crossSourceView || !_liveRowsShowEpg ? const {} : _live.now,
      next: crossSourceView || !_liveRowsShowEpg ? const {} : _live.next,
      showsEpg: _liveRowsShowEpg,
      epgFor: crossSourceView ? _crossSourceEpgFor : null,
      deliberate: _deliberatePreview,
      resolving: _resolving,
      scrollController: _scrollController,
      categoryScrollController: _categoryScrollController,
      focus: _focus,
      channelRowExtent: _liveChannelRowExtent(),
      categoryRowExtent: _liveCategoryRowExtent(),
      lastPlayedChannelId: _lastPlayedLiveChannelId,
      previewChannelId: _preview.channelId,
      // Source-aware, for the cross-source view: two providers can both carry
      // a channel with this id, and only one of them is previewing.
      isPreviewingRow: _isPreviewing,
      // In the cross-source view a row's favorite state belongs to *its* source,
      // not the active one. Reading it from `FavoritesController` (keyed to the
      // active source) drew every foreign row with an empty star, and toggling
      // wrote a phantom favorite under the wrong source id — which the delta
      // push would then have sent to the cloud.
      isFavorite: crossSourceView
          ? (id) => true
          : (id) => _isFavorite(ContentKind.live, id),
      onToggleFavorite: crossSourceView
          ? (id) => unawaited(_unfavoriteCrossSourceRow(id))
          : (id) => _toggleFavorite(ContentKind.live, id),
      onPlayChannel: _play,
      onPreviewChannel: (channel) => unawaited(_showPreviewSheet(channel)),
      onCatchup: _showCatchupSheet,
      categories: _liveCategoriesForUi,
      selectedCategoryId: _categoryId,
      onCategorySelected: _selectCategory,
      previewVideoBuilder: () => PreviewVideo(preview: _preview),
      previewLoading: _preview.loading,
      previewRetainVideo: _preview.nativeActive,
      previewError: _preview.error,
      guideSelection: _usesIntegratedGuide ? _guideSelection : null,
      guideBuilder: !_usesIntegratedGuide
          ? null
          : () => ListenableBuilder(
              listenable: _focus.channelSelection,
              builder: (context, _) => EpgGridScreen(
                repo: widget.repo,
                channels: visible,
                isPlayingChannel: (channel) =>
                    _preview.stream != null &&
                    !_preview.loading &&
                    _preview.error == null &&
                    _isPreviewing(channel),
                embedded: true,
                focusNode: _focus.channelsFocusNode,
                scrollController: _scrollController,
                rowExtent: _liveChannelRowExtent(),
                selectedChannelIndex: _focus.selectedChannelIndex,
                onSelectionChanged: (selection) {
                  _guideSelection.value = selection;
                  final index = selection.channelIndex;
                  if (index >= 0 &&
                      index < visible.length &&
                      identical(visible[index], selection.channel) &&
                      index != _focus.selectedChannelIndex) {
                    _focus.selectChannel(index, reveal: false);
                  }
                },
                onExitLeft: _focus.focusCategories,
                onExitUp: _focus.escapeUpFromChannels,
                onUnhandledKey: _focus.handleChannelsKey,
                onPlayChannel: _play,
                onPlayArchive: (channel, programme) =>
                    unawaited(_playCatchup(channel, programme)),
                onScheduleRecording: (channel, programme) => unawaited(
                  _scheduleRecording(channel, programme: programme),
                ),
              ),
            ),
    );
  }

  /// The channel the live preview panel should show: on a TV remote it follows
  /// D-pad focus (last focused), on desktop the auto-preview selection; falls
  /// back to the last-played channel and finally the first visible one.
  Channel? _resolvePreviewChannel(List<Channel> visible) {
    if (visible.isEmpty) return null;
    final crossSourceView = _categoryId == kAllSourcesFavoritesCategoryId;
    // In the cross-source view the rows are not the active source's catalog, so
    // `_channelsById` cannot find them — it would miss every foreign row and
    // fall through to `visible.first`, leaving the panel pointed at whatever
    // happens to be at the top. The favorites list is small enough to scan, and
    // [preferSourceId] breaks the tie when two providers share an id.
    Channel? byId(String? id, {String? preferSourceId}) {
      if (id == null) return null;
      if (!crossSourceView) return _channelsById[id];
      Channel? sameIdOtherSource;
      for (final item in _permittedGlobalFavorites) {
        if (item.channel.id != id) continue;
        if (preferSourceId == null || item.sourceId == preferSourceId) {
          return item.channel;
        }
        sameIdOtherSource ??= item.channel;
      }
      return sameIdOtherSource;
    }

    final previewSourceId = _preview.previewSourceId;
    if (_deliberatePreview) {
      // When a preview is actively running (or loading), lock the panel to
      // that channel.  D-pad focus moves away without disrupting it.
      final previewActive = _preview.stream != null || _preview.loading;
      return byId(
            previewActive ? _preview.channelId : null,
            preferSourceId: previewSourceId,
          ) ??
          byId(_focus.selectedChannelId) ??
          byId(_preview.channelId, preferSourceId: previewSourceId) ??
          byId(_lastPlayedLiveChannelId) ??
          visible.first;
    }
    return byId(_preview.channelId, preferSourceId: previewSourceId) ??
        byId(_lastPlayedLiveChannelId) ??
        visible.first;
  }
}

/// TV utility action: icon at rest, with its visible name revealed while the
/// remote is on it. This keeps the brand and content navigation prominent
/// without making AppBar actions anonymous to a focused viewer.
class _FocusedLabelIconButton extends StatefulWidget {
  final String label;
  final String? tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  const _FocusedLabelIconButton({
    required this.label,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  @override
  State<_FocusedLabelIconButton> createState() =>
      _FocusedLabelIconButtonState();
}

class _FocusedLabelIconButtonState extends State<_FocusedLabelIconButton> {
  final FocusNode _focusNode = FocusNode();
  bool _focused = false;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _focusNode.canRequestFocus = widget.onPressed != null;
    _focusNode.addListener(_syncFocus);
  }

  @override
  void didUpdateWidget(covariant _FocusedLabelIconButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _focusNode.canRequestFocus = widget.onPressed != null;
    _syncFocus();
  }

  @override
  void dispose() {
    _focusNode.removeListener(_syncFocus);
    _focusNode.dispose();
    super.dispose();
  }

  void _syncFocus() {
    final focused = _focusNode.hasFocus;
    if (mounted && _focused != focused) setState(() => _focused = focused);
  }

  @override
  Widget build(BuildContext context) {
    final expanded = _focused || _hovered;
    final enabled = widget.onPressed != null;
    final labelMeasure = TextPainter(
      text: TextSpan(
        text: widget.label,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 180);
    final expandedWidth = (labelMeasure.width + 52).clamp(88.0, 240.0);
    labelMeasure.dispose();
    return Tooltip(
      message: widget.tooltip ?? widget.label,
      child: Semantics(
        label: widget.label,
        button: true,
        enabled: enabled,
        onTap: widget.onPressed,
        excludeSemantics: true,
        child: FocusableActionDetector(
          focusNode: _focusNode,
          mouseCursor: enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onPressed?.call();
                return null;
              },
            ),
          },
          child: MouseRegion(
            onEnter: (_) {
              if (!_hovered) setState(() => _hovered = true);
            },
            onExit: (_) {
              if (_hovered) setState(() => _hovered = false);
            },
            child: GestureDetector(
              onTap: widget.onPressed,
              child: AnimatedContainer(
                duration: appMotion(context, const Duration(milliseconds: 120)),
                width: expanded ? expandedWidth : 48,
                height: 48,
                padding: EdgeInsets.symmetric(horizontal: expanded ? 8 : 0),
                decoration: BoxDecoration(
                  color: expanded ? AppColors.panelHi : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppRadius.control),
                  border: Border.all(
                    color: _focused ? AppColors.accent : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    Icon(widget.icon, size: 19, color: AppColors.textLo),
                    if (expanded) ...[
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textHi,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bridges [LiveZapController] to the channel list's own per-source plumbing.
///
/// It exists as a seam rather than the state implementing [ZapCatalog]
/// directly so the controller can be unit-tested with a fake — instantiating
/// this screen needs a live media_kit engine, which a Windows dev box hasn't
/// got, and the zap rules are far too load-bearing to be pinned only by a
/// suite that silently skips; see docs/development.md.
///
/// Every method routes through the **owning** source of the entry it is given,
/// never the active one: the cross-source Favorites view puts two providers'
/// channels in one zap range, and resolving, favouriting or framing one
/// against the wrong provider is silent and wrong rather than noisy.
class _ChannelListZapCatalog
    implements ZapCatalog, ChannelVariantCatalog, CaptureStreamCatalog {
  _ChannelListZapCatalog(this._screen)
    : _live = _screen._live,
      _favorites = _screen._globalFavorites,
      _liveOpenGeneration = _screen._liveOpenGeneration;

  final _ChannelListScreenState _screen;
  final LiveController _live;
  final GlobalFavoritesController _favorites;
  final int _liveOpenGeneration;
  LiveZapController? _zap;
  bool _refreshingEpg = false;
  bool _refreshEpgAgain = false;

  void bind(LiveZapController zap) {
    _zap = zap;
    _screen._livePlaybackEpgActive = true;
    _screen._syncEpgRefreshActivity();
    zap.addListener(_queueEpg);
    _live.addListener(_guideChanged);
    _favorites.addListener(_guideChanged);
    // Guide metadata follows playback in the background; a cache read must
    // never delay opening or handing off the live stream.
    _queueEpg();
  }

  void _guideChanged() => _zap?.refreshEpg();

  void _queueEpg() => unawaited(_refreshEpg());

  void checkTargetAllowed(ZapEntry entry) {
    if (!_allowed(entry)) {
      throw StateError(tr('This channel is locked or hidden.'));
    }
  }

  bool _allowed(ZapEntry entry) =>
      _current &&
      _screen._channelAllowed(entry.channel, entry.config) &&
      !entry.config.channelOrganization.hidden.contains(entry.channelId);

  bool get _current =>
      _screen._isLiveOpenCurrent(_liveOpenGeneration) &&
      identical(_screen._live, _live) &&
      identical(_screen._globalFavorites, _favorites);

  Future<void> _refreshEpg() async {
    if (_zap == null || !_current || _live.loading) return;
    if (_refreshingEpg) {
      _refreshEpgAgain = true;
      return;
    }
    _refreshingEpg = true;
    try {
      do {
        _refreshEpgAgain = false;
        final zap = _zap;
        if (zap == null || !_current) return;
        final list = zap.quickList;
        final wanted = [
          zap.current,
          zap.playing,
          if (list.open && list.mode == ZapQuickListMode.channels)
            for (final row in list.rows) zap.entries[row.index],
        ];
        final changed = await _live.ensureEpgForChannels([
          for (final entry in wanted)
            if (_isActiveSource(entry) && _allowed(entry)) entry.channelId,
        ]);
        if (_zap != zap || !_current) return;
        if (changed) zap.refreshEpg();
      } while (_refreshEpgAgain);
    } finally {
      _refreshingEpg = false;
    }
  }

  void dispose() {
    _zap?.removeListener(_queueEpg);
    _zap = null;
    _live.removeListener(_guideChanged);
    _favorites.removeListener(_guideChanged);
    if (_current) {
      _screen._livePlaybackEpgActive = false;
      _screen._syncEpgRefreshActivity();
    }
  }

  @override
  Future<List<ZapEntry>> channelVariants(
    ZapEntry entry, {
    int? currentHeight,
  }) async {
    if (!_current) return const [];
    final repo = _screen._repoFor(entry.config);
    final channels = await repo.db.readChannels(entry.sourceId);
    final hidden = entry.config.hiddenCategoryIds(ContentKind.live);
    return [
      for (final channel in lighterChannelVariants(
        channels
                .where((channel) => channel.id == entry.channelId)
                .firstOrNull ??
            entry.channel,
        channels.where(
          (channel) =>
              !hidden.contains(channel.categoryId) &&
              !entry.config.channelOrganization.hidden.contains(channel.id) &&
              _screen._channelAllowed(channel, entry.config),
        ),
        currentHeight: currentHeight,
      ))
        ZapEntry(
          channel: entry.config.channelOrganization.decorate(channel),
          config: entry.config,
          sourceName: entry.sourceName,
        ),
    ];
  }

  bool _isActiveSource(ZapEntry entry) =>
      entry.sourceId == _live.repo.source.id;

  @override
  Future<StreamInfo> resolve(ZapEntry entry) async {
    checkTargetAllowed(entry);
    final repo = _screen._repoFor(entry.config);
    final recording = _screen._recordingFor(entry.channel, repo);
    if (recording != null) {
      return DvrService.instance.recordingPlayback(recording);
    }
    return repo.resolve(entry.channel);
  }

  @override
  Future<StreamInfo> resolveCapture(ZapEntry entry) async {
    // A recording can outlive this route and its repository. Reconnect through
    // a separate provider client; normal resolve may return the recording's own
    // loopback URL when a viewer attaches to an already-running capture.
    final db = _screen.widget.repo.db;
    final source = entry.config.build();
    try {
      await source.connect();
      return await source.resolve(await db.revealChannel(entry.channel));
    } finally {
      await source.dispose();
    }
  }

  @override
  ({Programme? now, Programme? next}) epgFor(ZapEntry entry) {
    if (!_allowed(entry)) return (now: null, next: null);
    return _isActiveSource(entry) && _screen._liveLoadStarted
        ? _live.epgForChannel(entry.channelId)
        : _favorites.epgFor(entry.sourceId, entry.channelId);
  }

  @override
  bool isFavorite(ZapEntry entry) {
    if (!_current) return false;
    if (_isActiveSource(entry)) {
      return _screen._isFavorite(ContentKind.live, entry.channelId);
    }
    // `FavoritesController` holds only the active source's ids, so a foreign
    // row is answered from the cross-source list instead.
    return _screen._permittedGlobalFavorites.any(
      (item) =>
          item.sourceId == entry.sourceId && item.channel.id == entry.channelId,
    );
  }

  @override
  Future<void> setFavorite(ZapEntry entry, bool value) => !_current
      ? Future.value()
      : _isActiveSource(entry)
      ? _screen._setLiveFavorite(entry.channelId, value)
      : _screen._setForeignFavorite(entry.sourceId, entry.channelId, value);

  @override
  String? aspectLabelFor(ZapEntry entry) => entry.config.aspectModeLabel;

  @override
  Future<void> persistAspect(ZapEntry entry, String label) => _current
      ? _screen._persistAspectMode(entry.config, label)
      : Future.value();

  @override
  BufferPreset bufferPresetFor(ZapEntry entry) =>
      bufferPresetFromName(entry.config.bufferPresetName);

  @override
  void log(String note) => DiagnosticsLog.instance.add('library', note);

  // ── Quick list (Phase 6) ─────────────────────────────────────────────────

  /// Whether this session launched from the cross-source Favorites view.
  ///
  /// Read from the *screen*, not the entries: scanning a lazily wrapped
  /// 250k-channel range to count distinct source ids would materialise the
  /// whole thing, which is exactly what `zapEntriesOf` exists to avoid.
  bool get _crossSourceRange =>
      _screen._showFavorites ||
      _screen._categoryId == kAllSourcesFavoritesCategoryId;

  @override
  Future<List<ZapCategoryRow>> quickListCategories() async {
    if (!_current) return const [];
    // **The cross-source Favorites range has no provider categories**, so its
    // top mode lists the thing its rows actually differ by: the source that
    // owns them. Grouping by source is derived entirely from the rows already
    // in hand (no query, no provider round trip), it is the only grouping the
    // view itself draws (the per-row source chip), and narrowing to one
    // provider's favorites is a range a user can plausibly want. Offering the
    // *active* source's categories here would be incoherent — most rows in
    // the range don't belong to it.
    if (_crossSourceRange) {
      final labels = <String, String>{};
      for (final item in _screen._permittedGlobalFavorites) {
        labels.putIfAbsent(item.sourceId, () => item.sourceLabel);
      }
      return [
        ZapCategoryRow(id: '', title: tr('Favorites · All sources')),
        for (final entry in labels.entries)
          ZapCategoryRow(
            id: '$_kZapSourcePrefix${entry.key}',
            title: entry.value,
          ),
      ];
    }
    return [
      ZapCategoryRow(id: '', title: tr('All channels')),
      for (final category in _screen._liveCategoriesForUi)
        ZapCategoryRow(id: category.id, title: category.title),
    ];
  }

  @override
  Future<List<ZapEntry>> quickListChannels(ZapCategoryRow category) async {
    if (!_current) return const [];
    final id = category.id;
    if (id.startsWith(_kZapSourcePrefix) ||
        id == kAllSourcesFavoritesCategoryId ||
        (_crossSourceRange && id.isEmpty)) {
      final wanted = id.startsWith(_kZapSourcePrefix)
          ? id.substring(_kZapSourcePrefix.length)
          : null;
      return [
        for (final item in _screen._permittedGlobalFavorites)
          if (wanted == null || item.sourceId == wanted)
            ZapEntry(
              channel: item.channel,
              config: item.config,
              sourceName: item.sourceLabel,
            ),
      ];
    }
    return zapEntriesOf(
      _screen._liveChannelsForCategory(id.isEmpty ? null : id),
      config: _screen.widget.config,
      sourceName: _screen.widget.repo.source.name,
    );
  }

  @override
  Future<List<Programme>> quickListSchedule(ZapEntry entry) {
    if (!_allowed(entry)) return Future.value(const []);
    // Today, local midnight to midnight. Bounded on purpose: the mode stack
    // has no day rung, a day is ~30 rows a D-pad can walk end to end, and the
    // deeper archive is still one `CatchupSheet` away in the channel list.
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final repo = _screen._repoFor(entry.config);
    return repo.db.programmesForChannel(
      repo.source.id,
      entry.channelId,
      from: start,
      to: start.add(const Duration(days: 1)),
    );
  }
}

/// Prefix marking a quick-list category row that stands for a *source* rather
/// than a provider category — the cross-source Favorites range's top mode.
/// A provider category id could in principle collide with any literal, so the
/// prefix is only ever produced and consumed inside
/// [_ChannelListZapCatalog], and only for a range that has no provider
/// categories at all.
const String _kZapSourcePrefix = 'zapsrc:';
