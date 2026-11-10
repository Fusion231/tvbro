part of 'player_screen.dart';

extension _PlaybackSettings on _PlayerScreenState {
  void _resetAdaptiveBufferForChannel() {
    _adaptiveBufferPolicy.reset();
  }

  void _observeAdaptiveBuffer() {
    if (!_adaptiveBuffer || _separateEngineOwnsPlayback) return;
    if (!Platform.isWindows && !Platform.isAndroid) return;
    final aheadMs = _bufferedAheadMs();
    if (aheadMs < 0) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final next = _adaptiveBufferPolicy.observe(
      nowMs: nowMs,
      playing: _player.state.playing,
      buffering: _buffering,
      ended: _endedPending,
      bufferAheadMs: aheadMs,
    );
    if (next == null) return;
    _logPlayback('auto buffer preset=${next.storageName} ahead=${aheadMs}ms');
    unawaited(_applyAdaptiveBufferPreset(next));
  }

  Future<Map<String, String>> _channelBufferOptions(
    NativePlayer player, {
    BufferPreset? preset,
  }) async {
    final options = mpvBufferOptions(
      preset ??
          (_adaptiveBuffer
              ? _adaptiveBufferPolicy.effectivePreset
              : _bufferPreset),
    );
    if (options.isNotEmpty) return options;
    // A reused engine can still hold another channel's non-default preset.
    try {
      final value = await player.getProperty(
        'option-info/cache-secs/default-value',
      );
      if (double.tryParse(value) != null) return {'cache-secs': value};
    } catch (_) {
      _logPlayback('default buffer depth unavailable');
    }
    return options;
  }

  (String, String)? get _settingsIdentity {
    final entry = _zap?.playing;
    if (entry != null) return (entry.sourceId, 'live:${entry.channelId}');
    final playback = widget.playback;
    if (playback != null) {
      return (playback.sourceId, '${playback.kind.name}:${playback.itemId}');
    }
    if (_isLive && widget.dvrSourceId != null && widget.dvrChannelId != null) {
      return (widget.dvrSourceId!, 'live:${widget.dvrChannelId}');
    }
    return null;
  }

  Map<String, Object?> get _playbackPreferencesPayload => {
    'settingsSession': _settingsRevision,
    'qualityPreference': _preferences.quality,
    'bufferPreset': _bufferPreset.storageName,
    'adaptiveBuffer': _adaptiveBuffer,
    'matchRefreshRate': _preferences.matchRefreshRate,
    'aspect': kAspectModes[_aspectModeIndex].label,
  };

  Future<void> _loadPlaybackPreferences() async {
    final identity = _settingsIdentity;
    final key = identity == null
        ? null
        : PlaybackPreferencesStore.key(identity.$1, identity.$2);
    if (_preferencesIdentity == key && _settingsRevision != 0) return;
    _preferencesIdentity = key;
    final revision = ++_settingsRevision;
    _settingsOptions = const [];
    _settingsAlternatives = const [];
    _lastQualityApplication = null;
    _lastRefreshFps = null;
    _preferences = const PlaybackPreferences();
    if (identity != null) {
      try {
        await _preferenceWrites;
        final saved = await _preferencesStore.read(identity.$1, identity.$2);
        if (!mounted || revision != _settingsRevision) return;
        _preferences = saved;
      } catch (_) {
        _logPlayback('channel playback settings unavailable');
      }
    }
    if (!mounted || revision != _settingsRevision) return;
    _aspectModeIndex = resolveAspectModeIndex(
      _preferences.aspect ?? _zap?.aspectLabel ?? widget.initialAspectLabel,
    );
  }

  Future<void> _savePlaybackPreferences() {
    final identity = _settingsIdentity;
    if (identity == null) return Future.value();
    final saved = _preferences;
    // Serialize rapid selections; an older write must never win on disk.
    _preferenceWrites = _preferenceWrites.then((_) async {
      try {
        await _preferencesStore.write(identity.$1, identity.$2, saved);
      } catch (_) {
        _logPlayback('channel playback settings could not be saved');
      }
    });
    return _preferenceWrites;
  }

  List<VideoQuality> get _embeddedQualities => [
    for (final track in _player.state.tracks.video)
      if (track.id != 'auto' && track.id != 'no' && (track.h ?? 0) > 0)
        VideoQuality(
          id: track.id,
          height: track.h!,
          bitrate: track.bitrate ?? 0,
        ),
  ];

  Future<List<Map<String, String>>> _buildPlaybackSettings({
    Map<dynamic, dynamic>? nativeState,
  }) async {
    final revision = _settingsRevision;
    final nativeQualities = nativeState?['qualities'];
    final qualities = nativeQualities is List
        ? [
            for (final value in nativeQualities)
              if (value is Map) VideoQuality.fromMap(value),
          ]
        : _embeddedQualities;
    final unique =
        <String, VideoQuality>{
          for (final quality in qualities)
            if (quality.height > 0) quality.key: quality,
        }.values.toList()..sort(
          (a, b) => b.height != a.height
              ? b.height.compareTo(a.height)
              : b.bitrate.compareTo(a.bitrate),
        );
    final nativeHeight = nativeState?['height'];
    final height = nativeHeight is num
        ? nativeHeight.toInt()
        : _player.state.videoParams.h;
    final zap = _zap;
    var alternatives = <ZapEntry>[];
    if (zap != null && !zap.settling && _dvrSession == null) {
      final catalog = zap.catalog;
      if (catalog is ChannelVariantCatalog) {
        try {
          alternatives = await (catalog as ChannelVariantCatalog).channelVariants(
            zap.playing,
            currentHeight: height != null && height > 0 ? height : null,
          );
        } catch (_) {
          _logPlayback('lighter channel catalog unavailable');
        }
      }
    }
    if (!mounted || revision != _settingsRevision) return const [];
    _settingsAlternatives = alternatives;
    Map<String, String> row(String action, String label) => {
      'id': 'settings:$revision:$action',
      'label': label,
    };
    final selected = selectVideoQuality(unique, _preferences.quality)?.key;
    _settingsOptions = [
      row(
        'quality:auto',
        '${_preferences.quality == 'auto' ? '✓ ' : ''}${tr('Quality: Auto')}',
      ),
      if (unique.length > 1)
        for (final quality in unique)
          row(
            'quality:${quality.key}',
            '${selected == quality.key ? '✓ ' : ''}${tr(Platform.isAndroid ? 'Quality limit: {quality}' : 'Quality: {quality}', {'quality': quality.label})}',
          ),
      if (unique.length <= 1)
        row(
          'none',
          unique.isEmpty
              ? tr('Quality variants not available')
              : tr('Source quality: {quality}', {'quality': unique.single.label}),
        ),
      if (_supportsAdaptiveBuffer)
        row(
          'buffer:auto',
          '${_adaptiveBuffer ? '✓ ' : ''}${tr('Buffer: Auto · adjusts while playing')}',
        ),
      row(
        'buffer',
        '${_adaptiveBuffer ? '' : '✓ '}${tr('Buffer: {size} · next start', {'size': tr(bufferPresetLabel(_bufferPreset))})}',
      ),
      if (Platform.isAndroid || Platform.isWindows)
        row(
          'refresh',
          tr('Match refresh rate: {state}', {
            'state': _preferences.matchRefreshRate ? tr('On') : tr('Off'),
          }),
        ),
      if (zap != null && _dvrSession == null)
        if (alternatives.isEmpty)
          row('none', tr('No lighter channel available'))
        else
          for (var index = 0; index < alternatives.length; index++)
            row(
              'alternative:$index',
              tr('Lighter channel: {channel}', {'channel': alternatives[index].name}),
            ),
      row('reset', tr('Reset playback settings')),
    ];
    return _settingsOptions;
  }

  Future<void> _selectPlaybackSetting(String command) async {
    final prefix = 'settings:$_settingsRevision:';
    if (!command.startsWith(prefix) || (_zap?.settling ?? false)) return;
    final action = command.substring(prefix.length);
    if (action == 'none') return;
    if (action.startsWith('alternative:')) {
      final index = int.tryParse(action.substring('alternative:'.length));
      if (index != null && index >= 0 && index < _settingsAlternatives.length) {
        _zap?.selectAlternative(_settingsAlternatives[index]);
      }
      return;
    }
    if (action.startsWith('quality:')) {
      _preferences = _preferences.copyWith(quality: action.substring(8));
    } else if (action == 'buffer:auto') {
      if (!_supportsAdaptiveBuffer) return;
      _preferences = _preferences.copyWith(adaptiveBuffer: true);
    } else if (action == 'buffer') {
      _preferences = _preferences.copyWith(
        buffer: nextBufferPreset(_bufferPreset),
        adaptiveBuffer: false,
      );
    } else if (action == 'refresh') {
      _preferences = _preferences.copyWith(
        matchRefreshRate: !_preferences.matchRefreshRate,
      );
    } else if (action == 'reset') {
      _preferences = const PlaybackPreferences();
      _aspectModeIndex = resolveAspectModeIndex(
        _zap?.aspectLabel ?? widget.initialAspectLabel,
      );
    } else {
      return;
    }
    final revision = _settingsRevision;
    await _savePlaybackPreferences();
    if (!mounted || revision != _settingsRevision) return;
    if (Platform.isAndroid && _nativePlaybackLaunched) {
      await _PlayerScreenState._nativeHdrPlayer.invokeMethod<void>(
        'applyPlaybackPreferences',
        _playbackPreferencesPayload,
      );
    } else {
      if (action == 'buffer:auto') {
        _adaptiveBufferPolicy.reset();
        await _applyAdaptiveBufferPreset(BufferPreset.normal);
      }
      if (action == 'reset') await _applyCurrentAspect();
      await _applyEmbeddedQuality();
      _lastRefreshFps = null;
      await _matchWindowsRefreshRate();
    }
    _refreshPlaybackSettings();
    await _syncNativeControlState();
  }

  Future<void> _applyAdaptiveBufferPreset(BufferPreset preset) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    final options = await _channelBufferOptions(platform, preset: preset);
    await applyMpvOptions(
      platform,
      options,
      onWarn: (message) => _logPlayback('warn $message'),
    );
  }

  Future<void> _applyEmbeddedQuality() async {
    if (!mounted || _separateEngineOwnsPlayback) return;
    final tracks = _embeddedQualities;
    if (tracks.isEmpty) {
      _lastQualityApplication = null;
      return;
    }
    final selected = selectVideoQuality(tracks, _preferences.quality);
    final signature =
        '$_settingsRevision:${_preferences.quality}:${selected?.id}';
    if (_lastQualityApplication == signature) return;
    _lastQualityApplication = signature;
    try {
      final track = selected == null
          ? VideoTrack.auto()
          : _player.state.tracks.video.firstWhere((t) => t.id == selected.id);
      await _player.setVideoTrack(track);
    } catch (_) {
      _lastQualityApplication = null;
      _logPlayback('requested video quality is unavailable');
    }
  }

  Future<void> _matchWindowsRefreshRate() async {
    if (!Platform.isWindows || !mounted) return;
    final revision = _settingsRevision;
    final enabled = _preferences.matchRefreshRate;
    var fps = 0.0;
    if (enabled) {
      // Auto is a media_kit placeholder. The first advertised rendition can
      // have a different FPS from the video mpv actually selected.
      fps = (_player.state.track.video.fps ?? 0).toDouble();
      final platform = _player.platform;
      if (platform is NativePlayer) {
        try {
          fps = double.tryParse(await platform.getProperty('container-fps')) ?? fps;
        } catch (_) {
          // Unknown frame rate leaves the original display mode in place.
        }
      }
    }
    if (!mounted || revision != _settingsRevision ||
        enabled != _preferences.matchRefreshRate) {
      return;
    }
    if (!fps.isFinite || fps == _lastRefreshFps) return;
    _lastRefreshFps = fps;
    try {
      await _PlayerScreenState._nativeHdrPlayer.invokeMethod<bool>(
        'matchRefreshRate',
        {'fps': fps},
      );
    } on PlatformException {
      _logPlayback('display refresh matching is unavailable');
    } on MissingPluginException {
      // Older native host: keep its current display mode.
    }
  }

  Future<void> _showPlaybackSettings() async {
    if (_settingsDialogOpen) return;
    _settingsDialogOpen = true;
    try {
      final options = await _buildPlaybackSettings();
      if (!mounted) return;
      final selected = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(tr('Playback settings')),
          children: [
            for (final option in options)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, option['id']),
                child: Text(option['label']!),
              ),
          ],
        ),
      );
      if (selected != null && mounted) await _selectPlaybackSetting(selected);
    } finally {
      _settingsDialogOpen = false;
    }
  }
}
