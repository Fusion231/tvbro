import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/diagnostics_log.dart';
import '../data/net.dart' show isTransientNetworkError;
import '../data/provider_request_gate.dart';
import '../data/provider_stream_gate.dart';
import '../sources/source.dart';
import 'dvr_models.dart';
import 'dvr_retry.dart';
import 'hls_playlist.dart';
import 'mpeg_ts_segmenter.dart';
import 'ts_segment_worker.dart';

export 'dvr_models.dart';
export 'dvr_retry.dart';

/// A viewer's local live session. Capture continues if a recording owns it after
/// the viewer detaches. All positions are on one absolute capture timeline.
class DvrSession {
  DvrSession._(this._capture);
  final _Capture _capture;

  String get id => _capture.id;
  String get channelName => _capture.channelName;
  String? get sourceId => _capture.sourceId;
  String? get channelId => _capture.channelId;
  String? get recordingId => _capture.recording?.value.id;
  DvrSnapshot get snapshot => _capture.snapshot;
  Future<void> get ready => _capture.ready.future;
  Future<void> get done => _capture.finished.future;
  Duration get livePosition =>
      _capture.segments.isEmpty ? Duration.zero : _capture.segments.last.start;

  Duration playbackOriginFor(Duration absolutePosition) =>
      _capture.segmentFor(absolutePosition).start;

  StreamInfo playbackAt(Duration absolutePosition) =>
      _capture.playbackAt(absolutePosition);

  StreamInfo get playbackStream => playbackAt(livePosition);
}

/// Device-local recording and bounded timeshift. No provider locator/header is
/// persisted or sent to the native foreground-service notification.
class DvrService extends ChangeNotifier {
  DvrService({
    required Directory directory,
    DvrSettings settings = const DvrSettings(),
    HttpClient Function()? httpClientFactory,
    DvrRetryPolicy retryPolicy = const DvrRetryPolicy(),
    // Public parameter names differ from the private backing fields.
    // ignore: prefer_initializing_formals
  }) : _directory = directory,
       // ignore: prefer_initializing_formals
       _settings = settings,
       // ignore: prefer_initializing_formals
       _retryPolicy = retryPolicy,
       _httpClientFactory = httpClientFactory ?? HttpClient.new;

  DvrService._()
    : _directory = null,
      _settings = const DvrSettings(),
      _retryPolicy = const DvrRetryPolicy(),
      _httpClientFactory = HttpClient.new;

  static final DvrService instance = DvrService._();
  static const _foreground = MethodChannel('tvbro/dvr_capture');
  final HttpClient Function() _httpClientFactory;
  final DvrRetryPolicy _retryPolicy;
  Directory? _directory;
  late Directory _buffersDirectory;
  late Directory _recordingsDirectory;
  DvrSettings _settings;
  Future<void>? _initializing;
  Future<void> _operations = Future.value();
  final Map<String, _Capture> _captures = {};
  final Map<String, _RecordingSink> _saved = {};
  HttpServer? _server;
  DvrSession? _activeSession;
  int _viewerGeneration = 0;
  bool _closed = false;
  bool _nativeProtection = false;
  bool _notificationSuppressed = false;
  String? _startingRecordingId;
  Completer<void>? _cancelRecordingStart;

  DvrSettings get settings => _settings;
  DvrSession? get activeSession => _activeSession;
  List<DvrRecording> get recordings => List.unmodifiable(
    _saved.values.map((r) => r.value).toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt)),
  );
  DvrRecording? get activeRecording {
    for (final record in _saved.values) {
      if (record.value.status == DvrRecordingStatus.recording) {
        return record.value;
      }
    }
    return null;
  }

  int get recordingBytes =>
      _saved.values.fold(0, (sum, r) => sum + r.value.bytes);
  int get recordingQuotaBytes => _settings.maxRecordingsBytes;
  bool get notificationSuppressed => _notificationSuppressed;

  Future<void> ensureInitialized() {
    if (_closed) throw const DvrException('Local recording storage is closed.');
    return _initializing ??= _initialize();
  }

  Future<void> _initialize() async {
    _settings.validate();
    final usePlatformDirectory = _directory == null;
    _directory ??= Directory(
      p.join((await getApplicationSupportDirectory()).path, 'tvbro_dvr'),
    );
    await _directory!.create(recursive: true);
    _buffersDirectory = Directory(p.join(_directory!.path, 'buffers'));
    _recordingsDirectory = Directory(p.join(_directory!.path, 'recordings'));
    await _buffersDirectory.create(recursive: true);
    await _recordingsDirectory.create(recursive: true);
    final config = await _readJson(
      File(p.join(_directory!.path, 'settings.json')),
    );
    if (config != null) {
      try {
        final loaded = DvrSettings.fromJson(config);
        loaded.validate();
        _settings = loaded;
      } catch (_) {
        DiagnosticsLog.instance.add('dvr', 'settings_recovery=defaults');
      }
    }
    // Buffer directories contain only disposable, app-generated IDs. Never
    // follow links or delete an arbitrary path read from a manifest.
    await for (final entry in _buffersDirectory.list(followLinks: false)) {
      if (entry is Directory && _safeId(p.basename(entry.path))) {
        await entry.delete(recursive: true);
      }
    }
    await for (final entry in _recordingsDirectory.list(followLinks: false)) {
      if (entry is! Directory || !_safeId(p.basename(entry.path))) continue;
      final sink = await _RecordingSink.recover(this, entry);
      if (sink != null) _saved[sink.value.id] = sink;
    }
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(
      (request) => unawaited(_serve(request)),
      onError: (Object _) {
        DiagnosticsLog.instance.add('dvr', 'local_server_error');
      },
    );
    if (Platform.isAndroid && usePlatformDirectory) {
      _nativeProtection = true;
      _foreground.setMethodCallHandler(_handleForegroundCall);
    }
    _publish();
  }

  Future<void> updateSettings(DvrSettings value) => _queue(() async {
    await ensureInitialized();
    value.validate();
    if (activeRecording != null && recordingBytes > value.maxRecordingsBytes) {
      throw const DvrException(
        'Stop recording before reducing its storage limit.',
      );
    }
    _settings = value;
    await _atomicText(
      File(p.join(_directory!.path, 'settings.json')),
      jsonEncode(value.toJson()),
    );
    _publish();
  });

  Future<DvrSession> startTimeshift(
    StreamInfo stream, {
    required String channelName,
    String? sourceId,
    String? channelId,
    Future<StreamInfo> Function()? resolveAgain,
  }) {
    final generation = ++_viewerGeneration;
    final old = _activeSession?._capture;
    if (old != null &&
        old.recording == null &&
        !old.matches(stream, sourceId: sourceId, channelId: channelId)) {
      old.cancel();
    }
    final prepared = _queue<DvrSession>(() async {
      await ensureInitialized();
      if (generation != _viewerGeneration) {
        throw const DvrException('Local timeshift was cancelled.');
      }
      final previous = _activeSession?._capture;
      if (previous != null &&
          previous.matches(stream, sourceId: sourceId, channelId: channelId) &&
          previous.isRunning) {
        if (previous.recording == null && resolveAgain != null) {
          previous.resolveAgain = resolveAgain;
        }
        return _activeSession!;
      }
      _activeSession = null;
      if (previous != null) {
        previous.viewer = false;
        if (previous.recording == null) await _releaseCapture(previous);
      }
      final capture = await _findOrCreate(
        stream,
        channelName: channelName,
        sourceId: sourceId,
        channelId: channelId,
        resolveAgain: resolveAgain,
      );
      capture.viewer = true;
      final session = DvrSession._(capture);
      _activeSession = session;
      _publish();
      return session;
    });
    // Mutations stay serialized, but a provider's first segment must not hold
    // the queue: Android's recording Stop callback needs a timely ACK even if
    // a different channel is still waiting for network data.
    return prepared.then((session) async {
      try {
        await session.ready;
        if (generation != _viewerGeneration) {
          throw const DvrException('Local timeshift was cancelled.');
        }
        return session;
      } catch (_) {
        await _queue(() async {
          if (generation != _viewerGeneration ||
              !identical(_activeSession, session)) {
            return;
          }
          _activeSession = null;
          final capture = session._capture;
          capture.viewer = false;
          if (capture.recording == null) await _releaseCapture(capture);
          _publish();
        });
        rethrow;
      }
    });
  }

  Future<void> stopTimeshift({DvrSession? session}) {
    if (session != null && !identical(session, _activeSession)) {
      return Future.value();
    }
    ++_viewerGeneration;
    final capture = _activeSession?._capture;
    if (capture?.recording == null) capture?.cancel();
    return _queue(() async {
      final current = _activeSession;
      if (session != null && !identical(session, current)) return;
      _activeSession = null;
      if (current != null) {
        current._capture.viewer = false;
        if (current._capture.recording == null) {
          await _releaseCapture(current._capture);
        }
      }
      _publish();
    });
  }

  /// Reattach a recorded channel without resolving or opening a second provider
  /// connection. The recording owns its original transient locator internally.
  Future<DvrSession> attachRecording(String recordingId) {
    final generation = ++_viewerGeneration;
    return _queue(() async {
      await ensureInitialized();
      _Capture? capture;
      for (final candidate in _captures.values) {
        if (candidate.recording?.value.id == recordingId &&
            candidate.isRunning) {
          capture = candidate;
          break;
        }
      }
      if (capture == null) {
        throw const DvrException(
          'This recording is no longer capturing live TV.',
        );
      }
      final previous = _activeSession?._capture;
      if (previous != null && previous != capture) {
        previous.viewer = false;
        if (previous.recording == null) await _releaseCapture(previous);
      }
      capture.viewer = true;
      final session = DvrSession._(capture);
      _activeSession = session;
      _publish();
      await capture.ready.future;
      if (generation != _viewerGeneration) {
        throw const DvrException('Local timeshift was cancelled.');
      }
      return session;
    });
  }

  Future<DvrRecording> startRecording(
    StreamInfo stream, {
    required String channelName,
    String? sourceId,
    String? channelId,
    String? programmeTitle,
    bool includeBuffered = false,
    String? scheduleId,
    Future<StreamInfo> Function()? resolveAgain,
  }) => _queue(() async {
    await ensureInitialized();
    _validateStream(stream);
    if (activeRecording != null) {
      throw const DvrException(
        'A recording is already running on this device.',
      );
    }
    if (recordingBytes >= recordingQuotaBytes) {
      throw const DvrException(
        'Recording storage is full. Delete a saved recording first.',
      );
    }
    final id = _randomId();
    final directory = Directory(p.join(_recordingsDirectory.path, id));
    await directory.create();
    final sink = _RecordingSink(
      this,
      directory,
      DvrRecording(
        id: id,
        channelName: channelName,
        programmeTitle: programmeTitle,
        sourceId: sourceId,
        channelId: channelId,
        startedAt: DateTime.now(),
        status: DvrRecordingStatus.recording,
        scheduleId: scheduleId,
      ),
    );
    _saved[id] = sink;
    try {
      await sink.persist();
    } catch (error) {
      sink.value = sink.value.copyWith(
        status: DvrRecordingStatus.failed,
        endedAt: DateTime.now(),
        error: _safeError(error),
      );
      _publish();
      throw DvrException(_safeError(error));
    }
    final cancelled = Completer<void>();
    _startingRecordingId = id;
    _cancelRecordingStart = cancelled;
    _publish();
    Future<T> duringStart<T>(Future<T> future) => Future.any([
      future,
      cancelled.future.then<T>(
        (_) => throw const DvrException(
          'Recording was cancelled before capture was ready.',
        ),
      ),
    ]);
    _Capture? capture;
    try {
      if (_nativeProtection) {
        Object? started;
        try {
          started = await duringStart(
            _foreground
                .invokeMethod<Object?>('start', {
                  'id': id,
                  'channelName': channelName,
                })
                .timeout(const Duration(seconds: 120)),
          );
        } on DvrException {
          rethrow;
        } catch (_) {
          throw const DvrException(
            'Android could not protect the background recording.',
          );
        }
        if (started is! Map || started['notificationVisible'] is! bool) {
          throw const DvrException(
            'Android could not protect the background recording.',
          );
        }
        _notificationSuppressed = started['notificationVisible'] != true;
      }
      capture = await _findOrCreate(
        stream,
        channelName: channelName,
        sourceId: sourceId,
        channelId: channelId,
        resolveAgain: resolveAgain,
      );
      if (resolveAgain != null) capture.resolveAgain = resolveAgain;
      // Used when the first Record action has just created its viewer buffer:
      // queue that complete startup prefix before attaching future segments.
      // Queueing all copies synchronously preserves order against the capture.
      final startup = includeBuffered
          ? capture.segments
                .map((segment) => sink.append(segment, capture!.directory))
                .toList()
          : <Future<void>>[];
      capture.recording = sink;
      await Future.wait(startup);
      _publish();
      await duringStart(capture.ready.future);
      return sink.value;
    } catch (error) {
      if (capture != null) {
        capture.recording = null;
        if (!capture.viewer) await _releaseCapture(capture);
      }
      await sink.close(DvrRecordingStatus.failed, error: _safeError(error));
      await _stopProtection(id);
      _publish();
      throw DvrException(_safeError(error));
    } finally {
      if (_startingRecordingId == id) {
        _startingRecordingId = null;
        _cancelRecordingStart = null;
      }
    }
  });

  Future<void> stopRecording(String id) {
    _cancelStartingRecording(id);
    return _queue(() => _finishRecording(id, DvrRecordingStatus.completed));
  }

  void _cancelStartingRecording(String id) {
    if (_startingRecordingId == id &&
        _cancelRecordingStart?.isCompleted == false) {
      _cancelRecordingStart!.complete();
      unawaited(_stopProtection(id));
    }
  }

  Future<void> _finishRecording(
    String id,
    DvrRecordingStatus status, {
    String? error,
  }) async {
    final sink = _saved[id];
    if (sink == null || sink.value.status != DvrRecordingStatus.recording) {
      return;
    }
    _Capture? owner;
    for (final capture in _captures.values) {
      if (identical(capture.recording, sink)) {
        owner = capture;
        break;
      }
    }
    if (owner != null) {
      if (!owner.viewer) {
        // Stop the network before closing its sink so the final packet-aligned
        // TS tail can be committed. run() completion never waits on this method.
        owner.cancel();
        await owner.finished.future;
      }
      owner.recording = null;
    }
    await sink.close(status, error: error);
    await _stopProtection(id);
    if (owner != null && !owner.viewer) await _releaseCapture(owner);
    _publish();
  }

  Future<void> deleteRecording(String id) => _queue(() async {
    await ensureInitialized();
    final sink = _saved[id];
    if (sink == null) return;
    if (sink.value.status == DvrRecordingStatus.recording) {
      throw const DvrException('Stop this recording before deleting it.');
    }
    if (sink.readers > 0) {
      throw const DvrException(
        'Close playback of this recording before deleting it.',
      );
    }
    await sink.directory.delete(recursive: true);
    _saved.remove(id);
    _publish();
  });

  Future<StreamInfo> recordingPlayback(DvrRecording recording) async {
    await ensureInitialized();
    final sink = _saved[recording.id];
    if (sink?.value.status == DvrRecordingStatus.recording) {
      for (final capture in _captures.values) {
        if (identical(capture.recording, sink) && capture.isRunning) {
          await capture.ready.future;
          return capture.playbackAt(
            capture.segments.isEmpty
                ? Duration.zero
                : capture.segments.last.start,
          );
        }
      }
    }
    if (sink == null ||
        !sink.value.hasMedia ||
        sink.value.status == DvrRecordingStatus.recording) {
      throw const DvrException(
        'This recording has no playable saved media yet.',
      );
    }
    return StreamInfo(
      url: _url('recordings/${sink.token}/index.m3u8'),
      isLive: false,
    );
  }

  Future<_Capture> _findOrCreate(
    StreamInfo stream, {
    required String channelName,
    String? sourceId,
    String? channelId,
    Future<StreamInfo> Function()? resolveAgain,
  }) async {
    _validateStream(stream);
    for (final capture in _captures.values) {
      if (capture.matches(stream, sourceId: sourceId, channelId: channelId) &&
          capture.isRunning) {
        capture.resolveAgain ??= resolveAgain;
        return capture;
      }
    }
    final id = _randomId();
    final directory = Directory(p.join(_buffersDirectory.path, id));
    await directory.create();
    final capture = _Capture(
      this,
      id,
      directory,
      stream,
      channelName,
      sourceId,
      channelId,
      _httpClientFactory(),
      resolveAgain,
    );
    _captures[id] = capture;
    // Register both completion/error observers before the network starts.
    unawaited(capture.ready.future.then<void>((_) {}, onError: (Object _) {}));
    unawaited(capture.finished.future.then((_) => _captureFinished(capture)));
    unawaited(capture.run());
    return capture;
  }

  Future<void> _captureFinished(_Capture capture) async {
    try {
      final recording = capture.recording;
      if (recording != null && capture.state == DvrCaptureState.failed) {
        capture.recording = null;
        try {
          await recording.close(
            DvrRecordingStatus.interrupted,
            error: capture.error ?? 'The local capture stopped unexpectedly.',
          );
        } finally {
          await _stopProtection(recording.value.id);
        }
      } else if (recording != null && !capture.cancelled) {
        capture.recording = null;
        try {
          await recording.close(DvrRecordingStatus.completed);
        } finally {
          await _stopProtection(recording.value.id);
        }
      }
    } catch (_) {
      DiagnosticsLog.instance.add('dvr', 'recording_finalize_storage_error');
    } finally {
      if (!capture.viewer && capture.recording == null) {
        _captures.remove(capture.id);
        await capture.disposeFiles();
      }
      _publish();
    }
  }

  Future<void> _releaseCapture(_Capture capture) async {
    capture.cancel();
    await capture.finished.future;
    _captures.remove(capture.id);
    await capture.disposeFiles();
  }

  Future<void> _handleForegroundCall(MethodCall call) async {
    if (call.method != 'stopRequested' && call.method != 'protectionLost') {
      return;
    }
    final args = call.arguments;
    if (args is! Map || args['id'] is! String) return;
    final id = args['id'] as String;
    _cancelStartingRecording(id);
    final notification =
        call.method == 'stopRequested' && args['reason'] == 'notification';
    await _queue(
      () => _finishRecording(
        id,
        notification
            ? DvrRecordingStatus.completed
            : DvrRecordingStatus.interrupted,
        error: notification
            ? null
            : 'Android stopped background recording protection.',
      ),
    );
  }

  Future<void> _stopProtection(String id) async {
    if (!_nativeProtection) return;
    try {
      await _foreground
          .invokeMethod<void>('stop', {'id': id})
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      DiagnosticsLog.instance.add('dvr', 'foreground_stop_failed');
    }
  }

  String _url(String path) => 'http://127.0.0.1:${_server!.port}/$path';

  Future<void> _serve(HttpRequest request) async {
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      final parts = request.uri.pathSegments;
      if (parts.length < 3 ||
          parts.any((part) => part == '..' || part.contains('/'))) {
        request.response.statusCode = HttpStatus.notFound;
        return;
      }
      if (parts[0] == 'live') {
        _Capture? capture;
        for (final value in _captures.values) {
          if (value.token == parts[1]) capture = value;
        }
        if (capture != null) {
          await capture.serve(request, parts.sublist(2));
          return;
        }
      } else if (parts[0] == 'recordings' && parts.length == 3) {
        for (final sink in _saved.values) {
          if (sink.token == parts[1]) {
            await sink.serve(request, parts[2]);
            return;
          }
        }
      }
      request.response.statusCode = HttpStatus.notFound;
    } catch (_) {
      // Playback clients routinely cancel a range request during a seek.
      try {
        request.response.statusCode = HttpStatus.internalServerError;
      } catch (_) {}
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<T> _queue<T>(Future<T> Function() action) {
    final result = _operations.then((_) => action());
    _operations = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void _publish() {
    if (!_closed) notifyListeners();
  }

  /// Explicit asynchronous shutdown for tests/application teardown. Normal
  /// player-route disposal only detaches its timeshift viewer.
  Future<void> close() async {
    if (_closed) return;
    ++_viewerGeneration;
    if (_startingRecordingId != null) {
      _cancelStartingRecording(_startingRecordingId!);
    }
    for (final capture in _captures.values) {
      capture.cancel();
    }
    await _operations;
    for (final capture in _captures.values.toList()) {
      await capture.finished.future;
      final recording = capture.recording;
      capture.recording = null;
      if (recording != null) {
        await recording.close(
          DvrRecordingStatus.interrupted,
          error: 'The app closed while this recording was running.',
        );
        await _stopProtection(recording.value.id);
      }
      await capture.disposeFiles();
    }
    _captures.clear();
    _activeSession = null;
    await _server?.close(force: true);
    _closed = true;
    if (_nativeProtection) _foreground.setMethodCallHandler(null);
    super.dispose();
  }
}

void _validateStream(StreamInfo stream) {
  Uri? uri;
  try {
    uri = Uri.tryParse(stream.url);
  } catch (_) {}
  if (!stream.isLive ||
      uri == null ||
      uri.host.isEmpty ||
      !{'http', 'https'}.contains(uri.scheme)) {
    throw const DvrException(
      'Local recording supports live HTTP HLS and MPEG-TS streams.',
    );
  }
}

String _safeError(Object error) {
  if (error is ProviderStreamLimitReached) return error.toString();
  if (error is ProviderRequestBlocked) {
    return 'The provider paused capture (HTTP ${error.status}). Wait before trying again.';
  }
  if (error is DvrException) return error.message;
  if (error is FileSystemException) {
    return 'Local storage could not be written. Check available disk space.';
  }
  if (error is TimeoutException) {
    return 'The provider stopped sending media in time.';
  }
  return 'The stream could not be captured locally. Check the connection and provider.';
}

class _CaptureHttpFailure extends DvrException {
  const _CaptureHttpFailure(this.status)
    : super('The provider refused capture (HTTP $status).');

  final int status;
  bool get transient =>
      status == 408 ||
      status == 500 ||
      status == 502 ||
      status == 503 ||
      status == 504;
}

class _TransientCaptureFailure extends DvrException {
  const _TransientCaptureFailure(super.message);
}

String _randomId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

bool _safeId(String value) => RegExp(r'^[a-f0-9]{32}$').hasMatch(value);

bool _safeFile(String value) =>
    RegExp(r'^(segment-[0-9]+\.(ts|m4s)|init-[0-9]+\.mp4|key-[0-9]+\.bin)$')
        .hasMatch(value);

Future<Map<String, dynamic>?> _readJson(File file) async {
  for (final candidate in [file, File('${file.path}.old')]) {
    try {
      if (await candidate.length() > 8 * 1024 * 1024) continue;
      final value = jsonDecode(await candidate.readAsString());
      if (value is Map<String, dynamic>) return value;
    } catch (_) {}
  }
  return null;
}

Future<void> _atomicText(File file, String value) async {
  final temporary = File('${file.path}.new');
  final backup = File('${file.path}.old');
  await temporary.writeAsString(value, flush: true);
  if (await backup.exists()) await backup.delete();
  if (await file.exists()) await file.rename(backup.path);
  await temporary.rename(file.path);
  if (await backup.exists()) await backup.delete();
}

class _MediaSegment {
  const _MediaSegment({
    required this.sequence,
    required this.filename,
    required this.start,
    required this.duration,
    required this.bytes,
    required this.discontinuitySequence,
    this.discontinuity = false,
    this.map,
    this.key,
    this.iv,
  });

  final int sequence;
  final String filename;
  final Duration start;
  final Duration duration;
  final int bytes;
  final int discontinuitySequence;
  final bool discontinuity;
  final String? map;
  final String? key;
  final String? iv;
  Duration get end => start + duration;
  Iterable<String> get files sync* {
    yield filename;
    if (map != null) yield map!;
    if (key != null) yield key!;
  }

  Map<String, Object?> toJson() => {
    'sequence': sequence,
    'filename': filename,
    'startUs': start.inMicroseconds,
    'durationUs': duration.inMicroseconds,
    'bytes': bytes,
    'discontinuitySequence': discontinuitySequence,
    'discontinuity': discontinuity,
    'map': map,
    'key': key,
    'iv': iv,
  };

  factory _MediaSegment.fromJson(Map<String, dynamic> json) {
    final segment = _MediaSegment(
      sequence: (json['sequence'] as num).toInt(),
      filename: json['filename'] as String,
      start: Duration(microseconds: (json['startUs'] as num).toInt()),
      duration: Duration(microseconds: (json['durationUs'] as num).toInt()),
      bytes: (json['bytes'] as num).toInt(),
      discontinuitySequence:
          (json['discontinuitySequence'] as num?)?.toInt() ?? 0,
      discontinuity: json['discontinuity'] == true,
      map: json['map'] as String?,
      key: json['key'] as String?,
      iv: json['iv'] as String?,
    );
    if (segment.files.any((file) => !_safeFile(file)) ||
        segment.sequence < 0 ||
        segment.bytes <= 0 ||
        segment.duration <= Duration.zero ||
        segment.start < Duration.zero ||
        (segment.iv != null &&
            !RegExp(r'^0x[a-fA-F0-9]{32}$').hasMatch(segment.iv!))) {
      throw const DvrException('Saved recording metadata is damaged.');
    }
    return segment;
  }
}

class _Asset {
  const _Asset(this.filename, this.bytes);
  final String filename;
  final int bytes;
}

class _PlaybackCursor {
  _PlaybackCursor(this.firstSequence, this.currentSequence);
  final int firstSequence;
  int currentSequence;
  DateTime lastSeen = DateTime.now();
}

class _OpenResponse {
  const _OpenResponse(this.response, this.uri);
  final HttpClientResponse response;
  final Uri uri;
}

class _Capture {
  _Capture(
    this.service,
    this.id,
    this.directory,
    this.stream,
    this.channelName,
    this.sourceId,
    this.channelId,
    this.client,
    this.resolveAgain,
  ) {
    client.connectionTimeout = const Duration(seconds: 12);
    client.autoUncompress = true;
  }

  final DvrService service;
  final String id;
  final String token = _randomId();
  final Directory directory;
  StreamInfo stream;
  final String channelName;
  final String? sourceId;
  final String? channelId;
  HttpClient client;
  Future<StreamInfo> Function()? resolveAgain;
  final Completer<void> ready = Completer<void>();
  final Completer<void> finished = Completer<void>();
  final Completer<void> _cancellation = Completer<void>();
  final List<_MediaSegment> segments = [];
  final Map<String, _Asset> _assets = {};
  final Map<String, String> _remoteAssets = {};
  final Map<int, DateTime> _leases = {};
  final Map<String, _PlaybackCursor> _cursors = {};
  final Map<String, int> _readers = {};
  final Set<String> _pendingAssets = {};
  HttpClientRequest? _request;
  _RecordingSink? recording;
  DvrCaptureState state = DvrCaptureState.starting;
  String? error;
  bool viewer = false;
  bool cancelled = false;
  int _diskBytes = 0;
  int _pendingBytes = 0;
  int _nextSequence = 0;
  int _nextAsset = 0;
  int _discontinuities = 0;
  Duration _end = Duration.zero;
  TsSegmentWorker? _ts;
  int _targetDurationSeconds = 8;
  bool _deleteWhenIdle = false;
  Future<void>? _fileDisposal;
  int? _previousUpstreamSequence;
  int _retryAttempt = 0;
  DateTime? _recoveryStarted;
  bool _pendingDiscontinuity = false;
  bool _reopened = false;

  bool get isRunning => !cancelled && !finished.isCompleted;
  DvrSnapshot get snapshot => DvrSnapshot(
    bufferStart: segments.isEmpty ? _end : segments.first.start,
    bufferEnd: _end,
    bytes: _diskBytes + _pendingBytes,
    state: state,
    error: error,
    reconnecting: _recoveryStarted != null,
    retryAttempt: _retryAttempt,
  );

  bool matches(StreamInfo other, {String? sourceId, String? channelId}) {
    if (sourceId != null &&
        this.sourceId != null &&
        sourceId != this.sourceId) {
      return false;
    }
    if (sourceId != null &&
        channelId != null &&
        this.sourceId != null &&
        this.channelId != null) {
      return sourceId == this.sourceId && channelId == this.channelId;
    }
    return stream.url == other.url && mapEquals(stream.headers, other.headers);
  }

  _MediaSegment segmentFor(Duration position) {
    if (segments.isEmpty) {
      throw const DvrException('The local buffer is not ready yet.');
    }
    for (final segment in segments.reversed) {
      if (position >= segment.start) return segment;
    }
    return segments.first;
  }

  StreamInfo playbackAt(Duration position) {
    final selected = segmentFor(position);
    final cursorId = _randomId();
    // Abandoned reload cursors are small metadata; never retain them forever.
    _cursors.removeWhere(
      (_, value) =>
          DateTime.now().difference(value.lastSeen) >
          const Duration(minutes: 2),
    );
    if (_cursors.length >= 16) _cursors.remove(_cursors.keys.first);
    _cursors[cursorId] = _PlaybackCursor(selected.sequence, selected.sequence);
    return StreamInfo(
      url: service._url('live/$token/$cursorId/index.m3u8'),
      isLive: true,
    );
  }

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    _cancellation.complete();
    _request?.abort();
    client.close(force: true);
  }

  Future<T> _wait<T>(Future<T> future) => Future.any([
    future,
    _cancellation.future.then<T>((_) => throw const _CaptureCancelled()),
  ]);

  Future<void> run() async {
    try {
      ProviderStreamGate.instance.reserve(stream, owner: this);
      while (!cancelled) {
        try {
          await _consume();
          break;
        } catch (failure) {
          if (cancelled || failure is _CaptureCancelled) rethrow;
          if (failure is ProviderRequestBlocked) rethrow;
          final transient =
              isTransientNetworkError(failure) ||
              failure is _TransientCaptureFailure ||
              (failure is _CaptureHttpFailure && failure.transient);
          if (!transient) rethrow;
          // Retain only the packet-aligned TS prefix and discard a partially
          // downloaded HLS segment. Local numbering never resets on reconnect.
          if (_ts != null) {
            await _flushTs();
            _ts = null;
            _markMediaGap();
          }
          final policy = service._retryPolicy;
          _recoveryStarted ??= DateTime.now();
          if (++_retryAttempt > policy.maxRetries ||
              DateTime.now().difference(_recoveryStarted!) >=
                  policy.maxRecovery) {
            throw const DvrException(
              'The connection did not recover in time. Complete saved segments were kept.',
            );
          }
          _pendingAssets.clear();
          _pendingDiscontinuity = _nextSequence > 0;
          _reopened = true;
          error =
              'Connection interrupted; retrying ($_retryAttempt/${policy.maxRetries}).';
          service._publish();
          DiagnosticsLog.instance.add(
            'dvr',
            'capture_retry attempt=$_retryAttempt',
          );
          await _wait(Future<void>.delayed(policy.delayFor(_retryAttempt)));
          if (resolveAgain != null &&
              (_retryAttempt == 1 || _retryAttempt.isEven)) {
            try {
              final refreshed = await _wait(
                resolveAgain!().timeout(const Duration(seconds: 20)),
              );
              _validateStream(refreshed);
              final updated = refreshed.withProviderAccount(
                refreshed.providerAccount ?? stream.providerAccount,
              );
              ProviderStreamGate.instance.reserve(updated, owner: this);
              stream = updated;
            } catch (failure) {
              if (!isTransientNetworkError(failure)) rethrow;
            }
          }
          _request?.abort();
          client.close(force: true);
          client = service._httpClientFactory()
            ..connectionTimeout = const Duration(seconds: 12)
            ..autoUncompress = true;
        }
      }
    } catch (failure) {
      if (cancelled || failure is _CaptureCancelled) {
        try {
          await _flushTs();
        } catch (_) {}
      } else {
        error = _safeError(failure);
        state = DvrCaptureState.failed;
        DiagnosticsLog.instance.add('dvr', 'capture_failed reason=$error');
      }
    } finally {
      try {
        await _ts?.close();
      } finally {
        _ts = null;
        try {
          client.close(force: true);
        } finally {
          ProviderStreamGate.instance.release(this);
        }
        _recoveryStarted = null;
        if (state != DvrCaptureState.failed) state = DvrCaptureState.stopped;
        if (!ready.isCompleted) {
          ready.completeError(
            DvrException(
              error ?? 'The stream stopped before a local segment was ready.',
            ),
          );
        }
        finished.complete();
        service._publish();
      }
    }
  }

  Future<void> _consume() async {
    final opened = await _open(Uri.parse(stream.url));
    final mime = opened.response.headers.contentType?.mimeType ?? '';
    final iterator = StreamIterator<List<int>>(
      opened.response.timeout(const Duration(seconds: 20)),
    );
    try {
      if (!await _wait(iterator.moveNext())) {
        throw const _TransientCaptureFailure(
          'The provider returned an empty media stream.',
        );
      }
      final first = iterator.current;
      final prefix = utf8
          .decode(first.take(64).toList(), allowMalformed: true)
          .trimLeft();
      final hls =
          mime.contains('mpegurl') ||
          prefix.startsWith('#EXTM3U') ||
          prefix.startsWith('\uFEFF#EXTM3U') ||
          opened.uri.path.toLowerCase().endsWith('.m3u8');
      if (hls) {
        final bytes = BytesBuilder(copy: false)..add(first);
        while (await _wait(iterator.moveNext())) {
          bytes.add(iterator.current);
          if (bytes.length > 2 * 1024 * 1024) {
            throw const DvrException(
              'The HLS playlist is too large to record.',
            );
          }
        }
        await _hls(utf8.decode(bytes.takeBytes()), opened.uri);
      } else {
        _ts = await TsSegmentWorker.start(
          maximumSegmentBytes: min(
            32 * 1024 * 1024,
            service.settings.maxBufferBytes,
          ),
        );
        await _addTs(first);
        while (await _wait(iterator.moveNext())) {
          await _addTs(iterator.current);
        }
        await _flushTs();
        _markMediaGap();
        _ts = null;
        // Live TS providers commonly signal a dropped connection as clean
        // EOF. A finite HLS ENDLIST above still closes capture normally.
        throw const _TransientCaptureFailure(
          'The live MPEG-TS connection ended.',
        );
      }
    } finally {
      await iterator.cancel();
    }
  }

  void _markMediaGap() {
    final sink = recording;
    if (sink != null) sink.value = sink.value.copyWith(hasGaps: true);
  }

  Future<void> _addTs(List<int> chunk) async {
    if (cancelled) throw const _CaptureCancelled();
    for (final segment in await _ts!.add(chunk)) {
      await _writeTs(segment);
    }
  }

  Future<void> _flushTs() async {
    final worker = _ts;
    _ts = null;
    if (worker == null) return;
    try {
      for (final tail in await worker.finish()) {
        await _writeTs(tail);
      }
    } finally {
      await worker.close();
    }
  }

  Future<void> _writeTs(TsSegment ts) async {
    await _makeRoom(ts.bytes.length, end: _end + ts.duration);
    final name = 'segment-$_nextSequence.ts';
    final file = File(p.join(directory.path, '$name.partial'));
    await file.writeAsBytes(ts.bytes, flush: true);
    await file.rename(p.join(directory.path, name));
    await _commit(
      name,
      ts.bytes.length,
      ts.duration,
      discontinuity: ts.discontinuity || _pendingDiscontinuity,
    );
  }

  Future<void> _hls(String body, Uri uri) async {
    var playlist = HlsPlaylist.parse(body, uri);
    var masterDepth = 0;
    while (playlist.variant != null) {
      if (++masterDepth > 3) {
        throw const DvrException('The HLS master playlist is recursive.');
      }
      final opened = await _open(playlist.variant!);
      uri = opened.uri;
      playlist = HlsPlaylist.parse(await _readPlaylist(opened.response), uri);
    }
    if (_nextSequence > 0 &&
        playlist.targetDuration.inSeconds != _targetDurationSeconds) {
      throw const DvrException(
        'The provider changed its HLS target duration while recording.',
      );
    }
    _targetDurationSeconds = playlist.targetDuration.inSeconds;
    if (_reopened &&
        _previousUpstreamSequence != null &&
        playlist.segments.isNotEmpty &&
        playlist.segments.last.sequence < _previousUpstreamSequence!) {
      _previousUpstreamSequence = null;
      _pendingDiscontinuity = _nextSequence > 0;
      _markMediaGap();
    }
    _reopened = false;
    var lastMedia = DateTime.now();
    var firstLoad = _previousUpstreamSequence == null;
    while (!cancelled) {
      final available =
          firstLoad && !playlist.ended && playlist.segments.length > 3
          ? playlist.segments.sublist(playlist.segments.length - 3)
          : playlist.segments;
      for (final segment in available) {
        if (_previousUpstreamSequence != null &&
            segment.sequence <= _previousUpstreamSequence!) {
          continue;
        }
        if (_previousUpstreamSequence != null &&
            segment.sequence != _previousUpstreamSequence! + 1) {
          _pendingDiscontinuity = true;
          _markMediaGap();
          DiagnosticsLog.instance.add('dvr', 'capture_media_gap');
        }
        String? map;
        String? key;
        if (segment.map != null) {
          map = await _asset(
            segment.map!.uri,
            segment.map!.range,
            isKey: false,
          );
          _pendingAssets.add(map);
        }
        if (segment.key != null) {
          key = await _asset(segment.key!.uri, null, isKey: true);
          _pendingAssets.add(key);
        }
        final extension = map == null ? 'ts' : 'm4s';
        final filename = 'segment-$_nextSequence.$extension';
        await _makeRoom(0, end: _end + segment.duration);
        final size = await _download(
          segment.uri,
          segment.range,
          filename,
          maximumBytes: min(64 * 1024 * 1024, service.settings.maxBufferBytes),
        );
        // AES-128's implicit IV belongs to the upstream sequence, even though
        // local sequences and a saved recording's timeline start at zero.
        final iv = segment.key == null
            ? null
            : (segment.key!.iv?.substring(2) ??
                      segment.sequence.toRadixString(16))
                  .padLeft(32, '0');
        await _commit(
          filename,
          size,
          segment.duration,
          discontinuity: segment.discontinuity || _pendingDiscontinuity,
          map: map,
          key: key,
          iv: iv == null ? null : '0x$iv',
        );
        _pendingAssets.clear();
        _previousUpstreamSequence = segment.sequence;
        lastMedia = DateTime.now();
      }
      firstLoad = false;
      if (playlist.ended) return;
      if (DateTime.now().difference(lastMedia) > const Duration(seconds: 45)) {
        throw const _TransientCaptureFailure(
          'The provider stopped publishing new HLS segments.',
        );
      }
      // This is the HLS protocol's reload interval, not an asynchronous job
      // status poll. Cancellation wakes the wait immediately.
      final delay = Duration(
        milliseconds: max(1000, playlist.targetDuration.inMilliseconds ~/ 2),
      );
      await _wait(Future<void>.delayed(delay));
      final opened = await _open(uri);
      uri = opened.uri;
      playlist = HlsPlaylist.parse(await _readPlaylist(opened.response), uri);
      if (playlist.targetDuration.inSeconds != _targetDurationSeconds) {
        throw const DvrException(
          'The provider changed its HLS target duration while recording.',
        );
      }
      if (playlist.variant != null) {
        throw const DvrException(
          'The provider changed its HLS playlist format.',
        );
      }
    }
  }

  Future<String> _asset(
    Uri uri,
    HlsByteRange? range, {
    required bool isKey,
  }) async {
    final identity =
        '${isKey ? 'key' : 'map'}:$uri:${range?.offset}:${range?.length}';
    final existing = _remoteAssets[identity];
    if (existing != null && _assets.containsKey(existing)) return existing;
    final filename = isKey
        ? 'key-${_nextAsset++}.bin'
        : 'init-${_nextAsset++}.mp4';
    final size = await _download(
      uri,
      range,
      filename,
      maximumBytes: isKey
          ? 16
          : min(8 * 1024 * 1024, service.settings.maxBufferBytes),
    );
    if (isKey && size != 16) {
      await File(p.join(directory.path, filename)).delete();
      throw const DvrException('The HLS AES key is invalid.');
    }
    _assets[filename] = _Asset(filename, size);
    _remoteAssets[identity] = filename;
    _diskBytes += size;
    return filename;
  }

  Future<void> _commit(
    String filename,
    int bytes,
    Duration duration, {
    bool discontinuity = false,
    String? map,
    String? key,
    String? iv,
  }) async {
    if (duration > service.settings.maxBufferDuration) {
      await File(p.join(directory.path, filename)).delete();
      throw const DvrException(
        'A media segment is longer than the configured buffer duration.',
      );
    }
    if ((duration.inMicroseconds / 1000000).round() > _targetDurationSeconds) {
      await File(p.join(directory.path, filename)).delete();
      throw const DvrException(
        'A media segment exceeds the fixed local playlist duration.',
      );
    }
    if (discontinuity) _discontinuities++;
    final segment = _MediaSegment(
      sequence: _nextSequence++,
      filename: filename,
      start: _end,
      duration: duration,
      bytes: bytes,
      discontinuitySequence: _discontinuities,
      discontinuity: discontinuity,
      map: map,
      key: key,
      iv: iv,
    );
    segments.add(segment);
    _diskBytes += bytes;
    _end = segment.end;
    final sink = recording;
    if (sink != null) await sink.append(segment, directory);
    state = DvrCaptureState.buffering;
    _pendingDiscontinuity = false;
    _retryAttempt = 0;
    _recoveryStarted = null;
    error = null;
    if (!ready.isCompleted) ready.complete();
    service._publish();
  }

  Future<_OpenResponse> _open(Uri requested, {HlsByteRange? range}) async {
    var uri = requested;
    final original = Uri.parse(stream.url);
    final gate = ProviderRequestGate.instance;
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (!{'http', 'https'}.contains(uri.scheme) ||
          uri.host.isEmpty ||
          (original.scheme == 'https' && uri.scheme != 'https')) {
        throw const DvrException(
          'The provider redirected to an unsupported media URL.',
        );
      }
      gate.check(original);
      gate.check(uri);
      final request = await _wait(
        client.getUrl(uri).timeout(const Duration(seconds: 15)),
      );
      _request = request;
      request.followRedirects = false;
      for (final header in stream.headers.entries) {
        final name = header.key.toLowerCase();
        if ({
          'host',
          'connection',
          'content-length',
          'range',
          'accept-encoding',
        }.contains(name)) {
          continue;
        }
        if (uri.origin != original.origin &&
            {'authorization', 'cookie', 'proxy-authorization'}.contains(name)) {
          continue;
        }
        request.headers.set(header.key, header.value);
      }
      if (range != null) {
        request.headers.set(
          HttpHeaders.rangeHeader,
          'bytes=${range.offset}-${range.offset + range.length - 1}',
        );
      }
      final response = await _wait(
        request.close().timeout(const Duration(seconds: 15)),
      );
      final retryAfter = response.headers.value(HttpHeaders.retryAfterHeader);
      gate.recordResponse(
        uri,
        response.statusCode,
        retryAfter: retryAfter,
      );
      gate.recordResponse(
        original,
        response.statusCode,
        retryAfter: retryAfter,
      );
      try {
        gate.check(original);
        gate.check(uri);
      } on ProviderRequestBlocked catch (error, stackTrace) {
        try {
          await ProviderRequestGate.instance.flushCooldowns();
        } catch (_) {
          // Keep the refusal if the device cannot persist its deadline.
        }
        try {
          await response.take(0).drain<void>();
        } catch (_) {
          // A failing body cancellation must not turn a refusal into a retry.
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.take(0).drain<void>();
        if (location == null || redirects == 5) {
          throw const DvrException(
            'The provider media redirect could not be followed.',
          );
        }
        try {
          uri = uri.resolve(location);
        } on FormatException {
          throw const DvrException('The provider media redirect is invalid.');
        }
        continue;
      }
      if (response.statusCode != (range == null ? 200 : 206)) {
        await response.take(0).drain<void>();
        throw _CaptureHttpFailure(response.statusCode);
      }
      if (range != null) {
        final contentRange = response.headers.value(
          HttpHeaders.contentRangeHeader,
        );
        if (contentRange == null ||
            !contentRange.startsWith(
              'bytes ${range.offset}-${range.offset + range.length - 1}/',
            )) {
          await response.take(0).drain<void>();
          throw const DvrException(
            'The provider returned a different HLS byte range.',
          );
        }
      }
      return _OpenResponse(response, uri);
    }
    throw const DvrException('The provider redirected too many times.');
  }

  Future<String> _readPlaylist(HttpClientResponse response) async {
    final bytes = BytesBuilder(copy: false);
    final iterator = StreamIterator<List<int>>(
      response.timeout(const Duration(seconds: 15)),
    );
    try {
      while (await _wait(iterator.moveNext())) {
        bytes.add(iterator.current);
        if (bytes.length > 2 * 1024 * 1024) {
          throw const DvrException('The HLS playlist is too large to record.');
        }
      }
      return utf8.decode(bytes.takeBytes());
    } finally {
      await iterator.cancel();
    }
  }

  Future<int> _download(
    Uri uri,
    HlsByteRange? range,
    String filename, {
    required int maximumBytes,
  }) async {
    final opened = await _open(uri, range: range);
    final response = opened.response;
    if (response.contentLength > maximumBytes) {
      await response.take(0).drain<void>();
      throw const DvrException(
        'A provider media segment exceeds the local buffer limit.',
      );
    }
    final partial = File(p.join(directory.path, '$filename.partial'));
    RandomAccessFile? output;
    final iterator = StreamIterator<List<int>>(
      response.timeout(const Duration(seconds: 20)),
    );
    try {
      output = await partial.open(mode: FileMode.write);
      _pendingBytes = 0;
      while (await _wait(iterator.moveNext())) {
        final chunk = iterator.current;
        if (_pendingBytes + chunk.length > maximumBytes) {
          throw const DvrException(
            'A provider media segment exceeds the local buffer limit.',
          );
        }
        await _makeRoom(chunk.length);
        await output.writeFrom(chunk);
        _pendingBytes += chunk.length;
      }
      if (_pendingBytes == 0 ||
          (response.contentLength >= 0 &&
              _pendingBytes != response.contentLength) ||
          (range != null && _pendingBytes != range.length)) {
        throw const _TransientCaptureFailure(
          'The provider returned an incomplete media segment.',
        );
      }
      await output.flush();
      await output.close();
      output = null;
      await partial.rename(p.join(directory.path, filename));
      return _pendingBytes;
    } finally {
      await iterator.cancel();
      await output?.close();
      _pendingBytes = 0;
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<void> _makeRoom(int additional, {Duration? end}) async {
    final settings = service.settings;
    while (_diskBytes + _pendingBytes + additional > settings.maxBufferBytes ||
        (segments.isNotEmpty &&
            end != null &&
            end - segments.first.start > settings.maxBufferDuration)) {
      if (segments.isEmpty) {
        throw const DvrException(
          'The stream exceeds the local buffer storage limit.',
        );
      }
      final oldest = segments.first;
      final lease = _leases[oldest.sequence];
      if ((lease != null && lease.isAfter(DateTime.now())) ||
          oldest.files.any((file) => (_readers[file] ?? 0) > 0)) {
        throw const DvrException(
          'The local buffer limit was reached while playback still needed its files. Return to live or increase the limit.',
        );
      }
      segments.removeAt(0);
      _leases.remove(oldest.sequence);
      await File(p.join(directory.path, oldest.filename)).delete();
      _diskBytes -= oldest.bytes;
      final used = segments.expand((segment) => segment.files).toSet()
        ..addAll(_pendingAssets);
      for (final asset in _assets.values.toList()) {
        if (!used.contains(asset.filename)) {
          await File(p.join(directory.path, asset.filename)).delete();
          _assets.remove(asset.filename);
          _remoteAssets.removeWhere((_, value) => value == asset.filename);
          _diskBytes -= asset.bytes;
        }
      }
    }
  }

  Future<void> serve(HttpRequest request, List<String> path) async {
    if (path.length != 2) {
      request.response.statusCode = HttpStatus.notFound;
      return;
    }
    final cursor = _cursors[path.first];
    if (cursor == null) {
      request.response.statusCode = HttpStatus.notFound;
      return;
    }
    cursor.lastSeen = DateTime.now();
    if (path[1] == 'index.m3u8') {
      final available = segments
          .where(
            (segment) =>
                segment.sequence >=
                max(cursor.firstSequence, cursor.currentSequence - 2),
          )
          .take(6)
          .toList();
      if (available.isEmpty) {
        request.response.statusCode = HttpStatus.gone;
        return;
      }
      final target = available
          .map((s) => s.duration.inMicroseconds)
          .reduce(max);
      final duration = available.fold<int>(
        0,
        (sum, s) => sum + s.duration.inMicroseconds,
      );
      final until = DateTime.now().add(
        Duration(microseconds: duration + target),
      );
      for (final segment in available) {
        final previous = _leases[segment.sequence];
        if (previous == null || previous.isBefore(until)) {
          _leases[segment.sequence] = until;
        }
      }
      _playlistResponse(
        request,
        _playlist(
          available,
          ended: !isRunning && available.last == segments.last,
          targetDuration: _targetDurationSeconds,
        ),
      );
      return;
    }
    final filename = path[1];
    if (!_safeFile(filename)) {
      request.response.statusCode = HttpStatus.notFound;
      return;
    }
    _MediaSegment? media;
    for (final segment in segments) {
      if (segment.files.contains(filename)) {
        media = segment;
        break;
      }
    }
    if (media == null) {
      request.response.statusCode = HttpStatus.gone;
      return;
    }
    _readers[filename] = (_readers[filename] ?? 0) + 1;
    try {
      await _fileResponse(request, File(p.join(directory.path, filename)));
      if (request.method == 'GET' && filename == media.filename) {
        cursor.currentSequence = max(cursor.currentSequence, media.sequence);
      }
    } finally {
      final remaining = _readers[filename]! - 1;
      if (remaining == 0) {
        _readers.remove(filename);
      } else {
        _readers[filename] = remaining;
      }
      if (_deleteWhenIdle) await disposeFiles();
    }
  }

  Future<void> disposeFiles() async {
    // A cancelled player can still have an in-flight local read. Closing the
    // application server handles shutdown; Windows deletion may wait until the
    // stream closes. Do not recursively delete while file handles are active.
    _deleteWhenIdle = true;
    if (_readers.values.any((value) => value > 0)) return;
    await (_fileDisposal ??= () async {
      if (await directory.exists()) await directory.delete(recursive: true);
    }());
  }
}

class _CaptureCancelled implements Exception {
  const _CaptureCancelled();
}

class _RecordingSink {
  _RecordingSink(this.service, this.directory, this.value);

  final DvrService service;
  final Directory directory;
  final String token = _randomId();
  DvrRecording value;
  final List<_MediaSegment> segments = [];
  final Map<String, int> assets = {};
  Future<void> _writes = Future.value();
  int _nextCheckpoint = 128;
  bool _accepting = true;
  int readers = 0;

  static Future<_RecordingSink?> recover(
    DvrService service,
    Directory directory,
  ) async {
    final json = await _readJson(
      File(p.join(directory.path, 'recording.json')),
    );
    try {
      if (json == null) throw const FormatException();
      var value = DvrRecording.fromJson(json);
      if (value.id != p.basename(directory.path)) throw const FormatException();
      final sink = _RecordingSink(service, directory, value)
        .._accepting = false;
      final savedSegments = json['segments'];
      if (savedSegments is! List) throw const FormatException();
      var broken = false;
      final recoveredSegments = <dynamic>[...savedSegments];
      final journal = File(p.join(directory.path, 'segments.jsonl'));
      if (await journal.exists()) {
        // Checkpoint publication precedes journal truncation. Replaying an old
        // journal after a crash must therefore skip already checkpointed rows.
        try {
          var index = savedSegments.length;
          await for (final line in journal.openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
            if (line.isEmpty) continue;
            final entry = jsonDecode(line) as Map<String, dynamic>;
            final ordinal = entry['index'] as int;
            if (ordinal < savedSegments.length) continue;
            if (ordinal != index++) throw const FormatException();
            recoveredSegments.add(entry['segment']);
            if (entry['hasGaps'] == true) value = value.copyWith(hasGaps: true);
          }
        } catch (_) {
          // A torn final journal record does not invalidate its durable prefix.
          broken = true;
        }
      }
      final usedFiles = <String>{};
      for (final item in recoveredSegments) {
        try {
          final segment = _MediaSegment.fromJson(
            Map<String, dynamic>.from(item as Map),
          );
          if (sink.segments.isNotEmpty &&
              segment.sequence != sink.segments.last.sequence + 1) {
            throw const FormatException();
          }
          for (final filename in segment.files) {
            final file = File(p.join(directory.path, filename));
            if (await FileSystemEntity.type(file.path, followLinks: false) !=
                    FileSystemEntityType.file ||
                await file.length() <= 0) {
              throw const FormatException();
            }
          }
          if (await File(p.join(directory.path, segment.filename)).length() !=
              segment.bytes) {
            throw const FormatException();
          }
          sink.segments.add(segment);
          usedFiles.addAll(segment.files);
        } catch (_) {
          broken = true;
          break; // Only the complete prefix is safe to publish for playback.
        }
      }
      var bytes = 0;
      for (final filename in usedFiles) {
        final length = await File(p.join(directory.path, filename)).length();
        bytes += length;
        if (!filename.startsWith('segment-')) sink.assets[filename] = length;
      }
      await for (final entry in directory.list(followLinks: false)) {
        final name = p.basename(entry.path);
        if (entry is File &&
            ((name.endsWith('.partial') || name.endsWith('.new')) ||
                (_safeFile(name) && !usedFiles.contains(name)))) {
          await entry.delete();
        }
      }
      final duration = sink.segments.fold(
        Duration.zero,
        (sum, s) => sum + s.duration,
      );
      final interrupted =
          value.status == DvrRecordingStatus.recording || broken;
      value = value.copyWith(
        status: interrupted ? DvrRecordingStatus.interrupted : value.status,
        endedAt: interrupted ? DateTime.now() : value.endedAt,
        duration: duration,
        bytes: bytes,
        error: broken
            ? 'Some recording files were missing or damaged. The complete part was recovered.'
            : interrupted
            ? 'The app stopped while this recording was running.'
            : null,
      );
      if (sink.segments.isEmpty &&
          value.status == DvrRecordingStatus.completed) {
        value = value.copyWith(
          status: DvrRecordingStatus.failed,
          error: 'This recording contains no complete media segments.',
        );
      }
      sink.value = value;
      await sink.persist();
      return sink;
    } catch (_) {
      // Keep a damaged recording visible and charged against the quota. The
      // user can deliberately delete it; recovery never removes saved media.
      var bytes = 0;
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is File && _safeFile(p.basename(entry.path))) {
          bytes += await entry.length();
        }
      }
      final sink = _RecordingSink(
        service,
        directory,
        DvrRecording(
          id: p.basename(directory.path),
          channelName: 'Recovered recording',
          startedAt: (await directory.stat()).modified,
          endedAt: DateTime.now(),
          status: DvrRecordingStatus.failed,
          bytes: bytes,
          error: 'Recording metadata is damaged. These files cannot be played safely.',
        ),
      ).._accepting = false;
      return sink;
    }
  }

  Future<void> append(_MediaSegment segment, Directory source) {
    if (!_accepting) return Future.value();
    final result = _writes.then((_) async {
      final newAssets = <String, int>{};
      for (final filename in [segment.map, segment.key].whereType<String>()) {
        if (!assets.containsKey(filename)) {
          newAssets[filename] = await File(p.join(source.path, filename))
              .length();
        }
      }
      final addedBytes =
          segment.bytes + newAssets.values.fold<int>(0, (sum, b) => sum + b);
      if (service.recordingBytes + addedBytes > service.recordingQuotaBytes) {
        throw const DvrException(
          'Recording storage is full. This recording was stopped; saved recordings were kept.',
        );
      }
      final copied = <File>[];
      final previous = value;
      final previousLength = segments.length;
      try {
        for (final filename in [...newAssets.keys, segment.filename]) {
          final destination = File(p.join(directory.path, filename));
          final partial = File('${destination.path}.partial');
          copied.addAll([partial, destination]);
          await _durableCopy(File(p.join(source.path, filename)), partial);
          await partial.rename(destination.path);
        }
        assets.addAll(newAssets);
        segments.add(segment);
        value = value.copyWith(
          duration: value.duration + segment.duration,
          bytes: value.bytes + addedBytes,
        );
        // Media is already flushed and renamed. The journal is the durable
        // commit; checkpointing it is optional and must not roll this row back.
        await _appendJournal(segment);
      } catch (_) {
        segments.removeRange(previousLength, segments.length);
        for (final name in newAssets.keys) {
          assets.remove(name);
        }
        var retainedBytes = 0;
        for (final file in copied) {
          try {
            if (await file.exists()) await file.delete();
          } catch (_) {
            // A failed delete still consumes the quota until recovery retries
            // cleanup or the user deletes this recording.
            try {
              retainedBytes += await file.length();
            } catch (_) {}
          }
        }
        value = previous.copyWith(bytes: previous.bytes + retainedBytes);
        rethrow;
      }
      service._publish();
      if (segments.length >= _nextCheckpoint) {
        _nextCheckpoint *= 2;
        try {
          await persist();
        } catch (_) {
          // The flushed journal still recovers every committed segment.
          DiagnosticsLog.instance.add('dvr', 'recording_checkpoint_deferred');
        }
      }
    });
    _writes = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> close(DvrRecordingStatus status, {String? error}) {
    _accepting = false;
    final result = _writes.then((_) async {
      if (value.status != DvrRecordingStatus.recording) return;
      if (segments.isEmpty && status == DvrRecordingStatus.completed) {
        status = DvrRecordingStatus.failed;
        error ??=
            'No complete media segment was received before recording stopped.';
      }
      value = value.copyWith(
        status: status,
        endedAt: DateTime.now(),
        error: error,
      );
      await persist();
      DiagnosticsLog.instance.add(
        'dvr',
        'recording_stopped status=${status.name} bytes=${value.bytes}',
      );
    });
    _writes = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> persist() async {
    await _atomicText(
      File(p.join(directory.path, 'recording.json')),
      jsonEncode({
        ...value.toJson(),
        'segments': segments.map((s) => s.toJson()).toList(),
      }),
    );
    await _atomicText(
      File(p.join(directory.path, 'index.m3u8')),
      _playlist(segments, ended: value.status != DvrRecordingStatus.recording),
    );
    final journal = File(p.join(directory.path, 'segments.jsonl'));
    if (await journal.exists()) await journal.delete();
  }

  Future<void> _appendJournal(_MediaSegment segment) async {
    final file = await File(p.join(directory.path, 'segments.jsonl'))
        .open(mode: FileMode.append);
    try {
      await file.writeString('${jsonEncode({
        'index': segments.length - 1,
        'segment': segment.toJson(),
        'hasGaps': value.hasGaps,
      })}\n');
      await file.flush();
    } finally {
      await file.close();
    }
  }

  Future<void> serve(HttpRequest request, String filename) async {
    if (value.status == DvrRecordingStatus.recording || segments.isEmpty) {
      request.response.statusCode = HttpStatus.notFound;
      return;
    }
    if (filename == 'index.m3u8') {
      _playlistResponse(request, _playlist(segments, ended: true));
      return;
    }
    if (!_safeFile(filename) ||
        !segments.any((s) => s.files.contains(filename))) {
      request.response.statusCode = HttpStatus.notFound;
      return;
    }
    readers++;
    try {
      await _fileResponse(request, File(p.join(directory.path, filename)));
    } finally {
      readers--;
    }
  }
}

String _playlist(
  List<_MediaSegment> segments, {
  required bool ended,
  int? targetDuration,
}) {
  final target =
      targetDuration ??
      (segments.isEmpty
          ? 6
          : max(
              1,
              segments
                  .map((s) => (s.duration.inMicroseconds / 1000000).ceil())
                  .reduce(max),
            ));
  final first = segments.isEmpty ? null : segments.first;
  final result = StringBuffer()
    ..writeln('#EXTM3U')
    ..writeln('#EXT-X-VERSION:7')
    ..writeln('#EXT-X-TARGETDURATION:$target')
    ..writeln('#EXT-X-MEDIA-SEQUENCE:${first?.sequence ?? 0}')
    ..writeln(
      '#EXT-X-DISCONTINUITY-SEQUENCE:${first == null ? 0 : first.discontinuitySequence - (first.discontinuity ? 1 : 0)}',
    )
    ..writeln('#EXT-X-START:TIME-OFFSET=0,PRECISE=YES');
  if (ended) result.writeln('#EXT-X-PLAYLIST-TYPE:VOD');
  String? previousMap;
  String? previousKey;
  String? previousIv;
  for (final segment in segments) {
    if (segment.discontinuity) result.writeln('#EXT-X-DISCONTINUITY');
    if (segment.key != previousKey || segment.iv != previousIv) {
      result.writeln(
        segment.key == null
            ? '#EXT-X-KEY:METHOD=NONE'
            : '#EXT-X-KEY:METHOD=AES-128,URI="${segment.key}",IV=${segment.iv}',
      );
      previousKey = segment.key;
      previousIv = segment.iv;
    }
    if (segment.map != null && segment.map != previousMap) {
      result.writeln('#EXT-X-MAP:URI="${segment.map}"');
      previousMap = segment.map;
    }
    result
      ..writeln(
        '#EXTINF:${(segment.duration.inMicroseconds / 1000000).toStringAsFixed(6)},',
      )
      ..writeln(segment.filename);
  }
  if (ended) result.writeln('#EXT-X-ENDLIST');
  return result.toString();
}

void _playlistResponse(HttpRequest request, String body) {
  final bytes = utf8.encode(body);
  request.response.headers
    ..contentType = ContentType('application', 'vnd.apple.mpegurl')
    ..set(HttpHeaders.cacheControlHeader, 'no-store')
    ..set('X-Content-Type-Options', 'nosniff');
  request.response.contentLength = bytes.length;
  if (request.method != 'HEAD') request.response.add(bytes);
}

Future<void> _fileResponse(HttpRequest request, File file) async {
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    request.response.statusCode = HttpStatus.notFound;
    return;
  }
  final size = await file.length();
  var start = 0;
  var end = size - 1;
  final range = request.headers.value(HttpHeaders.rangeHeader);
  if (range != null) {
    final match = RegExp(r'^bytes=([0-9]*)-([0-9]*)$').firstMatch(range);
    if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */$size',
      );
      return;
    }
    if (match[1]!.isEmpty) {
      start = max(0, size - (int.tryParse(match[2]!) ?? 0));
    } else {
      start = int.tryParse(match[1]!) ?? size;
      if (match[2]!.isNotEmpty) end = min(end, int.tryParse(match[2]!) ?? -1);
    }
    if (start < 0 || start > end || start >= size) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */$size',
      );
      return;
    }
    request.response.statusCode = HttpStatus.partialContent;
    request.response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$end/$size',
    );
  }
  request.response.headers
    ..set(HttpHeaders.acceptRangesHeader, 'bytes')
    ..set(HttpHeaders.cacheControlHeader, 'no-store')
    ..set('X-Content-Type-Options', 'nosniff');
  final extension = p.extension(file.path);
  request.response.headers.contentType = extension == '.ts'
      ? ContentType('video', 'mp2t')
      : extension == '.m4s' || extension == '.mp4'
      ? ContentType('video', 'mp4')
      : ContentType.binary;
  request.response.contentLength = end - start + 1;
  if (request.method != 'HEAD') {
    await request.response.addStream(file.openRead(start, end + 1));
  }
}

Future<void> _durableCopy(File source, File destination) async {
  final output = await destination.open(mode: FileMode.write);
  try {
    await for (final chunk in source.openRead()) {
      await output.writeFrom(chunk);
    }
    await output.flush();
  } finally {
    await output.close();
  }
}
