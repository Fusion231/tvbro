import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:media_kit/media_kit.dart';
import 'package:video_player_avplay/video_player.dart' as av;
import 'package:video_player_avplay/video_player_platform_interface.dart'
    as api;

typedef AvplayControllerFactory = av.VideoPlayerController Function(
  Media media,
);

/// Uses MediaKit's public platform injection; never constructs NativePlayer/mpv.
Player createTizenPlayer({
  PlayerConfiguration configuration = const PlayerConfiguration(),
}) => Player(
  configuration: configuration,
  platformPlayer: TizenAvplayPlatformPlayer(configuration: configuration),
);

bool isTizenPlayer(Player player) =>
    player.platform is TizenAvplayPlatformPlayer;

Widget buildTizenVideo(
  Player player, {
  BoxFit fit = BoxFit.contain,
  Color fill = Colors.black,
}) {
  final backend = player.platform;
  if (backend is! TizenAvplayPlatformPlayer) {
    throw ArgumentError('The player was not created by createTizenPlayer.');
  }
  return _TizenVideoSurface(backend: backend, fit: fit, fill: fill);
}

/// Converts only backend operations/events. Source resolution, reconnect,
/// provider ownership, navigation and playback UI remain in package:iptvs.
class TizenAvplayPlatformPlayer extends PlatformPlayer {
  TizenAvplayPlatformPlayer({
    super.configuration = const PlayerConfiguration(),
    @visibleForTesting AvplayControllerFactory? controllerFactory,
  }) : _createController = controllerFactory ?? controllerForMedia {
    state = const PlayerState(
      tracks: Tracks(
        video: [],
        audio: [],
        subtitle: [SubtitleTrack('no', null, null)],
      ),
    );
    completer.complete();
  }

  final AvplayControllerFactory _createController;
  final ValueNotifier<av.VideoPlayerController?> videoController =
      ValueNotifier(null);
  av.VideoPlayerController? _controller;
  VoidCallback? _controllerListener;
  Future<void> _tail = Future.value();
  Future<void>? _disposeFuture;
  int _generation = 0;
  bool _disposed = false;
  final ValueNotifier<bool> _subtitlesVisible = ValueNotifier(true);
  BoxFit _fit = BoxFit.contain;
  final Map<String, av.VideoTrack> _videoTracks = {};
  final Map<String, av.AudioTrack> _audioTracks = {};
  final Map<String, av.TextTrack> _textTracks = {};

  Future<void> _serial(Future<void> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  void _checkAlive() {
    if (_disposed) throw StateError('The Tizen player has been disposed.');
  }

  bool _current(int generation, av.VideoPlayerController controller) =>
      !_disposed &&
      generation == _generation &&
      identical(controller, _controller);

  @override
  Future<void> open(Playable playable, {bool play = true}) {
    _checkAlive();
    final generation = ++_generation;
    return _serial(() async {
      if (_disposed || generation != _generation) return;
      await _closeController();
      if (_disposed || generation != _generation) return;
      try {
        final Media media;
        if (playable is Media) {
          media = playable;
        } else if (playable is Playlist &&
            playable.medias.length == 1 &&
            playable.index == 0) {
          media = playable.medias.single;
        } else {
          throw UnsupportedError(
            'Tizen AVPlay accepts Media or a single-entry Playlist.',
          );
        }
        // Validate independently of the injectable controller factory.
        _streamingHeaders(media.httpHeaders);
        _videoTracks.clear();
        _audioTracks.clear();
        _textTracks.clear();
        _subtitlesVisible.value = true;
        _lastError = null;
        _publish(
          PlayerState(
            playlist: Playlist([media]),
            volume: state.volume,
            rate: state.rate,
            buffering: true,
            tracks: const Tracks(
              video: [],
              audio: [],
              subtitle: [SubtitleTrack('no', null, null)],
            ),
          ),
        );
        final controller = _createController(media);
        _controller = controller;
        // Seed settings without issuing any native playback before initialization.
        await controller.setVolume(state.volume / 100);
        await controller.setPlaybackSpeed(state.rate);
        if (!_current(generation, controller)) return;
        _controllerListener = () => _receive(controller, generation);
        controller.addListener(_controllerListener!);
        videoController.value = controller;
        await controller.initialize();
        if (!_current(generation, controller)) return;
        if (play) await controller.play();
        if (!_current(generation, controller)) return;
        if (media.start != null) await controller.seekTo(media.start!);
        if (!_current(generation, controller)) return;
        await controller.setDisplayMode(_displayMode(_fit));
        if (!_current(generation, controller)) return;
        if (state.rate != 1) await controller.setPlaybackSpeed(state.rate);
        if (!_current(generation, controller)) return;
        _receive(controller, generation);
        await _refreshTracks(controller, generation);
      } catch (error) {
        if (!_disposed && generation == _generation) {
          _publish(state.copyWith(playing: false, buffering: false));
          final message = _errorMessage(error);
          if (_lastError != message) errorController.add(message);
          _lastError = message;
        }
        // A failed SDK initialization must release its native player too.
        await _closeController();
        rethrow;
      }
    });
  }

  Future<void> _closeController() async {
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    if (_controllerListener != null) {
      controller.removeListener(_controllerListener!);
      _controllerListener = null;
    }
    videoController.value = null;
    await controller.dispose();
  }

  void _receive(av.VideoPlayerController controller, int generation) {
    if (!_current(generation, controller)) return;
    final value = controller.value;
    if (value.hasError) {
      _publish(state.copyWith(playing: false, buffering: false));
      final message = value.errorDescription ?? 'Tizen AVPlay playback failed.';
      if (_lastError != message) errorController.add(message);
      _lastError = message;
      return;
    }
    _lastError = null;
    final width = value.size.width.isFinite ? value.size.width.round() : 0;
    final height = value.size.height.isFinite ? value.size.height.round() : 0;
    final text = !_subtitlesVisible.value
        ? <String>[]
        : (value.captions.textCaptions ?? [])
              .map((caption) => caption.text)
              .toList();
    _publish(
      state.copyWith(
        playing: value.isPlaying,
        completed: value.isCompleted,
        position: value.position,
        // Retain the SDK timebase: live ranges may have a non-zero start.
        // Subtracting a sliding start would hide progress from the app watchdog.
        duration: value.duration.end,
        buffering: value.isBuffering || !value.isInitialized,
        bufferingPercentage: value.buffered.clamp(0, 100).toDouble(),
        volume: value.volume * 100,
        rate: value.playbackSpeed,
        width: width,
        height: height,
        videoParams: VideoParams(
          w: width,
          h: height,
          dw: width,
          dh: height,
          aspect: height > 0 ? width / height : null,
        ),
        subtitle: text,
      ),
    );
  }

  String? _lastError;

  Future<void> _refreshTracks(
    av.VideoPlayerController controller,
    int generation,
  ) async {
    try {
      final videos = await controller.videoTracks ?? <av.VideoTrack>[];
      final audios = await controller.audioTracks ?? <av.AudioTrack>[];
      final texts = await controller.textTracks ?? <av.TextTrack>[];
      final active = await controller.getActiveTrackInfo();
      if (!_current(generation, controller)) return;
      _videoTracks.addEntries(
        videos.map((track) => MapEntry('${track.trackId}', track)),
      );
      _audioTracks.addEntries(
        audios.map((track) => MapEntry('${track.trackId}', track)),
      );
      _textTracks.addEntries(
        texts.map((track) => MapEntry('${track.trackId}', track)),
      );
      var selected = state.track;
      for (final track in active) {
        if (track is av.VideoTrack)
          selected = selected.copyWith(video: _videoTrack(track));
        if (track is av.AudioTrack)
          selected = selected.copyWith(audio: _audioTrack(track));
        if (track is av.TextTrack)
          selected = selected.copyWith(subtitle: _textTrack(track));
      }
      _publish(
        state.copyWith(
          track: selected,
          tracks: Tracks(
            video: videos.map(_videoTrack).toList(),
            audio: audios.map(_audioTrack).toList(),
            subtitle: [SubtitleTrack.no(), ...texts.map(_textTrack)],
          ),
        ),
      );
    } catch (error) {
      if (_current(generation, controller)) {
        logController.add(
          PlayerLog(
            prefix: 'tizen-avplay',
            level: 'warn',
            text: 'Track metadata is unavailable: ${_errorMessage(error)}',
          ),
        );
      }
    }
  }

  static VideoTrack _videoTrack(av.VideoTrack track) => VideoTrack(
    '${track.trackId}',
    track.mimetype,
    null,
    codec: track.mimetype,
    w: track.width,
    h: track.height,
    bitrate: track.bitrate,
  );
  static AudioTrack _audioTrack(av.AudioTrack track) => AudioTrack(
    '${track.trackId}',
    track.mimetype,
    track.language,
    codec: track.mimetype,
    channelscount: track.channel,
    bitrate: track.bitrate,
  );
  static SubtitleTrack _textTrack(av.TextTrack track) => SubtitleTrack(
    '${track.trackId}',
    track.mimetype,
    track.language,
    codec: track.mimetype,
  );

  void _publish(PlayerState next) {
    if (_disposed) return;
    final previous = state;
    state = next;
    void emit<T>(StreamController<T> target, T before, T after) {
      if (before != after && !target.isClosed) target.add(after);
    }

    emit(playlistController, previous.playlist, next.playlist);
    emit(playingController, previous.playing, next.playing);
    emit(completedController, previous.completed, next.completed);
    emit(positionController, previous.position, next.position);
    emit(durationController, previous.duration, next.duration);
    emit(volumeController, previous.volume, next.volume);
    emit(rateController, previous.rate, next.rate);
    emit(bufferingController, previous.buffering, next.buffering);
    emit(
      bufferingPercentageController,
      previous.bufferingPercentage,
      next.bufferingPercentage,
    );
    emit(videoParamsController, previous.videoParams, next.videoParams);
    emit(widthController, previous.width, next.width);
    emit(heightController, previous.height, next.height);
    emit(trackController, previous.track, next.track);
    emit(tracksController, previous.tracks, next.tracks);
    emit(subtitleController, previous.subtitle, next.subtitle);
  }

  Future<void> _control(
    Future<void> Function(av.VideoPlayerController controller) action,
  ) {
    _checkAlive();
    return _serial(() async {
      _checkAlive();
      final controller = _controller;
      if (controller == null)
        throw StateError('Open media before controlling Tizen AVPlay.');
      await action(controller);
      if (identical(controller, _controller)) _receive(controller, _generation);
    });
  }

  @override
  Future<void> play() => _control((controller) => controller.play());
  @override
  Future<void> pause() {
    _checkAlive();
    return _serial(() async {
      _checkAlive();
      final controller = _controller;
      if (controller == null) return;
      await controller.pause();
      if (identical(controller, _controller)) _receive(controller, _generation);
    });
  }

  @override
  Future<void> playOrPause() => state.playing ? pause() : play();
  @override
  Future<void> seek(Duration duration) => _control((controller) async {
    final range = controller.value.duration;
    final target = duration < range.start
        ? range.start
        : (range.end > range.start && duration > range.end
              ? range.end
              : duration);
    await controller.seekTo(target);
  });
  @override
  Future<void> setVolume(double volume) {
    if (!volume.isFinite) throw ArgumentError.value(volume, 'volume');
    _checkAlive();
    final normalized = volume.clamp(0, 100).toDouble();
    if (_controller == null) {
      _publish(state.copyWith(volume: normalized));
      return Future.value();
    }
    return _control((controller) => controller.setVolume(normalized / 100));
  }

  @override
  Future<void> setRate(double rate) {
    if (!rate.isFinite || rate <= 0) throw ArgumentError.value(rate, 'rate');
    _checkAlive();
    if (_controller == null) {
      _publish(state.copyWith(rate: rate));
      return Future.value();
    }
    return _control((controller) => controller.setPlaybackSpeed(rate));
  }

  @override
  Future<void> setAudioTrack(AudioTrack track) => _control((controller) async {
    final selected = _audioTracks[track.id];
    if (track.uri || selected == null)
      throw UnsupportedError(
        'AVPlay requires an available embedded audio track ID.',
      );
    if (!await controller.setTrackSelection(selected))
      throw StateError('AVPlay rejected the audio track.');
    _publish(
      state.copyWith(track: state.track.copyWith(audio: _audioTrack(selected))),
    );
  });
  @override
  Future<void> setVideoTrack(VideoTrack track) => _control((controller) async {
    final selected = _videoTracks[track.id];
    if (selected == null)
      throw UnsupportedError('AVPlay requires an available video track ID.');
    if (!await controller.setTrackSelection(selected))
      throw StateError('AVPlay rejected the video track.');
    _publish(
      state.copyWith(track: state.track.copyWith(video: _videoTrack(selected))),
    );
  });
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) => _control((
    controller,
  ) async {
    if (track.id == 'no') {
      // AVPlay sends captions to Flutter; hiding those real captions disables
      // their presentation without claiming a nonexistent native track API.
      _subtitlesVisible.value = false;
      _publish(
        state.copyWith(
          track: state.track.copyWith(subtitle: SubtitleTrack.no()),
          subtitle: [],
        ),
      );
      return;
    }
    final selected = _textTracks[track.id];
    if (track.uri || track.data || selected == null)
      throw UnsupportedError(
        'AVPlay requires an available embedded subtitle track ID.',
      );
    if (!await controller.setTrackSelection(selected))
      throw StateError('AVPlay rejected the subtitle track.');
    _subtitlesVisible.value = true;
    _publish(
      state.copyWith(
        track: state.track.copyWith(subtitle: _textTrack(selected)),
      ),
    );
  });

  @override
  Future<void> stop() {
    _checkAlive();
    ++_generation;
    return _serial(() async {
      await _closeController();
      _publish(
        PlayerState(
          volume: state.volume,
          rate: state.rate,
          tracks: const Tracks(
            video: [],
            audio: [],
            subtitle: [SubtitleTrack('no', null, null)],
          ),
        ),
      );
    });
  }

  @override
  Future<void> dispose() {
    if (_disposeFuture != null) return _disposeFuture!;
    _disposed = true;
    ++_generation;
    return _disposeFuture = _serial(() async {
      await _closeController();
      videoController.dispose();
      _subtitlesVisible.dispose();
      await super.dispose();
    });
  }

  void setDisplayFit(BoxFit fit) {
    if (_fit == fit) return;
    _fit = fit;
    if (_controller?.value.isInitialized ?? false) {
      unawaited(
        _control((controller) => controller.setDisplayMode(_displayMode(fit)))
            .catchError((Object error) {
              if (!_disposed)
                logController.add(
                  PlayerLog(
                    prefix: 'tizen-avplay',
                    level: 'warn',
                    text: 'Display fit unavailable: ${_errorMessage(error)}',
                  ),
                );
            }),
      );
    }
  }

  static api.DisplayMode _displayMode(BoxFit fit) => switch (fit) {
    BoxFit.cover => api.DisplayMode.croppedFull,
    BoxFit.fill => api.DisplayMode.fullScreen,
    _ => api.DisplayMode.letterBox,
  };

  @override
  Future<int> get handle => Future.error(
    UnsupportedError('AVPlay has no mpv handle; use its SDK video surface.'),
  );
  Never _unsupported(String operation) => throw UnsupportedError(
    'Tizen AVPlay does not expose $operation through this adapter.',
  );
  @override
  Future<void> add(Media media) async => _unsupported('playlist editing');
  @override
  Future<void> remove(int index) async => _unsupported('playlist editing');
  @override
  Future<void> next() async => _unsupported('playlist traversal');
  @override
  Future<void> previous() async => _unsupported('playlist traversal');
  @override
  Future<void> jump(int index) async => _unsupported('playlist traversal');
  @override
  Future<void> move(int from, int to) async => _unsupported('playlist editing');
  @override
  Future<void> setPlaylistMode(PlaylistMode mode) async {
    if (mode != PlaylistMode.none) _unsupported('network looping');
  }

  @override
  Future<void> setPitch(double pitch) async => _unsupported('pitch control');
  @override
  Future<void> setShuffle(bool shuffle) async => _unsupported('shuffle');
  @override
  Future<void> setAudioDevice(AudioDevice device) async =>
      _unsupported('audio output selection');
  @override
  Future<Uint8List?> screenshot({
    String? format = 'image/jpeg',
    bool includeLibassSubtitles = false,
  }) async => _unsupported('screenshots');

  static Map<api.StreamingPropertyType, String> _streamingHeaders(
    Map<String, String>? headers,
  ) {
    final result = <api.StreamingPropertyType, String>{};
    for (final entry in (headers ?? <String, String>{}).entries) {
      switch (entry.key.toLowerCase()) {
        case 'cookie':
          result[api.StreamingPropertyType.cookie] = entry.value;
        case 'user-agent':
          result[api.StreamingPropertyType.userAgent] = entry.value;
        default:
          throw UnsupportedError(
            'Tizen AVPlay cannot forward HTTP header "${entry.key}".',
          );
      }
    }
    return result;
  }

  @visibleForTesting
  static av.VideoPlayerController controllerForMedia(Media media) {
    final uri = Uri.tryParse(media.uri);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return av.VideoPlayerController.network(
        media.uri,
        httpHeaders: media.httpHeaders ?? const {},
        streamingProperty: _streamingHeaders(media.httpHeaders),
        formatHint: uri.path.toLowerCase().endsWith('.mpd')
            ? api.VideoFormat.dash
            : null,
      );
    }
    if (uri?.scheme == 'file' || (uri != null && uri.scheme.isEmpty)) {
      return av.VideoPlayerController.file(
        uri?.scheme == 'file' ? File.fromUri(uri!) : File(media.uri),
      );
    }
    throw UnsupportedError(
      'Tizen AVPlay supports HTTP(S) or local file media.',
    );
  }

  static String _errorMessage(Object error) => error is PlatformException
      ? (error.message ?? error.code)
      : error.toString();
}

class _TizenVideoSurface extends StatefulWidget {
  const _TizenVideoSurface({
    required this.backend,
    required this.fit,
    required this.fill,
  });
  final TizenAvplayPlatformPlayer backend;
  final BoxFit fit;
  final Color fill;
  @override
  State<_TizenVideoSurface> createState() => _TizenVideoSurfaceState();
}

class _TizenVideoSurfaceState extends State<_TizenVideoSurface> {
  @override
  void initState() {
    super.initState();
    widget.backend.setDisplayFit(widget.fit);
  }

  @override
  void didUpdateWidget(_TizenVideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.backend.setDisplayFit(widget.fit);
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: widget.fill,
    child: AnimatedBuilder(
      animation: Listenable.merge([
        widget.backend.videoController,
        widget.backend._subtitlesVisible,
      ]),
      builder: (context, _) {
        final controller = widget.backend.videoController.value;
        if (controller == null) return const SizedBox.expand();
        return ValueListenableBuilder<av.VideoPlayerValue>(
          valueListenable: controller,
          builder: (context, value, _) => Stack(
            fit: StackFit.expand,
            children: [
              av.VideoPlayer(controller),
              if (widget.backend._subtitlesVisible.value)
                IgnorePointer(
                  child: av.ClosedCaption(captions: value.captions),
                ),
            ],
          ),
        );
      },
    ),
  );
}
