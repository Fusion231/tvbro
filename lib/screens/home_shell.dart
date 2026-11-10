import 'dart:async' show Timer, unawaited;
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_brand.dart';
import '../l10n/app_localizations.dart';
import '../data/app_database.dart';
import '../data/cloud_auto_sync.dart';
import '../data/cloud_config.dart';
import '../data/cloud_sync.dart';
import '../data/distribution_channel.dart';
import '../data/diagnostics_log.dart';
import '../data/library_repository.dart';
import '../data/load_token.dart';
import '../data/local_profile_store.dart';
import '../data/metadata_clients.dart';
import '../data/metadata_provider.dart';
import '../data/net.dart' show sourceLoadErrorMessage;
import '../data/parental_controls.dart';
import '../data/source_store.dart';
import '../data/source_identity_migration.dart';
import '../data/supporter_access.dart';
import '../data/update_installer.dart';
import '../data/update_service.dart';
import '../data/update_store.dart';
import '../dvr/dvr_scheduler.dart';
import '../sources/source.dart';
import '../sources/source_config.dart';
import '../theme.dart';
import '../widgets/app_logo.dart';
import '../widgets/boot_autostart_setting.dart';
import '../widgets/library_preload_progress.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/parental_gate.dart';
import '../widgets/playlist_expiry_notice.dart';
import 'channel_list_screen.dart';
import 'cloud_sync_screen.dart';
import 'legal_screen.dart';
import 'profile_pick_screen.dart';
import 'profile_setup_screen.dart';
import 'sources_screen.dart';
import 'update_flow.dart';
import 'recordings_screen.dart';

/// Top-level shell: resolves the active source, builds its repository, and
/// shows the channel list — or an empty state when nothing is configured.
class HomeShell extends StatefulWidget {
  final AppDatabase db;
  final SourceStore store;
  final CloudSync? sync;
  const HomeShell({
    super.key,
    required this.db,
    required this.store,
    this.sync,
  });

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  late final CloudSync _sync = widget.sync ?? CloudSync(db: widget.db);
  late final SupporterAccess _supporter = SupporterAccess(sync: _sync);
  SourceConfig? _config;
  Source? _source;
  List<MetadataProvider> _metadataProviders = const [];
  LibraryRepository? _repo;
  bool _loading = true;
  bool _preloadingContent = false;
  bool _checkingSource = false;
  String? _preloadError;
  String? _libraryWarning;
  final Map<ContentKind, bool?> _preloadStages = {};
  bool? _preloadEpgReady;
  String? _preloadEpgMessage;
  LoadToken? _preloadToken;
  bool _profileSetupRequired = false;
  bool Function(KeyEvent event)? _keyboardLogger;
  bool _updateResumeActive = false;
  Timer? _catalogRefreshTimer;
  int _catalogRefreshGeneration = 0;
  bool _catalogRefreshPaused = false;
  DateTime? _catalogRetryAfter;
  int _librarySession = 0;
  Future<void>? _inactivityReset;

  /// Background profile sync; null when the build has no cloud config or
  /// this device isn't paired to a profile.
  CloudAutoSync? _cloudAutoSync;

  // Active profile info for the avatar — loaded after the main source load.
  // Local profile first (most-recently-selected), cloud profile as fallback.
  String? _profileName;
  int _profileColorIndex = 0;
  int _loadActiveGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    assert(() {
      _installKeyboardLogger();
      return true;
    }());
    // The auto-sync is started from `_loadActive`, which also re-binds it when
    // the profile changes — starting it here as well would race that.
    _loadActive();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _resetAfterInactivity();
      if (mounted) await _resumePendingThenCheck();
    });
  }

  /// Keeps the paired profile in step without a manual Pull or Push.
  ///
  /// Silent by design: it only runs when the build has cloud config *and* this
  /// device is paired to a profile, and every failure is logged rather than
  /// surfaced — the app is fully usable offline, and a sync that cannot reach
  /// the server is not an error the user needs to act on.
  /// The profile [_cloudAutoSync] is bound to, so a re-check can tell whether
  /// it still targets the right one.
  String? _cloudAutoSyncProfileId;

  bool _cloudAutoSyncStarting = false;
  bool _editingSources = false;
  Future<void>? _cloudAutoSyncStart;

  Future<void> _startCloudAutoSync() async {
    if (!CloudConfig.isConfigured || _editingSources) return;
    // Re-entrancy guard: this is fired unawaited from `_loadActive`, and two
    // overlapping loads (a source change landing during a profile switch)
    // would otherwise both get past the profile check and build two services
    // listening to the same stream — every local change then pushed twice.
    if (_cloudAutoSyncStarting) return;
    _cloudAutoSyncStarting = true;
    try {
      await (_cloudAutoSyncStart = _bindCloudAutoSync().catchError((Object _) {
        // Sources/backup remain available when the optional cloud is offline.
        DiagnosticsLog.instance.add('cloud', 'auto-sync binding unavailable');
      }));
    } finally {
      _cloudAutoSyncStarting = false;
    }
  }

  Future<void> _bindCloudAutoSync() async {
    // Restored cloud snapshots are local recovery profiles until the user
    // explicitly pairs/selects a cloud profile again.
    if (!mounted || _editingSources) return;
    const profiles = LocalProfileStore();
    if (await profiles.activeId() != null || await profiles.ownerless()) {
      await _stopCloudAutoSync();
      return;
    }
    final sync = _sync;
    if (!sync.hasSession) return;
    if (!await _supporter.allows(SupporterFeature.automaticFavorites)) {
      await _stopCloudAutoSync();
      return;
    }
    if (!mounted || _editingSources) return;
    String? profileId;
    try {
      profileId = await sync.activeProfileId();
    } catch (_) {
      // Keep the retry/remote observer alive across an offline boot. The
      // unexpired device entitlement was verified above; no new session is made.
      profileId = await sync.cachedProfileId();
      if (profileId == null) rethrow;
    }
    if (!mounted || _editingSources) return;

    // Already bound to this profile — nothing to do. This runs from
    // `_loadActive`, which also fires on every *source* change, so the common
    // case must be free.
    if (_cloudAutoSync != null && _cloudAutoSyncProfileId == profileId) return;

    if (_cloudAutoSync case final previous?) {
      // Send what the *previous* profile accumulated before letting go of it:
      // the outbox is not profile-scoped, so anything still queued would
      // otherwise be evaluated against the new profile's managed sources.
      await previous.flush();
      await previous.dispose();
      _cloudAutoSync = null;
      _cloudAutoSyncProfileId = null;
    }

    // Unpaired, or the device has no profile yet. Re-checked on every
    // `_loadActive`, so pairing from the cloud screen starts the sync on return
    // rather than at the next launch.
    if (profileId == null || !mounted || _editingSources) return;
    final boundProfileId = profileId;

    _cloudAutoSyncProfileId = boundProfileId;
    late final CloudAutoSync automatic;
    automatic = CloudAutoSync(
      pull: () async {
        if (!await _supporter.allows(SupporterFeature.automaticFavorites)) {
          unawaited(_stopCloudAutoSync(expected: automatic));
          return;
        }
        if (!mounted || _editingSources) return;
        final before = await _profileConfiguration();
        try {
          await sync.withProfileReadSnapshot(boundProfileId, () async {
            await sync.pullSources(
              widget.store,
              boundProfileId,
              preserveLocalChanges: true,
            );
            await sync.pullMetadata(
              widget.store,
              boundProfileId,
              preserveLocalChanges: true,
            );
            await sync.pullFavorites(widget.store, boundProfileId);
            await sync.pullPlaybackPositions(widget.store, boundProfileId);
          });
        } finally {
          if (mounted &&
              !_editingSources &&
              before != await _profileConfiguration()) {
            unawaited(_loadActive());
          }
        }
      },
      push: () async {
        if (!await _supporter.allows(SupporterFeature.automaticFavorites)) {
          unawaited(_stopCloudAutoSync(expected: automatic));
          return false;
        }
        final settings = await sync.pushSourceSettingsDelta(
          widget.store,
          boundProfileId,
        );
        final favorites = await sync.pushFavoritesDelta(
          widget.store,
          boundProfileId,
        );
        return settings || favorites;
      },
      pushPlayback: () async {
        if (!await _supporter.allows(SupporterFeature.automaticFavorites)) {
          unawaited(_stopCloudAutoSync(expected: automatic));
          return false;
        }
        return sync.pushPlaybackPositions(widget.store, boundProfileId);
      },
      pullPlayback: () async {
        if (!await _supporter.allows(SupporterFeature.automaticFavorites)) {
          unawaited(_stopCloudAutoSync(expected: automatic));
          return;
        }
        if (!mounted || _editingSources) return;
        await sync.pullPlaybackPositions(widget.store, boundProfileId);
      },
      changes: widget.db.favoritesChanged,
      additionalChanges: [widget.store.settingsChanged],
      playbackChanges: widget.db.playbackPositionsChanged,
      urgentPlaybackChanges: widget.db.playbackCheckpointed,
      profileChanges: sync.observeProfileUpdates(boundProfileId),
      shouldFlushImmediately: () => const {
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.detached,
      }.contains(WidgetsBinding.instance.lifecycleState),
    );
    _cloudAutoSync = automatic;
    await automatic.start();
  }

  Future<void> _stopCloudAutoSync({CloudAutoSync? expected}) async {
    if (expected != null && !identical(_cloudAutoSync, expected)) return;
    final previous = _cloudAutoSync;
    _cloudAutoSync = null;
    _cloudAutoSyncProfileId = null;
    await previous?.dispose();
  }

  // Reading saved configuration avoids rebuilding the player for favorite-only
  // notifications, while applying source/settings/metadata updates immediately.
  Future<String> _profileConfiguration() async => jsonEncode({
    'sources': [
      for (final source in await widget.store.list()) source.toJson(),
    ],
    'active': await widget.store.activeId(),
    'metadata': (await widget.store.metadataConfig()).toJson(),
  });

  Future<void> _pauseCloudAutoSync() async {
    _editingSources = true;
    await _cloudAutoSyncStart;
    final previous = _cloudAutoSync;
    await previous?.flush();
    await _stopCloudAutoSync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _catalogRefreshPaused = true;
      _stopCatalogRefresh();
    }
    // Send pending favorite changes before the process can be killed: on
    // Android a backgrounded app may never get another turn, and a change
    // sitting out its debounce would then wait for the next launch.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_cloudAutoSync?.flush() ?? Future<void>.value());
      return;
    }
    if (state != AppLifecycleState.resumed || !mounted) return;
    unawaited(_resumeApp());
  }

  Future<void> _resumeApp() async {
    await _resetAfterInactivity();
    if (!mounted ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _catalogRefreshPaused = false;
    unawaited(_scheduleCatalogRefresh());
    if (DvrScheduler.instance.canResolve) {
      unawaited(
        DvrScheduler.instance.refreshDue().catchError((Object _) {
          DiagnosticsLog.instance.add('dvr', 'schedule_resume_failed');
        }),
      );
    }
    // Another device may have changed favorites while this one was away.
    unawaited(_cloudAutoSync?.pullNow(onResume: true) ?? _startCloudAutoSync());
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _resumePendingThenCheck(),
    );
  }

  Future<void> _resetAfterInactivity() {
    final pending = _inactivityReset ??= _consumeInactivityReset().whenComplete(
      () => _inactivityReset = null,
    );
    // Bound resume work, but keep observing the native one-shot reply. A late
    // true must still reset navigation, and overlapping resumes share its read.
    return pending.timeout(const Duration(seconds: 2), onTimeout: () {});
  }

  Future<void> _consumeInactivityReset() async {
    // Flutter is also paused while Android's fullscreen Activity is visible.
    // Only the native host can distinguish watching from actually leaving.
    if (defaultTargetPlatform != TargetPlatform.android) return;
    bool reset;
    try {
      reset =
          await const MethodChannel('iptvs/app_session')
              .invokeMethod<bool>('consumeInactivityReset') ??
          false;
    } catch (_) {
      return;
    }
    if (!reset || !mounted) return;
    final route = ModalRoute.of(context);
    if (route == null) return;
    final navigator = Navigator.of(context);
    setState(() => _librarySession++);
    // Dispose the old list (and its pending stream resolutions) before popping
    // the player. Its push continuation must not restart the old preview.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    navigator.popUntil((candidate) => candidate == route);
    DiagnosticsLog.instance.add('library', 'inactive session returned to home');
  }

  Future<void> _resumePendingThenCheck() async {
    final handled = await _resumePendingUpdate();
    if (!handled && mounted) await _maybeCheckForUpdate();
  }

  Future<bool> _resumePendingUpdate() async {
    if (_updateResumeActive) return true;
    if (!mounted) return false;
    _updateResumeActive = true;
    try {
      return await resumePendingUpdate(context);
    } finally {
      _updateResumeActive = false;
    }
  }

  /// Throttled boot-time update check. Runs only on the release platforms
  /// (Android/Windows/Linux AppImage) where an in-app install is possible, and only if we
  /// haven't checked recently. [runUpdateCheck] prompts (respecting the
  /// skipped-version preference) and records the check time.
  Future<void> _maybeCheckForUpdate() async {
    if (!DistributionConfig.directUpdaterEnabled) return;
    if (!UpdateInstaller.isSupported) return;
    const store = UpdateStore();
    if (!shouldAutoCheck(await store.lastCheck(), DateTime.now())) return;
    if (!mounted) return;
    await runUpdateCheck(context, manual: false, store: store);
  }

  @override
  void dispose() {
    _preloadToken?.cancel();
    _stopCatalogRefresh();
    WidgetsBinding.instance.removeObserver(this);
    if (_keyboardLogger case final logger?) {
      HardwareKeyboard.instance.removeHandler(logger);
      _keyboardLogger = null;
    }
    unawaited(_cloudAutoSync?.dispose() ?? Future<void>.value());
    _cloudAutoSync = null;
    _cloudAutoSyncProfileId = null;
    _source?.dispose();
    for (final provider in _metadataProviders) {
      provider.close();
    }
    super.dispose();
  }

  void _installKeyboardLogger() {
    bool logger(KeyEvent event) {
      final focus = FocusManager.instance.primaryFocus;
      final focusLabel =
          focus?.debugLabel ??
          focus?.context?.widget.runtimeType.toString() ??
          'none';
      final keyLabel = event.logicalKey.keyLabel.isNotEmpty
          ? event.logicalKey.keyLabel
          : (event.logicalKey.debugName ?? event.logicalKey.keyId.toString());
      debugPrint(
        '[iptvs.keys] type=${event.runtimeType} logical=$keyLabel '
        'physical=${event.physicalKey.debugName ?? event.physicalKey.usbHidUsage.toString()} '
        'focus=$focusLabel',
      );
      return false;
    }

    _keyboardLogger = logger;
    HardwareKeyboard.instance.addHandler(logger);
  }

  Future<void> _loadActive({bool forcePreload = false}) async {
    final gen = ++_loadActiveGeneration;
    _preloadToken?.cancel();
    _stopCatalogRefresh();
    _catalogRetryAfter = null;
    if (mounted) {
      setState(() {
        _loading = true;
        _preloadingContent = forcePreload;
        _checkingSource = forcePreload;
        _preloadStages.clear();
        _preloadEpgReady = null;
        _preloadEpgMessage = null;
        _preloadError = null;
        _libraryWarning = null;
      });
    }
    // Cloud configuration must still arrive when the cached provider cannot
    // connect or there is no source yet. Catalog preload can return early.
    unawaited(_startCloudAutoSync());
    await migrateAllSourceIdentities(widget.db, await widget.store.list());
    final savedConfig = await widget.store.activeConfig();
    final cfg = savedConfig == null || sourceCredentialsMissing(savedConfig)
        ? null
        : savedConfig;
    final preloadContent =
        cfg != null &&
        (forcePreload || !await widget.db.hasLibraryContent(cfg.id));
    final metadata = await widget.store.metadataConfig();
    final profileSetupRequired = cfg == null
        ? await _hasPendingLocalProfileSetup()
        : false;
    final providers = buildMetadataProviders(
      metadata,
      language: AppLanguageController.instance.language == AppLanguage.polish
          ? 'pol'
          : 'eng',
    );
    debugPrint(
      '[iptvs.metadata] providers=${providers.map((p) => '${p.provider}:${p.authMode}').join(',')}',
    );
    final src = cfg?.build();
    if (!mounted || gen != _loadActiveGeneration) {
      await src?.dispose();
      for (final provider in providers) {
        provider.close();
      }
      return;
    }
    final previousSource = _source;
    final previousProviders = _metadataProviders;
    setState(() {
      _config = cfg;
      _source = src;
      _metadataProviders = providers;
      _repo = src == null
          ? null
          : LibraryRepository(
              source: src,
              db: widget.db,
              metadataProviders: providers,
              autoEnrichMetadata: metadata.autoEnrich,
            );
      _profileSetupRequired = profileSetupRequired;
      _preloadingContent = preloadContent;
      _checkingSource = preloadContent;
      _preloadEpgReady = null;
      _preloadEpgMessage = null;
      _preloadStages
        ..clear()
        ..addAll({
          if (preloadContent)
            for (final kind in const [
              ContentKind.live,
              ContentKind.movie,
              ContentKind.series,
            ])
              kind: null,
        });
      _loading = preloadContent;
    });
    // Capture ownership before awaiting teardown; a newer load may publish now.
    await previousSource?.dispose();
    for (final provider in previousProviders) {
      provider.close();
    }
    if (!mounted || gen != _loadActiveGeneration) return;
    if (preloadContent) {
      final repo = _repo!;
      final token = LoadToken();
      _preloadToken = token;
      repo.loadToken = token;
      try {
        // Sources own bounded transport retries. Repeating the whole setup
        // here multiplies those requests after the provider already failed.
        await src!.connect();
      } catch (error) {
        if (!mounted || gen != _loadActiveGeneration) return;
        setState(() {
          _checkingSource = false;
          _preloadError = sourceLoadErrorMessage(error);
        });
        return;
      }
      if (!mounted || gen != _loadActiveGeneration) return;
      setState(() => _checkingSource = false);
      var itemCount = 0;
      final errors = <ContentKind, String>{};
      String? epgWarning;
      // Finish both the catalogs and the guide before reporting setup ready.
      // One unavailable section must not hide the successfully saved content.
      Future<void> prepare(ContentKind kind) async {
        var ready = false;
        try {
          if (kind == ContentKind.live) {
            final snapshot = await repo.load(forceRefresh: forcePreload);
            itemCount += snapshot.channels.length;
            ready = true;
            if (mounted && gen == _loadActiveGeneration && !token.isCancelled) {
              setState(() => _preloadStages[kind] = true);
            }
            await repo.pendingEpgRefresh;
            if (!mounted || gen != _loadActiveGeneration || token.isCancelled) {
              return;
            }
            epgWarning = snapshot.channels.isEmpty
                ? null
                : await _epgWarning(repo);
            if (!mounted || gen != _loadActiveGeneration || token.isCancelled) {
              return;
            }
            setState(() {
              _preloadEpgReady = epgWarning == null;
              _preloadEpgMessage =
                  epgWarning ??
                  (capabilitiesOf(repo.source).epg ==
                          CapabilityAvailability.unavailable
                      ? tr('No program guide is configured for this source.')
                      : null);
            });
          } else {
            await repo.synchronizeMediaCatalog(
              kind,
              forceRefresh: forcePreload,
              token: token,
            );
            itemCount += await widget.db.countMediaItems(cfg.id, kind);
          }
          ready = true;
        } on LoadCancelledException {
          return;
        } catch (error) {
          final section = switch (kind) {
            ContentKind.live => tr('TV channels'),
            ContentKind.movie => tr('Movies'),
            _ => tr('Series'),
          };
          errors[kind] = tr('Could not load {section}. {message}', {
            'section': section,
            'message': sourceLoadErrorMessage(error),
          });
          if (kind == ContentKind.live &&
              mounted &&
              gen == _loadActiveGeneration &&
              !token.isCancelled) {
            setState(() {
              _preloadEpgReady = false;
              _preloadEpgMessage = tr(
                'Program guide unavailable because TV channels could not be loaded.',
              );
            });
          }
          DiagnosticsLog.instance.add(
            'library',
            'onboarding ${kind.name} preload failed: ${error.runtimeType}',
          );
        } finally {
          if (mounted && gen == _loadActiveGeneration && !token.isCancelled) {
            setState(() => _preloadStages[kind] = ready);
          }
        }
      }

      await Future.wait([
        prepare(ContentKind.live),
        prepare(ContentKind.movie),
        prepare(ContentKind.series),
      ]);
      if (!mounted || gen != _loadActiveGeneration) return;
      if (itemCount == 0) {
        setState(() {
          _preloadError = errors.isEmpty
              ? tr(
                  'This source returned no TV channels, movies, or series. '
                  'Check its URL and access details.',
                )
              : errors.values.join('\n');
        });
        return;
      }
      DiagnosticsLog.instance.add('library', 'onboarding preload completed');
      _preloadToken = null;
      repo.loadToken = null;
      final warnings = [...errors.values, if (epgWarning != null) epgWarning!];
      setState(() {
        _preloadingContent = false;
        _loading = false;
        _libraryWarning = warnings.isEmpty
            ? null
            : '${warnings.join('\n')}\n${tr('Saved content is still available. Open the unavailable section to try again.')}';
      });
    } else if (_repo case final repo?) {
      unawaited(_refreshCachedEpg(repo, gen));
    }
    // A failed onboarding section already exhausted its bounded retries.
    // Leave the successful cache usable and retry that section later.
    if (preloadContent) {
      _catalogRetryAfter = DateTime.now().add(const Duration(hours: 1));
    }
    unawaited(_scheduleCatalogRefresh());
    _loadProfileInfo();
  }

  Future<String?> _epgWarning(LibraryRepository repo) async {
    if (repo.lastEpgRefreshFailed) {
      return tr('Could not download the program guide. {message}', {
        'message':
            repo.lastEpgRefreshError ??
            tr('Check your connection and EPG settings.'),
      });
    }
    if (capabilitiesOf(repo.source).epg != CapabilityAvailability.supported) {
      return null;
    }
    final guide = await repo.nowNext();
    if (guide.now.isEmpty && guide.next.isEmpty) {
      return tr(
        'The source returned no current program information. Check EPG settings or try again later.',
      );
    }
    return null;
  }

  Future<void> _refreshCachedEpg(LibraryRepository repo, int generation) async {
    bool current() =>
        mounted &&
        generation == _loadActiveGeneration &&
        identical(repo, _repo);
    try {
      final channels = await widget.db.readChannels(repo.source.id);
      if (!current() || channels.isEmpty) return;
      await repo.refreshEpg(channels);
      final refresh = repo.pendingEpgRefresh;
      if (refresh == null) return;
      await refresh;
      if (!current()) return;
      final warning = await _epgWarning(repo);
      if (!mounted || !current() || warning == null) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(warning)));
    } catch (error) {
      DiagnosticsLog.instance.add(
        'epg',
        'cached home guide refresh failed: ${error.runtimeType}',
      );
    }
  }

  void _stopCatalogRefresh() {
    _catalogRefreshGeneration++;
    _catalogRefreshTimer?.cancel();
    _catalogRefreshTimer = null;
    _repo?.cancelCatalogSync();
  }

  Future<void> _scheduleCatalogRefresh() async {
    final repo = _repo;
    final generation = ++_catalogRefreshGeneration;
    _catalogRefreshTimer?.cancel();
    _catalogRefreshTimer = null;
    if (!mounted ||
        repo == null ||
        _catalogRefreshPaused ||
        _loading ||
        _preloadingContent) {
      return;
    }
    var delay = const Duration(hours: 1);
    try {
      delay = await repo.catalogRefreshDelay();
    } catch (error) {
      DiagnosticsLog.instance.add(
        'library',
        'catalog refresh scheduling failed: ${error.runtimeType}',
      );
    }
    if (!mounted || generation != _catalogRefreshGeneration) return;
    final retryDelay = _catalogRetryAfter?.difference(DateTime.now());
    if (retryDelay != null && retryDelay > delay) delay = retryDelay;
    _catalogRefreshTimer = Timer(delay, () {
      _catalogRefreshTimer = null;
      unawaited(_refreshCatalog(repo, generation));
    });
  }

  Future<void> _refreshCatalog(LibraryRepository repo, int generation) async {
    try {
      await repo.synchronizeCatalog();
    } on LoadCancelledException {
      return;
    } catch (error) {
      DiagnosticsLog.instance.add(
        'library',
        'catalog refresh failed: ${error.runtimeType}',
      );
    }
    if (!mounted || generation != _catalogRefreshGeneration) return;
    // Missing or failed sections stay due; one retry deadline prevents a
    // failed provider from turning that into a zero-delay timer loop.
    _catalogRetryAfter = DateTime.now().add(const Duration(hours: 1));
    await _scheduleCatalogRefresh();
  }

  Future<void> _loadProfileInfo() async {
    final gen = _loadActiveGeneration;
    try {
      // Local profile takes precedence (it's the most-recently-selected).
      final localStore = LocalProfileStore();
      final localActiveId = await localStore.activeId();
      if (localActiveId != null) {
        final locals = await localStore.loadAll();
        final local = locals.where((p) => p.id == localActiveId).firstOrNull;
        if (local != null && mounted && gen == _loadActiveGeneration) {
          setState(() {
            _profileName = local.name;
            _profileColorIndex = local.colorIndex;
          });
          return;
        }
      }
      // Fall back to cloud profile.
      if (CloudConfig.isConfigured) {
        final sync = _sync;
        final profiles = await sync.listProfiles();
        final activeId = await sync.activeProfileId();
        if (!mounted || gen != _loadActiveGeneration) return;
        final idx = profiles.indexWhere((p) => p.id == activeId);
        final profile = idx >= 0
            ? profiles[idx]
            : (profiles.isNotEmpty ? profiles.first : null);
        if (profile != null && mounted && gen == _loadActiveGeneration) {
          setState(() {
            _profileName = profile.name;
            _profileColorIndex = profileColorIndexFor(profile.id);
          });
        }
      }
    } catch (_) {
      // Best-effort — avatar falls back to the person icon.
    }
  }

  Future<void> _manageSources() async {
    if (!await authorizeParentalSettings(context) || !mounted) return;
    // A restore replaces favorites as well as source/profile ownership. Wait
    // for existing work before opening the route, including a startup pull.
    await _pauseCloudAutoSync();
    if (!mounted) return;
    final restored = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SourcesScreen(store: widget.store, db: widget.db),
      ),
    );
    if (!mounted) return;
    if (restored == true) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => ProfilePickScreen(
            db: widget.db,
            store: widget.store,
            bootMode: true,
          ),
        ),
        (_) => false,
      );
      return;
    }
    _editingSources = false;
    await _persistPendingLocalProfileSetup();
    await _loadActive();
  }

  Future<void> _addFirstSource() async {
    if (!await authorizeParentalSettings(context) || !mounted) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => EditSourceScreen(store: widget.store)),
    );
    if (saved != true) return;
    await _persistPendingLocalProfileSetup();
    await _loadActive();
  }

  Future<void> _addUsingPhone() async {
    if (!await authorizeParentalSettings(context) || !mounted) return;
    await _pauseCloudAutoSync();
    if (!mounted) return;
    final complete = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CloudSyncScreen(
          store: widget.store,
          db: widget.db,
          onboarding: true,
        ),
      ),
    );
    if (!mounted) return;
    _editingSources = false;
    if (complete == true) {
      await _loadActive();
    } else {
      unawaited(_startCloudAutoSync());
    }
  }

  Future<void> _editPreloadSource() async {
    if (!await authorizeParentalSettings(context) || !mounted) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            EditSourceScreen(store: widget.store, existing: _config),
      ),
    );
    if (saved == true && mounted) await _loadActive(forcePreload: true);
  }

  Future<bool> _hasPendingLocalProfileSetup() async {
    final localStore = LocalProfileStore();
    final id = await localStore.activeId();
    if (id == null) return false;
    final profiles = await localStore.loadAll();
    final profile = profiles.where((p) => p.id == id).firstOrNull;
    if (profile == null ||
        profile.snapshot.sourcesJson.isNotEmpty ||
        profile.snapshot.activeSourceId != null) {
      return false;
    }
    return (await widget.store.list()).isEmpty;
  }

  /// A newly created profile remains incomplete until it has an actual source.
  /// Persist the first choice into that profile only after it has been saved.
  Future<void> _persistPendingLocalProfileSetup() async {
    final localStore = LocalProfileStore();
    final id = await localStore.activeId();
    if (id == null) return;
    final profiles = await localStore.loadAll();
    final index = profiles.indexWhere((p) => p.id == id);
    if (index < 0) return;
    final profile = profiles[index];
    if (profile.snapshot.sourcesJson.isNotEmpty ||
        profile.snapshot.activeSourceId != null) {
      return;
    }

    final sources = await widget.store.list();
    if (sources.isEmpty) return;
    var activeId = await widget.store.activeId();
    if (activeId == null || !sources.any((source) => source.id == activeId)) {
      activeId = sources.first.id;
      await widget.store.setActive(activeId);
    }
    final snapshot = ProfileSnapshot(
      sourcesJson: [for (final source in sources) source.toJson()],
      activeSourceId: activeId,
      metadataJson: (await widget.store.metadataConfig()).toJson(),
    );
    await localStore.save(profile.withSnapshot(snapshot));
  }

  Future<void> _openRecordings() async {
    if (!await unlockParentalContent(context) || !mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const RecordingsScreen()),
    );
  }

  Future<void> _changeProfile() async {
    ParentalControlService.instance.lock();
    await _pauseCloudAutoSync();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProfilePickScreen(
          db: widget.db,
          store: widget.store,
          onDone: () => Navigator.of(context).pop(),
        ),
      ),
    );
    if (!mounted) return;
    _editingSources = false;
    await _loadActive();
  }

  Future<void> _profileSettings() async {
    if (!await authorizeParentalSettings(context) || !mounted) return;
    await _pauseCloudAutoSync();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CloudSyncScreen(store: widget.store, db: widget.db),
      ),
    );
    if (!mounted) return;
    _editingSources = false;
    await _loadActive();
  }

  Future<void> _useDemo() async {
    if (!await authorizeParentalSettings(context) || !mounted) return;
    await widget.store.save(
      const SourceConfig(
        id: 'demo',
        kind: SourceKind.demo,
        label: 'Demo',
        fields: {},
      ),
    );
    await widget.store.setActive('demo');
    await _persistPendingLocalProfileSetup();
    await _loadActive();
  }

  @override
  Widget build(BuildContext context) {
    final child = _buildContent(context);
    final config = _config;
    return config == null
        ? child
        : PlaylistExpiryNotice(
            config: config,
            enabled: !_loading || _preloadError != null,
            child: child,
          );
  }

  Widget _buildContent(BuildContext context) {
    if (_loading) {
      return _preloadingContent
          ? Scaffold(
              body: LibraryPreloadProgress(
                stages: _preloadStages,
                includeEpg: true,
                epgReady: _preloadEpgReady,
                epgMessage: _preloadEpgMessage,
                connecting: _checkingSource,
                error: _preloadError,
                onEditSource: () => unawaited(_editPreloadSource()),
                onRetry: () => unawaited(_loadActive(forcePreload: true)),
              ),
            )
          : const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final repo = _repo;
    if (repo == null) {
      return Scaffold(
        appBar: AppBar(
          title: const AppLogo(),
          actions: [
            IconButton(
              tooltip: tr('Help & about'),
              icon: const Icon(Icons.help_outline),
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const LegalScreen())),
            ),
          ],
        ),
        // Edge-to-edge (targetSdk 35+): centred content can still reach the
        // system bar on a short landscape viewport.
        body: SafeArea(
          top: false,
          child: _profileSetupRequired
              ? ProfileSetupChoices(
                  profileName: _profileName,
                  onChoose: (choice) {
                    if (choice == ProfileSetupChoice.addSource) {
                      unawaited(_addFirstSource());
                    } else if (choice == ProfileSetupChoice.cloud) {
                      unawaited(_addUsingPhone());
                    } else {
                      unawaited(_useDemo());
                    }
                  },
                )
              : Center(
                  child: SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: AppColors.panel,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: AppColors.line),
                              ),
                              child: const Icon(
                                Icons.live_tv_rounded,
                                size: 48,
                                color: AppColors.accent,
                              ),
                            ),
                            const SizedBox(height: 24),
                            Text(
                              tr('Welcome to {app}', {'app': AppBrand.name}),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 30,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              tr(
                                'Live television, your guide, movies and series — together '
                                'on your device. Connect your own IPTV provider to get started.',
                              ),
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: AppColors.textLo),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              tr(
                                'M3U playlists  ·  Xtream Codes  ·  Stalker portals',
                              ),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: AppColors.textLo,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 28),
                            const BootAutostartSetting(),
                            FilledButton.icon(
                              autofocus: true,
                              onPressed: _manageSources,
                              icon: const Icon(Icons.add),
                              label: Text(tr('Add a source')),
                            ),
                            const SizedBox(height: 8),
                            if (CloudConfig.isConfigured)
                              OutlinedButton.icon(
                                onPressed: _addUsingPhone,
                                icon: const Icon(Icons.qr_code_rounded),
                                label: Text(tr('Add using your phone')),
                              ),
                            TextButton(
                              onPressed: _useDemo,
                              child: Text(tr('Use demo streams')),
                            ),
                            TextButton.icon(
                              onPressed: _openRecordings,
                              icon: const Icon(Icons.video_library_outlined),
                              label: Text(tr('Recordings on this device')),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      );
    }

    return ChannelListScreen(
      key: ValueKey((_config!.id, _librarySession)),
      repo: repo,
      config: _config!,
      store: widget.store,
      initialWarning: _libraryWarning,
      onManageSources: _manageSources,
      onRefreshSource: () => _loadActive(forcePreload: true),
      onBeforeSourcePreferences: _pauseCloudAutoSync,
      onSourcePreferencesChanged: () {
        _editingSources = false;
        unawaited(_loadActive());
      },
      onOpenRecordings: _openRecordings,
      profileName: _profileName,
      profileColorIndex: _profileColorIndex,
      onChangeProfile: _changeProfile,
      // Profile settings = the cloud-sync screen; only meaningful when the
      // build has cloud config.
      onProfileSettings: CloudConfig.isConfigured ? _profileSettings : null,
    );
  }
}
