import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../data/app_database.dart';
import '../data/cloud_config.dart';
import '../data/cloud_sync.dart';
import '../data/device_label.dart';
import '../data/local_profile_store.dart';
import '../data/metadata_config.dart';
import '../data/source_store.dart';
import '../data/supporter_access.dart';
import '../sources/source_config.dart';
import '../theme.dart';
import '../widgets/focusable_card.dart';
import '../widgets/pairing_qr.dart';
import '../widgets/pin_entry.dart';
import '../widgets/supporter_gate.dart';

/// Pairs this device with a web-panel account and pulls its source list down.
/// No login happens here: the device shows a short code, the user enters it in
/// the panel (on a real keyboard), and this screen polls until it's claimed.
class CloudSyncScreen extends StatefulWidget {
  final SourceStore store;
  final AppDatabase db;
  final bool onboarding;

  /// Inject a fake in tests; defaults to the live Supabase-backed [CloudSync].
  final CloudSync? sync;

  const CloudSyncScreen({
    super.key,
    required this.store,
    required this.db,
    this.sync,
    this.onboarding = false,
  });

  @override
  State<CloudSyncScreen> createState() => _CloudSyncScreenState();
}

class _CloudSyncScreenState extends State<CloudSyncScreen> {
  late final CloudSync _sync = widget.sync ?? CloudSync(db: widget.db);

  bool _loading = true;
  bool _paired = false;
  bool _busy = false;
  bool _committing = false;
  String? _error;
  String? _status;
  PairingCode? _code;
  Timer? _poll;
  List<CloudProfile> _profiles = const [];
  String? _activeProfileId;
  DateTime? _knownRemoteRevision;
  CloudCryptoStatus _crypto = CloudCryptoStatus.off;
  List<SourceConfig> _availableSources = const [];
  final Map<String, String> _unlockedPins = {};
  SupporterStatus _supporter = SupporterStatus.free;
  StreamSubscription<void>? _profileChanges;
  String? _observedProfile;
  Timer? _refreshTimer;
  bool _refreshPending = false;

  /// The server reports this profile as unencrypted (or at an older key) after
  /// this device has already seen it encrypted. Always accompanies
  /// [CloudCryptoStatus.locked] — see [_refreshCrypto].
  bool _downgraded = false;

  /// The name this device suggests for itself while pairing, shown read-only so
  /// the user knows what will appear in the panel. Empty on an unknown platform
  /// (or if detection fails), in which case the hint is omitted entirely.
  String _suggestedLabel = '';

  @override
  void initState() {
    super.initState();
    _init();
    detectSuggestedDeviceLabel().then((label) {
      if (mounted) setState(() => _suggestedLabel = label);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _refreshTimer?.cancel();
    unawaited(_profileChanges?.cancel());
    super.dispose();
  }

  Future<void> _init() async {
    try {
      await _sync.ensureAnonSession();
      if (await _sync.isPaired()) {
        if (mounted) setState(() => _paired = true);
        await _loadProfiles();
        if (widget.onboarding && mounted) {
          // A PIN dialog can wait for user input; show the paired screen
          // behind it instead of keeping the loading indicator running.
          setState(() => _loading = false);
          await _refreshOnboarding();
        }
      } else {
        await _newCode();
      }
    } catch (e) {
      if (mounted) setState(() => _error = tr(friendlyCloudError(e)));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refreshSupporter() async {
    try {
      final supporter = await SupporterAccess(sync: _sync).status();
      if (mounted) setState(() => _supporter = supporter);
    } catch (_) {
      // Support status never holds up pairing, setup, or basic playback.
    }
  }

  /// Load the account's profiles and the device's active one, defaulting to the
  /// first profile when the device hasn't picked one yet.
  Future<void> _loadProfiles() async {
    unawaited(_refreshSupporter());
    final profiles = await _sync.listProfiles();
    var active = widget.onboarding
        ? _activeProfileId
        : await _sync.activeProfileId();
    if (!profiles.any((p) => p.id == active)) active = null;
    if (active == null && profiles.isNotEmpty) {
      active = profiles.first.id;
      if (!widget.onboarding) {
        try {
          await _sync.setProfile(active);
        } catch (_) {
          // Best-effort; the user can pick explicitly below.
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _activeProfileId = active;
      _knownRemoteRevision = profiles
          .where((p) => p.id == active)
          .firstOrNull
          ?.updatedAt;
    });
    await _refreshCrypto();
    if (widget.onboarding && _observedProfile != active && active != null) {
      await _profileChanges?.cancel();
      _observedProfile = active;
      _profileChanges = _sync.observeProfileChanges(active).listen((_) {
        _scheduleOnboardingRefresh();
      });
    }
  }

  void _scheduleOnboardingRefresh() {
    _refreshPending = true;
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted && !_busy && !_committing) {
        unawaited(_refreshOnboarding());
      }
    });
  }

  /// Refresh the E2EE status for the active profile (best-effort; degrades to
  /// [CloudCryptoStatus.off] against a pre-migration backend or on error).
  ///
  /// A *downgrade* also resolves to [CloudCryptoStatus.locked], so it is carried
  /// separately: the two states need different words and different actions —
  /// "unlock this device in the panel" versus "the encryption this profile had
  /// has disappeared". Without [_downgraded] the distinct message never reaches
  /// the screen.
  Future<void> _refreshCrypto() async {
    final profileId = _activeProfileId;
    if (profileId == null) return;
    try {
      final state = await _sync.cryptoState(profileId);
      if (mounted) {
        setState(() {
          _crypto = state.status;
          _downgraded = state.downgraded;
        });
      }
    } catch (_) {
      // Leave the prior status; the pull/push paths surface real failures.
    }
  }

  /// Accept that a profile's encryption was turned off deliberately, clearing
  /// this device's sticky mark. Confirm-gated because the *legitimate* case (a
  /// panel-side disable) and the attack (a backend lying about E2EE state) look
  /// identical from here — only the user knows which happened, so the device
  /// asks rather than guessing.
  Future<void> _acknowledgeDowngrade() async {
    final profileId = _activeProfileId;
    if (profileId == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Encryption turned off?')),
        content: Text(
          tr(
            'Only continue if you turned end-to-end encryption off yourself in '
            'the panel. If you did not, this device will start sending '
            'credentials the server can read.',
          ),
        ),
        actions: [
          TextButton(
            // See the note in sources_screen: a D-pad dialog with nothing
            // focused eats the first OK press.
            autofocus: true,
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('I turned it off')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _sync.acknowledgeE2eeDowngrade(profileId);
    await _refreshCrypto();
  }

  Future<void> _switchProfile(String id) async {
    if (id == _activeProfileId || _busy) return;
    if (widget.onboarding) {
      setState(() {
        _activeProfileId = id;
        _availableSources = const [];
        _status = null;
      });
      await _refreshOnboarding();
      return;
    }
    setState(() => _busy = true);
    try {
      if (!mounted) return;
      setState(() {
        _activeProfileId = id;
        _busy = false;
      });
      await _refreshCrypto();
      await _pull();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = tr(friendlyCloudError(e));
          _busy = false;
        });
      }
    }
  }

  Future<void> _newCode() async {
    _poll?.cancel();
    final code = await _sync.requestPairingCode();
    if (!mounted) return;
    setState(() {
      _code = code;
      _error = null;
    });
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _checkClaim());
  }

  Future<void> _checkClaim() async {
    final code = _code;
    if (code == null) return;
    // Codes are short-lived; refresh once expired so the screen stays usable.
    if (DateTime.now().isAfter(code.expiresAt)) {
      try {
        await _newCode();
      } catch (_) {
        /* keep polling on the old code's failure */
      }
      return;
    }
    try {
      if (await _sync.pairingStatus(code.code)) {
        _poll?.cancel();
        if (!mounted) return;
        setState(() => _paired = true);
        await _loadProfiles();
        if (widget.onboarding) {
          await _refreshOnboarding();
        } else {
          await _pull(initial: true);
        }
      }
    } catch (_) {
      // Transient network error — the next tick retries.
    }
  }

  Future<bool> _unlockOnboardingProfile(CloudProfile profile) async {
    final pin = profile.pin;
    if (pin == null || pin.isEmpty || _unlockedPins[profile.id] == pin) {
      return true;
    }
    final unlocked = await promptUnlockProfile(
      context,
      profileName: profile.name.isEmpty ? tr('Profile') : profile.name,
      verifier: pin,
    );
    if (unlocked) _unlockedPins[profile.id] = pin;
    return unlocked;
  }

  /// Preview for free setup; licensed devices import usable saved profiles.
  Future<void> _refreshOnboarding({bool autoContinue = true}) async {
    if (_busy) return;
    _refreshPending = false;
    setState(() {
      _busy = true;
      _error = null;
      _availableSources = const [];
    });
    try {
      await _loadProfiles();
      if (!mounted) return;
      final profile = _profiles
          .where((p) => p.id == _activeProfileId)
          .firstOrNull;
      if (profile == null) return;
      if (!await _unlockOnboardingProfile(profile)) {
        // Pairing may already select a server-side default profile. Without
        // a loaded local profile, keep Home from auto-importing it after a
        // canceled PIN gate; the picker must finish selecting it first.
        const local = LocalProfileStore();
        if (await local.activeId() == null) await local.setOwnerless(true);
        return;
      }
      final sources = await _sync.previewSources(widget.store, profile.id);
      if (!mounted) return;
      setState(
        () => _availableSources = sources
            .where((source) => !sourceCredentialsMissing(source))
            .toList(),
      );
      await _refreshSupporter();
    } catch (e) {
      if (mounted) setState(() => _error = tr(friendlyCloudError(e)));
    } finally {
      if (mounted) setState(() => _busy = false);
      if (mounted && _refreshPending) _scheduleOnboardingRefresh();
    }
    if (mounted &&
        autoContinue &&
        _availableSources.isNotEmpty &&
        _supporter.isActiveAt(DateTime.now())) {
      await _continueOnboarding();
    }
  }

  Future<void> _continueOnboarding() async {
    if (_busy || _availableSources.isEmpty) return;
    // Re-read the profile and PIN before committing, since the panel may have
    // changed after the preview was displayed.
    await _refreshOnboarding(autoContinue: false);
    if (!mounted || _availableSources.isEmpty) return;
    final profileId = _activeProfileId!;
    final profile = _profiles.firstWhere((p) => p.id == profileId);
    setState(() {
      _busy = true;
      _committing = true;
    });
    List<SourceConfig>? previousSources;
    String? previousActive;
    Set<String>? previousManaged;
    MetadataConfig? previousMetadata;
    String? previousProfile;
    try {
      previousSources = await widget.store.list();
      previousActive = await widget.store.activeId();
      previousManaged = await _sync.managedSourceIds();
      previousMetadata = await widget.store.metadataConfig();
      previousProfile = await _sync.cachedProfileId();
      await _sync.setProfile(profileId);
      await _sync.pullSources(widget.store, profileId);
      final sources = await widget.store.list();
      final usable = sources.where(
        (source) => !sourceCredentialsMissing(source),
      );
      if (usable.isEmpty) {
        throw StateError('No usable sources');
      }
      await widget.store.setActive(usable.first.id);
      await _sync.pullMetadata(widget.store, profileId);
      await _sync.pullFavorites(widget.store, profileId);
      const localStore = LocalProfileStore();
      await localStore.setCloudPin(profile.id, profile.pin, name: profile.name);
      await localStore.setOwnerless(false);
      await localStore.setActive(null);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (previousSources != null && previousManaged != null) {
        await widget.store.setAll(previousSources);
        await widget.store.setActive(previousActive);
        await _sync.setManagedSourceIds(previousManaged);
        if (previousMetadata != null) {
          await widget.store.saveMetadataConfig(
            previousMetadata,
            fromCloud: true,
          );
        }
        if (previousProfile != null && previousProfile != profileId) {
          await _sync.setProfile(previousProfile);
        }
      }
      if (mounted) {
        setState(() {
          _error = tr(friendlyCloudError(e));
          _availableSources = const [];
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _committing = false;
        });
      }
    }
  }

  Future<void> _pull({bool initial = false}) async {
    final profileId = _activeProfileId;
    if (profileId == null) {
      setState(
        () => _error = tr('No profile to sync — create one in the panel.'),
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    const profiles = LocalProfileStore();
    ProfileSnapshot? previous;
    String? previousCloud;
    String? previousLocal;
    bool ownerless = false;
    bool switching = false;
    try {
      previousLocal = await profiles.activeId();
      previousCloud = await _sync.activeProfileId();
      ownerless = await profiles.ownerless();
      switching =
          previousLocal != null || previousCloud != profileId || ownerless;
      if (switching || initial) {
        final profile = _profiles.where((p) => p.id == profileId).firstOrNull;
        if (profile == null) return;
        if (!await _unlockOnboardingProfile(profile)) {
          if (initial && previousLocal == null) {
            await profiles.setOwnerless(true);
          }
          return;
        }
      }
      if (switching) {
        previous = await _captureSnapshot();
        if (!ownerless) {
          if (previousLocal != null) {
            final local = (await profiles.loadAll())
                .where((p) => p.id == previousLocal)
                .firstOrNull;
            if (local != null) {
              await profiles.save(local.withSnapshot(previous));
            }
          } else if (previousCloud != null) {
            await profiles.saveCloudSnapshot(previousCloud, previous);
          }
        }
        await _restoreSnapshot(
          await profiles.cloudSnapshot(profileId) ?? const ProfileSnapshot(),
        );
        await _sync.setProfile(profileId);
      }
      unawaited(_refreshSupporter());
      final count = await _sync.pullSources(widget.store, profileId);
      final metadata = await _sync.pullMetadata(widget.store, profileId);
      await _sync.pullFavorites(widget.store, profileId);
      _knownRemoteRevision = (await _sync.profileRevision(profileId))
          ?.updatedAt;
      await profiles.setActive(null);
      await profiles.setOwnerless(false);
      if (!mounted) return;
      final sources = tr('Synced {count} source{suffix}', {
        'count': count,
        'suffix': count == 1 ? '' : 's',
      });
      setState(
        () => _status =
            '${initial ? tr('Paired — ') : ''}$sources'
            '${metadata ? tr(' · metadata updated') : ''}.',
      );
    } catch (e) {
      if (previous != null) {
        await _restoreSnapshot(previous);
        await profiles.setActive(previousLocal);
        await profiles.setOwnerless(ownerless);
        if (previousCloud != null) await _sync.setProfile(previousCloud);
      }
      if (mounted) setState(() => _error = tr(friendlyCloudError(e)));
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refreshCrypto();
    }
  }

  Future<ProfileSnapshot> _captureSnapshot() async => ProfileSnapshot(
    sourcesJson: [
      for (final source in await widget.store.list()) source.toJson(),
    ],
    activeSourceId: await widget.store.activeId(),
    metadataJson: (await widget.store.metadataConfig()).toJson(),
    managedIds: (await _sync.managedSourceIds()).toList(),
  );

  Future<void> _restoreSnapshot(ProfileSnapshot snapshot) async {
    await widget.store.setAll([
      for (final source in snapshot.sourcesJson) SourceConfig.fromJson(source),
    ]);
    await widget.store.setActive(snapshot.activeSourceId);
    await widget.store.saveMetadataConfig(
      MetadataConfig.fromJson(snapshot.metadataJson ?? const {}),
      fromCloud: true,
    );
    await _sync.setManagedSourceIds(snapshot.managedIds.toSet());
  }

  Future<void> _copyCode() async {
    final code = _code?.code;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('Code copied')),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _openPanel() async {
    final uri = Uri.tryParse(CloudConfig.panelUrl);
    var ok = false;
    if (uri != null) {
      try {
        ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        ok = false;
      }
    }
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Couldn\'t open the link — visit it manually')),
        ),
      );
    }
  }

  Future<void> _push() async {
    final profileId = _activeProfileId;
    if (profileId == null) {
      setState(() => _error = tr('No profile selected.'));
      return;
    }
    CloudRevision? current;
    try {
      current = await _sync.profileRevision(profileId);
    } catch (error) {
      // A revision read failure must not silently permit an overwrite. Treat
      // the revision as unknown; the conservative confirmation below remains.
      if (mounted) {
        setState(() => _error = tr(friendlyCloudError(error)));
      }
    }
    if (!mounted) return;
    if (shouldWarnBeforeOverwrite(
      knownRemoteRevision: _knownRemoteRevision,
      currentRemoteRevision: current?.updatedAt,
      hasLocalChanges: true,
    )) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('Panel changed')),
          content: Text(
            tr(
              'This profile changed on the panel since this device last '
              'synced. Pushing will replace those newer changes.',
            ),
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(tr('Cancel')),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(tr('Replace panel profile')),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (proceed != true) return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Push to panel?')),
        content: Text(
          tr(
            'This replaces the source list, metadata settings, and favorites of '
            'the selected profile ({profile}) with the ones on this '
            'device. Anything in that profile that isn\'t on this device will be '
            'removed.',
            {'profile': _activeProfileName},
          ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(tr('Push')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final count = await _sync.pushSources(widget.store, profileId);
      await _sync.pushMetadata(widget.store, profileId);
      await _sync.pushFavorites(widget.store, profileId);
      _knownRemoteRevision = (await _sync.profileRevision(profileId))
          ?.updatedAt;
      if (!mounted) return;
      setState(
        () => _status = tr(
          'Pushed {count} source{suffix} · metadata · favorites to {profile}.',
          {
            'count': count,
            'suffix': count == 1 ? '' : 's',
            'profile': _activeProfileName,
          },
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = tr(friendlyCloudError(e)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _activeProfileName {
    for (final p in _profiles) {
      if (p.id == _activeProfileId) {
        return p.name.isEmpty ? tr('profile') : p.name;
      }
    }
    return tr('the profile');
  }

  Future<void> _unpair() async {
    setState(() => _busy = true);
    try {
      await _sync.unpair(widget.store);
      if (!mounted) return;
      setState(() {
        _paired = false;
        _status = null;
      });
      await _newCode();
    } catch (e) {
      if (mounted) setState(() => _error = tr(friendlyCloudError(e)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_committing,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            tr(widget.onboarding ? 'Add using your phone' : 'Cloud sync'),
          ),
        ),
        // Edge-to-edge (targetSdk 35+): keep the pairing/push controls clear of the
        // system bar.
        body: SafeArea(
          top: false,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              // Capped and centred: this screen is mostly running prose and a
              // pairing code, and unconstrained it ran edge to edge on a
              // maximised desktop window.
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: kSettingsMaxContentWidth,
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_paired)
                            ...(widget.onboarding
                                ? _onboardingBody()
                                : _pairedBody())
                          else
                            ..._pairingBody(),
                          if (_status != null) ...[
                            const SizedBox(height: 20),
                            Text(
                              _status!,
                              style: const TextStyle(color: AppColors.accent),
                            ),
                          ],
                          if (_error != null) ...[
                            const SizedBox(height: 20),
                            Text(
                              _error!,
                              style: const TextStyle(color: AppColors.danger),
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

  List<Widget> _pairingBody() => [
    Text(
      tr('Pair this device'),
      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
    ),
    const SizedBox(height: 8),
    Text(
      tr(
        'Open the panel on your phone or computer, sign in, and enter this '
        'code under Devices:',
      ),
      style: const TextStyle(color: AppColors.textLo),
    ),
    const SizedBox(height: 20),
    Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: InkWell(
          onTap: _code == null ? null : _copyCode,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            decoration: BoxDecoration(
              color: AppColors.panelHi,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                // Balances the trailing copy icon so the code stays centered.
                const SizedBox(width: 38),
                // Scale the code down so any glyph mix fits the box on a
                // narrow phone instead of overflowing.
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.center,
                    child: Text(
                      _code?.code ?? '········',
                      maxLines: 1,
                      style: const TextStyle(
                        fontSize: 40,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 8,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                const Icon(Icons.copy_rounded, color: AppColors.textLo),
              ],
            ),
          ),
        ),
      ),
    ),
    const SizedBox(height: 8),
    Center(
      child: Text(
        tr('Tap the code to copy it'),
        style: TextStyle(color: AppColors.textLo, fontSize: 12),
      ),
    ),
    if (_code case final code?) ...[
      const SizedBox(height: 20),
      Center(
        child: PairingQrView(
          link: pairingPanelLink(CloudConfig.panelUrl, code.code),
        ),
      ),
    ],
    // Read-only on purpose: naming happens in the panel, on a real keyboard.
    // Adding a text field here would put a focus target — and a Back-ladder
    // rung — on a screen reached by D-pad remote.
    if (_suggestedLabel.isNotEmpty) ...[
      const SizedBox(height: 12),
      Center(
        child: Text(
          tr(
            'This device will appear as "{name}". '
            'You can give it another name in the panel.',
            {'name': _suggestedLabel},
          ),
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textLo, fontSize: 12),
        ),
      ),
    ],
    const SizedBox(height: 16),
    Center(
      child: InkWell(
        onTap: _openPanel,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.open_in_new, size: 16, color: AppColors.accent),
              const SizedBox(width: 6),
              Text(
                CloudConfig.panelUrl,
                style: const TextStyle(
                  color: AppColors.accent,
                  decoration: TextDecoration.underline,
                  decorationColor: AppColors.accent,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    const SizedBox(height: 24),
    FilledButton.icon(
      onPressed: _busy ? null : _newCode,
      icon: const Icon(Icons.refresh),
      label: Text(tr('New code')),
    ),
  ];

  List<Widget> _onboardingBody() => [
    ..._supporterStatus(),
    Text(
      tr('This device is paired'),
      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
    ),
    const SizedBox(height: 8),
    Text(
      tr(
        'Add your playlist in the panel, then refresh here. Continue when you are ready.',
      ),
      style: const TextStyle(color: AppColors.textLo),
    ),
    ..._profileSection(),
    const SizedBox(height: 20),
    _cryptoStatusLine(),
    const SizedBox(height: 20),
    Text(
      _availableSources.isEmpty
          ? tr(
              'Waiting for a playlist. Add a source in the panel or unlock its credentials, then refresh.',
            )
          : tr('Found {count} ready source(s).', {
              'count': _availableSources.length,
            }),
    ),
    const SizedBox(height: 12),
    OutlinedButton.icon(
      onPressed: _busy ? null : _refreshOnboarding,
      icon: const Icon(Icons.refresh),
      label: Text(tr('Refresh playlists')),
    ),
    const SizedBox(height: 12),
    FilledButton(
      onPressed: _busy || _availableSources.isEmpty
          ? null
          : _continueOnboarding,
      child: Text(tr('Continue')),
    ),
  ];

  List<Widget> _pairedBody() => [
    ..._supporterStatus(),
    Row(
      children: [
        Icon(Icons.cloud_done_outlined, color: AppColors.accent),
        SizedBox(width: 10),
        Text(
          tr('This device is paired'),
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
      ],
    ),
    const SizedBox(height: 8),
    Text(
      tr(
        'Sync this device with a profile in the panel. Pull replaces the '
        'cloud-managed sources, metadata, and favorites here with the '
        'profile\'s (sources you added locally are kept). Push sends this '
        'device\'s set up, replacing the profile\'s. Newest change wins.',
      ),
      style: TextStyle(color: AppColors.textLo),
    ),
    ..._profileSection(),
    const SizedBox(height: 20),
    _cryptoStatusLine(),
    const SizedBox(height: 20),
    FilledButton.icon(
      onPressed: _busy ? null : () => _pull(),
      icon: _busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.sync),
      label: Text(tr('Pull now')),
    ),
    const SizedBox(height: 12),
    OutlinedButton.icon(
      // Push is disabled on a locked E2EE device — it holds no content key, so
      // it can't produce the encrypted secret the server would accept.
      onPressed: (_busy || _crypto == CloudCryptoStatus.locked) ? null : _push,
      icon: const Icon(Icons.cloud_upload_outlined),
      label: Text(tr('Push to panel')),
    ),
    const SizedBox(height: 12),
    OutlinedButton.icon(
      onPressed: _busy ? null : _unpair,
      icon: const Icon(Icons.link_off),
      label: Text(tr('Unpair this device')),
    ),
  ];

  List<Widget> _supporterStatus() => [
    Text(
      tr(
        _supporter.isActiveAt(DateTime.now())
            ? 'Supporter active'
            : 'Free player',
      ),
      style: const TextStyle(fontWeight: FontWeight.w700),
    ),
    const SizedBox(height: 4),
    Text(
      tr(
        'Playback, playlists, EPG, manual recordings, one-off schedules and manual cloud sync stay free.',
      ),
      style: const TextStyle(color: AppColors.textLo, fontSize: 12),
    ),
    const SizedBox(height: 8),
    Text(
      tr(
        'Supporter conveniences: recurring weekday recordings, automatic settings and favorites sync, and saved-position movie and series resume.',
      ),
      style: const TextStyle(color: AppColors.textLo, fontSize: 12),
    ),
    if (!_supporter.isActiveAt(DateTime.now()))
      TextButton(
        onPressed: () async {
          await requireSupporter(
            context,
            SupporterFeature.automaticFavorites,
            access: SupporterAccess(sync: _sync),
          );
          await _refreshSupporter();
        },
        child: Text(tr('Supporter features')),
      ),
    const SizedBox(height: 20),
  ];

  /// A status line describing the profile's end-to-end-encryption state. Locked
  /// devices get the actionable unlock message (and Push is disabled above).
  Widget _cryptoStatusLine() {
    // Checked before the switch: a downgrade *is* `locked`, but the locked text
    // ("unlock this device in the panel") is actively misleading here — there is
    // nothing to unlock, because the server is claiming the encryption is gone.
    if (_downgraded) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.gpp_maybe_outlined,
            size: 18,
            color: AppColors.danger,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(kCloudE2eeDowngradedMessage),
                  style: TextStyle(color: AppColors.danger, fontSize: 13),
                ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: _busy ? null : _acknowledgeDowngrade,
                  child: Text(tr('I turned encryption off on purpose')),
                ),
              ],
            ),
          ),
        ],
      );
    }
    final (IconData icon, String text, Color color) = switch (_crypto) {
      CloudCryptoStatus.off => (
        Icons.lock_open_outlined,
        tr(
          'End-to-end encryption: off (secrets protected by the server\'s access '
          'control and TLS).',
        ),
        AppColors.textLo,
      ),
      CloudCryptoStatus.ready => (
        Icons.lock_outline,
        tr(
          'End-to-end encryption: on — this device is set up and can sync '
          'credentials.',
        ),
        AppColors.accent,
      ),
      CloudCryptoStatus.locked => (
        Icons.lock,
        tr(
          'This profile is end-to-end encrypted. Open the panel and unlock it to '
          'finish setting up this device. Until then, Push is disabled and '
          'sources without saved credentials need attention.',
        ),
        AppColors.danger,
      ),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: TextStyle(color: color, fontSize: 13)),
        ),
      ],
    );
  }

  /// The profile picker: lists the account's profiles, highlights the active
  /// one, and switches (then re-pulls) on selection. Profiles are created and
  /// renamed in the web panel.
  List<Widget> _profileSection() {
    if (_profiles.isEmpty) {
      return [
        SizedBox(height: 20),
        Text(
          tr('No profiles yet — create one in the panel, then pull.'),
          style: TextStyle(color: AppColors.textLo),
        ),
      ];
    }
    return [
      const SizedBox(height: 20),
      Text(tr('Profile'), style: TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      Text(
        tr('Pick which profile this device syncs.'),
        style: TextStyle(color: AppColors.textLo, fontSize: 12),
      ),
      const SizedBox(height: 10),
      for (var i = 0; i < _profiles.length; i++)
        _ProfileRow(
          name: _profiles[i].name.isEmpty ? tr('Profile') : _profiles[i].name,
          selected: _profiles[i].id == _activeProfileId,
          autofocus: _profiles[i].id == _activeProfileId,
          onTap: _busy ? null : () => _switchProfile(_profiles[i].id),
        ),
    ];
  }
}

class _ProfileRow extends StatelessWidget {
  final String name;
  final bool selected;
  final bool autofocus;
  final VoidCallback? onTap;

  const _ProfileRow({
    required this.name,
    required this.selected,
    required this.autofocus,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      autofocus: autofocus,
      onTap: onTap ?? () {},
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
              color: selected ? AppColors.accent : AppColors.textLo,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? AppColors.textHi : AppColors.textLo,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
