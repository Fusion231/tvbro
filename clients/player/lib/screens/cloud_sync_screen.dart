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
import '../sources/source_config.dart';
import '../theme.dart';
import '../widgets/focusable_card.dart';
import '../widgets/pairing_qr.dart';
import '../widgets/pin_entry.dart';
import 'profile_pick_screen.dart';

enum _TransferDirection { download, upload }

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
  bool _pairingOnboarding = false;
  bool get _isOnboarding => widget.onboarding || _pairingOnboarding;
  bool _paired = false;
  bool _busy = false;
  bool _committing = false;
  String? _error;
  String? _status;
  PairingCode? _code;
  Timer? _poll;
  bool _pairingRequestPending = false;
  bool _pairingCoolingDown = false;
  int _pairingFailures = 0;
  List<CloudProfile> _profiles = const [];
  String? _activeProfileId;
  DateTime? _knownRemoteRevision;
  CloudCryptoStatus _crypto = CloudCryptoStatus.off;
  List<SourceConfig> _availableSources = const [];
  final Map<String, String> _unlockedPins = {};
  StreamSubscription<void>? _profileChanges;
  String? _observedProfile;
  Timer? _refreshTimer;
  bool _refreshPending = false;
  _TransferDirection? _direction;
  bool _previewLoading = false;
  bool _transferCompleted = false;
  String? _deviceProfileName;
  bool _uploadToNewProfile = true;
  bool _newNameInitialized = false;
  final _newProfileName = TextEditingController();
  String? _newUploadProfileId;

  bool get _isNewProfileUpload =>
      !_isOnboarding &&
      _direction == _TransferDirection.upload &&
      _uploadToNewProfile;

  bool get _transferLocked => _busy || _committing || _previewLoading;

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
    _newProfileName.dispose();
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
        if (_isOnboarding && mounted) {
          // A PIN dialog can wait for user input; show the paired screen
          // behind it instead of keeping the loading indicator running.
          setState(() => _loading = false);
          await _refreshOnboarding();
        }
      } else {
        // First pairing on an empty device is still initial setup, even when
        // entered through the account screen rather than the setup shortcut.
        _pairingOnboarding = (await widget.store.list()).isEmpty;
        await _newCode();
      }
    } catch (e) {
      if (mounted) setState(() => _error = tr(friendlyCloudError(e)));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// A sole onboarding profile needs no extra choice; multiple profiles do.
  Future<void> _loadProfiles() async {
    final profiles = await _sync.listProfiles();
    var active = _activeProfileId;
    if (!_isOnboarding && active == null) {
      active = await _sync.activeProfileId();
    }
    if (!profiles.any((p) => p.id == active)) active = null;
    if (_isOnboarding && active == null && profiles.length == 1) {
      active = profiles.single.id;
    }
    if (!_isOnboarding && active == null && profiles.isNotEmpty) {
      active = profiles.first.id;
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
    if (_isOnboarding && _observedProfile != active && active != null) {
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
    if (_transferLocked ||
        (!_isOnboarding && id == _activeProfileId && !_isNewProfileUpload)) {
      return;
    }
    if (_isOnboarding) {
      setState(() {
        _activeProfileId = id;
        _availableSources = const [];
        _status = null;
      });
      await _refreshOnboarding();
      return;
    }
    setState(() {
      _activeProfileId = id;
      _uploadToNewProfile = false;
      _transferCompleted = false;
      _status = null;
    });
    await _refreshTransfer();
  }

  Future<void> _selectDirection(_TransferDirection direction) async {
    if (_transferLocked) return;
    setState(() {
      _direction = direction;
      _uploadToNewProfile = true;
      _availableSources = const [];
      _transferCompleted = false;
      _status = null;
      _error = null;
    });
    await _refreshTransfer();
  }

  Future<void> _chooseDeviceProfile() async {
    if (_transferLocked) return;
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
    setState(() {
      _transferCompleted = false;
      _status = null;
      _newNameInitialized = false;
      _newUploadProfileId = null;
    });
    await _refreshTransfer();
  }

  Future<void> _refreshTransfer() async {
    if (_busy || _previewLoading) return;
    setState(() {
      _previewLoading = true;
      _error = null;
      _availableSources = const [];
    });
    try {
      await _loadProfiles();
      if (!mounted) return;
      if (_direction == _TransferDirection.upload) {
        const local = LocalProfileStore();
        final localId = await local.activeId();
        final localProfiles = await local.loadAll();
        var name = localProfiles
            .where((p) => p.id == localId)
            .firstOrNull
            ?.name;
        if (name == null && localId == null && !await local.ownerless()) {
          final cloudId = await _sync.cachedProfileId();
          name = _profiles.where((p) => p.id == cloudId).firstOrNull?.name;
        }
        final sources = await widget.store.list();
        if (!mounted) return;
        if (!_newNameInitialized) {
          _newProfileName.text = name?.trim().isNotEmpty == true
              ? name!.trim()
              : _suggestedLabel.isNotEmpty
              ? _suggestedLabel
              : tr('Current profile');
          _newNameInitialized = true;
        }
        setState(() {
          _deviceProfileName = name;
          _availableSources = sources;
        });
      } else if (_direction == _TransferDirection.download) {
        final profile = _profiles
            .where((p) => p.id == _activeProfileId)
            .firstOrNull;
        if (profile == null || !await _unlockOnboardingProfile(profile)) return;
        final sources = await _sync.previewSources(widget.store, profile.id);
        if (!mounted) return;
        setState(() => _availableSources = sources);
      }
    } catch (error) {
      if (mounted) setState(() => _error = tr(friendlyCloudError(error)));
    } finally {
      if (mounted) setState(() => _previewLoading = false);
    }
  }

  Future<void> _newCode() async {
    if (!mounted || _pairingRequestPending || _pairingCoolingDown) return;
    _poll?.cancel();
    _pairingRequestPending = true;
    var failed = false;
    try {
      final code = await _sync.requestPairingCode();
      if (!mounted) return;
      setState(() {
        _code = code;
        _error = null;
      });
    } catch (error) {
      failed = true;
      if (mounted) setState(() => _error = tr(friendlyCloudError(error)));
    } finally {
      _pairingRequestPending = false;
      _schedulePairingCheck(failed: failed);
    }
  }

  void _schedulePairingCheck({required bool failed}) {
    _poll?.cancel();
    if (!mounted || _paired) return;
    _pairingFailures = failed ? (_pairingFailures + 1).clamp(0, 5) : 0;
    _pairingCoolingDown = failed;
    final seconds = failed ? (3 * (1 << _pairingFailures)).clamp(3, 60) : 3;
    _poll = Timer(Duration(seconds: seconds), () {
      _pairingCoolingDown = false;
      unawaited(_checkClaim());
    });
  }

  Future<void> _checkClaim() async {
    if (!mounted || _paired || _pairingRequestPending || _pairingCoolingDown) {
      return;
    }
    final code = _code;
    // Codes are short-lived; refresh once expired so the screen stays usable.
    if (code == null || !DateTime.now().isBefore(code.expiresAt)) {
      await _newCode();
      return;
    }
    _poll?.cancel();
    _pairingRequestPending = true;
    var failed = false;
    try {
      if (await _sync.pairingStatus(code.code)) {
        _poll?.cancel();
        if (!mounted) return;
        setState(() => _paired = true);
        await _loadProfiles();
        if (_isOnboarding) {
          await _refreshOnboarding();
        }
      }
    } catch (_) {
      failed = true;
    } finally {
      _pairingRequestPending = false;
      _schedulePairingCheck(failed: failed);
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

  /// Download a usable profile after the user chooses it during onboarding.
  Future<void> _refreshOnboarding({bool autoContinue = true}) async {
    if (_busy || _committing) return;
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
    } catch (e) {
      if (mounted) setState(() => _error = tr(friendlyCloudError(e)));
    } finally {
      if (mounted) setState(() => _busy = false);
      if (mounted && _refreshPending) _scheduleOnboardingRefresh();
    }
    if (mounted &&
        ModalRoute.of(context)?.isCurrent == true &&
        autoContinue &&
        _availableSources.isNotEmpty) {
      await _continueOnboarding();
    }
  }

  Future<void> _continueOnboarding() async {
    if (_busy || _committing || _availableSources.isEmpty) return;
    // Re-read the profile and PIN before committing, since the panel may have
    // changed after the preview was displayed.
    await _refreshOnboarding(autoContinue: false);
    if (!mounted ||
        ModalRoute.of(context)?.isCurrent != true ||
        _availableSources.isEmpty) {
      return;
    }
    final profileId = _activeProfileId!;
    final profile = _profiles.firstWhere((p) => p.id == profileId);
    setState(() {
      _busy = true;
      _committing = true;
    });
    const localStore = LocalProfileStore();
    ProfileSnapshot? previous;
    String? previousLocal;
    bool ownerless = false;
    String? previousProfile;
    try {
      previousLocal = await localStore.activeId();
      ownerless = await localStore.ownerless();
      previousProfile = await _sync.cachedProfileId();
      previous = await _captureSnapshot();
      if (!ownerless) {
        if (previousLocal != null) {
          final local = (await localStore.loadAll())
              .where((p) => p.id == previousLocal)
              .firstOrNull;
          if (local != null) {
            await localStore.save(local.withSnapshot(previous));
          }
        } else if (previousProfile != null) {
          await localStore.saveCloudSnapshot(previousProfile, previous);
        }
      }
      await _restoreSnapshot(
        await localStore.cloudSnapshot(profileId) ?? const ProfileSnapshot(),
      );
      await _sync.setProfile(profileId);
      await _sync.withProfileReadSnapshot(profileId, () async {
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
      });
      await _sync.pullFavorites(widget.store, profileId);
      await _sync.pullPlaybackPositions(widget.store, profileId);
      await localStore.setCloudPin(profile.id, profile.pin, name: profile.name);
      await localStore.setOwnerless(false);
      await localStore.setActive(null);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (previous != null) {
        await _restoreSnapshot(previous);
        await localStore.setActive(previousLocal);
        // A first download can bind the device before its data arrives. Keep
        // the picker from treating that empty binding as a loaded profile.
        await localStore.setOwnerless(
          ownerless || (previousLocal == null && previousProfile == null),
        );
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
      _transferCompleted = false;
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
      final (count, metadata) = await _sync.withProfileReadSnapshot(
        profileId,
        () async {
          final count = await _sync.pullSources(widget.store, profileId);
          final metadata = await _sync.pullMetadata(widget.store, profileId);
          return (count, metadata);
        },
      );
      await _sync.pullFavorites(widget.store, profileId);
      await _sync.pullPlaybackPositions(widget.store, profileId);
      _knownRemoteRevision = (await _sync.profileRevision(profileId))
          ?.updatedAt;
      await profiles.setActive(null);
      await profiles.setOwnerless(false);
      if (!mounted) return;
      final sources = tr('Synced {count} source{suffix}', {
        'count': count,
        'suffix': count == 1 ? '' : 's',
      });
      setState(() {
        _status =
            '${initial ? tr('Paired — ') : ''}$sources'
            '${metadata ? tr(' · metadata updated') : ''}.';
        _transferCompleted = true;
      });
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
    if (mounted && _transferCompleted) await _refreshTransfer();
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
    final uri = Uri.tryParse(
      pairingPanelLink(
        CloudConfig.accountPanelUrl,
        _paired ? '' : _code?.code ?? '',
        language: AppLanguageController.instance.language.code,
      ),
    );
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
    final profile = _profiles.where((p) => p.id == profileId).firstOrNull;
    if (profile == null || !await _unlockOnboardingProfile(profile)) return;
    // Source ids are global in the panel. Uploading one to a different profile
    // would move it out of its original profile rather than create a copy.
    try {
      final ids = (await widget.store.list())
          .map((source) => source.id)
          .toSet();
      for (final other in _profiles.where((p) => p.id != profileId)) {
        final sources = await _sync.previewSources(widget.store, other.id);
        if (sources.any((source) => ids.contains(source.id))) {
          if (mounted) {
            setState(
              () => _error = tr(
                'Some playlists already belong to another panel profile. Upload to that profile, or add a separate copy in the panel.',
              ),
            );
          }
          return;
        }
      }
    } catch (error) {
      if (mounted) setState(() => _error = tr(friendlyCloudError(error)));
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
      _transferCompleted = false;
    });
    const local = LocalProfileStore();
    ProfileSnapshot? before;
    LocalProfile? localProfile;
    String? localId;
    String? previousCloud;
    bool previousOwnerless = false;
    bool rebound = false;
    try {
      localId = await local.activeId();
      previousCloud = await _sync.activeProfileId();
      previousOwnerless = await local.ownerless();
      before = await _captureSnapshot();
      localProfile = (await local.loadAll())
          .where((p) => p.id == localId)
          .firstOrNull;
      if (localProfile != null) {
        await local.save(localProfile.withSnapshot(before));
      }
      final count = await _sync.pushSources(widget.store, profileId);
      await _sync.pushMetadata(widget.store, profileId);
      await _sync.pushFavorites(widget.store, profileId);
      if ((await _sync.supporterStatus()).isActiveAt(DateTime.now())) {
        await _sync.pushPlaybackPositions(
          widget.store,
          profileId,
          includeAll: true,
        );
      }
      final uploaded = await _captureSnapshot();
      if (localProfile != null) {
        await local.save(
          localProfile.withSnapshot(
            ProfileSnapshot(
              sourcesJson: uploaded.sourcesJson,
              activeSourceId: uploaded.activeSourceId,
              metadataJson: uploaded.metadataJson,
            ),
          ),
        );
      }
      await _sync.setProfile(profileId);
      rebound = true;
      await local.saveCloudSnapshot(profileId, uploaded);
      await local.setCloudPin(profileId, profile.pin, name: profile.name);
      await local.setOwnerless(false);
      await local.setActive(null);
      _knownRemoteRevision = (await _sync.profileRevision(profileId))
          ?.updatedAt;
      if (!mounted) return;
      setState(() {
        _transferCompleted = true;
        _status = tr(
          'Pushed {count} source{suffix} · metadata · favorites to {profile}.',
          {
            'count': count,
            'suffix': count == 1 ? '' : 's',
            'profile': _activeProfileName,
          },
        );
      });
    } catch (e) {
      if (before != null) {
        await _restoreSnapshot(before);
        if (localProfile != null) {
          await local.save(localProfile.withSnapshot(before));
        }
        await local.setActive(localId);
        await local.setOwnerless(previousOwnerless);
        if (rebound && previousCloud != null) {
          await _sync.setProfile(previousCloud);
        }
      }
      if (mounted) setState(() => _error = tr(friendlyCloudError(e)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _transferCompleted) await _refreshTransfer();
  }

  Future<void> _pushNewProfile() async {
    final name = _newProfileName.text.trim();
    if (_transferLocked || name.isEmpty || _availableSources.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _transferCompleted = false;
      _error = null;
      _status = null;
    });
    try {
      const local = LocalProfileStore();
      var copyingEncryptedProfile = false;
      if (await local.activeId() == null && !await local.ownerless()) {
        final sourceProfile = await _sync.cachedProfileId();
        if (sourceProfile != null) {
          final crypto = await _sync.cryptoState(sourceProfile);
          copyingEncryptedProfile = crypto.status != CloudCryptoStatus.off;
        }
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _committing = true;
      });
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('Create a panel profile?')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(
                  'Create “{profile}” in your account with {count} playlist(s), settings and favorites from this device.',
                  {'profile': name, 'count': _availableSources.length},
                ),
              ),
              if (copyingEncryptedProfile) ...[
                const SizedBox(height: 16),
                Text(
                  tr(
                    'The new copy will not use end-to-end encryption. The panel server will be able to read its playlist credentials. The original encrypted profile stays unchanged.',
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(tr('Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(tr('Create and upload')),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      setState(() => _busy = true);
      // Keep the operation id on failure: a lost response must not create a
      // second profile when the user retries the same upload.
      final profile = await _sync.createProfileFromDevice(
        widget.store,
        profileId: _newUploadProfileId ??= newSourceId(),
        name: name,
      );
      if (!mounted) return;
      setState(() {
        _profiles = [..._profiles.where((p) => p.id != profile.id), profile];
        _activeProfileId = profile.id;
      });
      // The server copies sources to new ids. The regular download path parks
      // the original local profile and binds the device to that saved copy.
      await _pull();
      if (!mounted || !_transferCompleted) return;
      await local.saveCloudSnapshot(profile.id, await _captureSnapshot());
      if (!mounted) return;
      setState(() {
        _uploadToNewProfile = false;
        _newUploadProfileId = null;
        _status = tr(
          'Created {profile} in the panel with {count} playlist(s).',
          {'profile': profile.name, 'count': _availableSources.length},
        );
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _transferCompleted = false;
          _error = tr(friendlyCloudError(error));
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

  String get _activeProfileName {
    for (final p in _profiles) {
      if (p.id == _activeProfileId) {
        return _profileDisplayName(p);
      }
    }
    return tr('the profile');
  }

  String _profileDisplayName(CloudProfile profile) {
    final name = profile.name.trim().isEmpty
        ? tr('Profile')
        : profile.name.trim();
    final duplicates = _profiles.where(
      (p) => (p.name.trim().isEmpty ? tr('Profile') : p.name.trim()) == name,
    );
    return duplicates.length > 1
        ? '$name (${_profiles.indexOf(profile) + 1})'
        : name;
  }

  Future<void> _unpair() async {
    setState(() => _busy = true);
    try {
      await _sync.unpair(widget.store);
      if (!mounted) return;
      setState(() {
        _paired = false;
        _status = null;
        _direction = null;
        _transferCompleted = false;
        _newNameInitialized = false;
        _newUploadProfileId = null;
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
          title: Text(tr(_isOnboarding ? 'Download from cloud' : 'Cloud sync')),
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
              : LayoutBuilder(
                  builder: (context, constraints) {
                    if (_paired &&
                        !_isOnboarding &&
                        _direction != null &&
                        constraints.maxWidth >= 840) {
                      return _wideTransferBody();
                    }
                    return Center(
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
                                ...(_isOnboarding
                                    ? _onboardingBody()
                                    : _pairedBody())
                              else
                                ..._pairingBody(),
                              if (_status != null &&
                                  (!_paired || _isOnboarding)) ...[
                                const SizedBox(height: 20),
                                Text(
                                  _status!,
                                  style: const TextStyle(
                                    color: AppColors.accent,
                                  ),
                                ),
                              ],
                              if (_error != null) ...[
                                const SizedBox(height: 20),
                                Text(
                                  _error!,
                                  style: const TextStyle(
                                    color: AppColors.danger,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }

  Widget _wideTransferBody() => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1180),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr(
                      _direction == _TransferDirection.download
                          ? 'Download from panel'
                          : 'Upload from this device',
                    ),
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                _changeDirectionButton(),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ..._transferProfileControls(),
                          const SizedBox(height: 28),
                          TextButton.icon(
                            onPressed: _transferLocked ? null : _unpair,
                            icon: const Icon(Icons.link_off),
                            label: Text(tr('Unpair this device')),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                ..._transferDetails(),
                                if (_error != null) ...[
                                  const SizedBox(height: 20),
                                  Text(
                                    _error!,
                                    style: const TextStyle(
                                      color: AppColors.danger,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        ..._transferActions(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

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
          link: pairingPanelLink(
            CloudConfig.accountPanelUrl,
            code.code,
            language: AppLanguageController.instance.language.code,
          ),
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
              Flexible(
                child: Text(
                  CloudConfig.accountPanelUrl,
                  softWrap: true,
                  style: const TextStyle(
                    color: AppColors.accent,
                    decoration: TextDecoration.underline,
                    decorationColor: AppColors.accent,
                  ),
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
    Text(
      tr('Choose the profile you want to download.'),
      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
    ),
    const SizedBox(height: 8),
    Text(
      tr(
        'Choose a profile. Its playlists and settings will be downloaded automatically.',
      ),
      style: const TextStyle(color: AppColors.textLo),
    ),
    ..._profileSection(),
    if (_activeProfileId != null) ...[
      const SizedBox(height: 20),
      _cryptoStatusLine(),
      const SizedBox(height: 20),
      if (_committing)
        Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(tr('Downloading your profile…'))),
          ],
        )
      else if (!_busy)
        Text(
          tr(
            'Waiting for a playlist. Add a source in the panel or unlock its credentials, then refresh.',
          ),
        ),
    ],
    const SizedBox(height: 12),
    OutlinedButton.icon(
      onPressed: _busy ? null : _refreshOnboarding,
      icon: const Icon(Icons.refresh),
      label: Text(tr('Refresh playlists')),
    ),
  ];

  List<Widget> _pairedBody() => [
    Row(
      children: [
        Icon(Icons.cloud_done_outlined, color: AppColors.accent),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            tr('This device is paired'),
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
    const SizedBox(height: 8),
    if (_direction == null) ...[
      Text(
        tr(
          'Choose what you want to do. Nothing is transferred until you confirm.',
        ),
        style: const TextStyle(color: AppColors.textLo),
      ),
      const SizedBox(height: 24),
      _directionButton(
        _TransferDirection.download,
        Icons.cloud_download_outlined,
        'Download from panel',
        'Choose a saved profile and preview its playlists before downloading.',
      ),
      const SizedBox(height: 12),
      _directionButton(
        _TransferDirection.upload,
        Icons.cloud_upload_outlined,
        'Upload from this device',
        'Send this device\'s playlists and settings to a profile in your account.',
      ),
    ] else ...[
      Text(
        tr(
          _direction == _TransferDirection.download
              ? 'Download from panel'
              : 'Upload from this device',
        ),
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      ),
      _changeDirectionButton(),
      ..._transferProfileControls(),
      const SizedBox(height: 20),
      ..._transferDetails(),
      const SizedBox(height: 20),
      ..._transferActions(),
    ],
    const SizedBox(height: 28),
    TextButton.icon(
      onPressed: _transferLocked ? null : _unpair,
      icon: const Icon(Icons.link_off),
      label: Text(tr('Unpair this device')),
    ),
  ];

  Widget _changeDirectionButton() => TextButton.icon(
    key: const ValueKey('change-direction'),
    onPressed: _transferLocked
        ? null
        : () => setState(() {
            _direction = null;
            _transferCompleted = false;
            _status = null;
            _error = null;
          }),
    icon: const Icon(Icons.arrow_back),
    label: Text(tr('Change direction')),
  );

  List<Widget> _transferProfileControls() => [
    if (_direction == _TransferDirection.upload)
      OutlinedButton.icon(
        onPressed: _transferLocked ? null : _chooseDeviceProfile,
        icon: const Icon(Icons.switch_account_outlined),
        label: Text(tr('Choose a profile on this device')),
      ),
    ..._profileSection(),
    const SizedBox(height: 8),
    OutlinedButton.icon(
      key: const ValueKey('refresh-profiles'),
      onPressed: _transferLocked ? null : _refreshTransfer,
      icon: const Icon(Icons.refresh),
      label: Text(tr('Refresh profiles')),
    ),
  ];

  List<Widget> _transferDetails() => [
    _transferPreview(),
    if (!_isNewProfileUpload && _crypto != CloudCryptoStatus.off) ...[
      const SizedBox(height: 16),
      _cryptoStatusLine(),
    ],
  ];

  List<Widget> _transferActions() => [
    if (!_transferCompleted)
      FilledButton.icon(
        key: const ValueKey('transfer-submit'),
        onPressed:
            _transferLocked ||
                (_isNewProfileUpload
                    ? _newProfileName.text.trim().isEmpty
                    : _activeProfileId == null) ||
                _availableSources.isEmpty ||
                (_direction == _TransferDirection.upload &&
                    !_isNewProfileUpload &&
                    _crypto == CloudCryptoStatus.locked)
            ? null
            : _direction == _TransferDirection.download
            ? () => _pull()
            : _isNewProfileUpload
            ? _pushNewProfile
            : _push,
        icon: _busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                _direction == _TransferDirection.download
                    ? Icons.cloud_download_outlined
                    : Icons.cloud_upload_outlined,
              ),
        label: Text(
          tr(
            _direction == _TransferDirection.download
                ? 'Download selected profile'
                : _isNewProfileUpload
                ? 'Create profile and upload'
                : 'Upload to selected profile',
          ),
        ),
      ),
    if (_transferCompleted && _status != null) ...[
      const SizedBox(height: 20),
      Semantics(liveRegion: true, child: Text(_status!)),
      const SizedBox(height: 12),
      FilledButton.icon(
        key: const ValueKey('transfer-done'),
        onPressed: _transferLocked
            ? null
            : () => Navigator.of(context).pop(true),
        icon: const Icon(Icons.check),
        label: Text(tr('Continue watching')),
      ),
    ],
  ];

  Widget _directionButton(
    _TransferDirection direction,
    IconData icon,
    String title,
    String description,
  ) => OutlinedButton.icon(
    key: ValueKey(
      direction == _TransferDirection.download
          ? 'sync-download'
          : 'sync-upload',
    ),
    onPressed: _transferLocked ? null : () => _selectDirection(direction),
    icon: Icon(icon, size: 28),
    style: OutlinedButton.styleFrom(padding: const EdgeInsets.all(20)),
    label: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr(title),
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(
          tr(description),
          style: const TextStyle(color: AppColors.textLo, fontSize: 13),
        ),
      ],
    ),
  );

  Widget _transferPreview() => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: AppColors.panel,
      border: Border.all(color: AppColors.line),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr(
            _direction == _TransferDirection.download
                ? 'What will be downloaded'
                : 'What will be uploaded',
          ),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        if (_previewLoading)
          const LinearProgressIndicator()
        else ...[
          Text(
            _direction == _TransferDirection.upload
                ? tr('From this device: {profile}', {
                    'profile': _deviceProfileName ?? tr('Current profile'),
                  })
                : tr('From panel: {profile}', {'profile': _activeProfileName}),
            style: const TextStyle(color: AppColors.textLo, fontSize: 13),
          ),
          const SizedBox(height: 8),
          Text(tr('Playlists: {count}', {'count': _availableSources.length})),
          for (final source in _availableSources)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '• ${source.label.isEmpty ? source.kind.name.toUpperCase() : source.label}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (_availableSources.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                tr(
                  _direction == _TransferDirection.upload
                      ? 'No playlists on this device. Return to the player and choose a profile with playlists.'
                      : 'This panel profile has no playlists. Choose another profile or add a playlist in the panel.',
                ),
                style: const TextStyle(color: AppColors.textLo),
              ),
            ),
          if (_availableSources.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              tr('Profile settings and favorites are included.'),
              style: const TextStyle(color: AppColors.textLo, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Text(
              tr(
                _direction == _TransferDirection.download
                    ? 'Your current profile will be saved on this device before switching.'
                    : _isNewProfileUpload
                    ? 'A new panel profile will contain a copy of these playlists. Your local profile stays saved on this device.'
                    : 'The selected panel profile will be replaced. Your local profile remains saved on this device.',
              ),
              style: const TextStyle(color: AppColors.textLo, fontSize: 12),
            ),
          ],
        ],
      ],
    ),
  );

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

  /// Preview an existing profile, or create a separate copy when uploading.
  List<Widget> _profileSection() {
    final canCreate = !_isOnboarding && _direction == _TransferDirection.upload;
    if (_profiles.isEmpty && !canCreate) {
      return [
        SizedBox(height: 20),
        Text(
          tr(
            _isOnboarding
                ? 'No profiles yet — create one in the panel, then pull.'
                : 'No account profiles yet. Create one in the panel, then refresh profiles.',
          ),
          style: TextStyle(color: AppColors.textLo),
        ),
        TextButton(onPressed: _openPanel, child: Text(tr('Open panel'))),
      ];
    }
    return [
      const SizedBox(height: 20),
      Text(
        tr(
          _isOnboarding
              ? 'Profile'
              : _direction == _TransferDirection.upload
              ? 'Destination profile'
              : 'Panel profiles',
        ),
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 4),
      Text(
        tr(
          _isOnboarding
              ? 'Choose the profile you want to download.'
              : canCreate
              ? 'Create a new profile from this device, or choose an existing destination.'
              : 'Choose the profile you want to download.',
        ),
        style: TextStyle(color: AppColors.textLo, fontSize: 12),
      ),
      const SizedBox(height: 10),
      if (canCreate) ...[
        _ProfileRow(
          key: const ValueKey('upload-new-profile'),
          name: tr('Create a new profile'),
          selected: _uploadToNewProfile,
          autofocus: _uploadToNewProfile,
          onTap: _transferLocked
              ? null
              : () => setState(() {
                  _uploadToNewProfile = true;
                  _transferCompleted = false;
                  _status = null;
                  _error = null;
                }),
        ),
        if (_uploadToNewProfile) ...[
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('new-profile-name'),
            controller: _newProfileName,
            enabled: !_transferLocked,
            maxLength: 256,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: tr('Profile name'),
              helperText: tr(
                'The name comes from this device. You can change it.',
              ),
            ),
            onChanged: (_) => setState(() => _newUploadProfileId = null),
          ),
        ],
        if (_profiles.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            tr('Or choose an existing profile'),
            style: const TextStyle(color: AppColors.textLo, fontSize: 12),
          ),
          const SizedBox(height: 8),
        ],
      ],
      for (var i = 0; i < _profiles.length; i++)
        _ProfileRow(
          key: ValueKey('cloud-profile-${_profiles[i].id}'),
          name: _profileDisplayName(_profiles[i]),
          selected: !_isNewProfileUpload && _profiles[i].id == _activeProfileId,
          autofocus:
              !_isNewProfileUpload &&
              (_profiles[i].id == _activeProfileId ||
                  (_isOnboarding && _activeProfileId == null && i == 0)),
          onTap: _transferLocked ? null : () => _switchProfile(_profiles[i].id),
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
    super.key,
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
