import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'dvr_models.dart';
import 'mpeg_ts_segmenter.dart';

/// One parser isolate per direct-TS capture. Await each chunk before reading
/// another: the worker never queues the network stream or complete segments.
class TsSegmentWorker {
  TsSegmentWorker._() {
    _ready.future.ignore();
    _events.listen(_receive);
  }

  final ReceivePort _events = ReceivePort();
  final Completer<SendPort> _ready = Completer<SendPort>();
  final Completer<void> _exited = Completer<void>();
  Isolate? _isolate;
  SendPort? _commands;
  Completer<List<TsSegment>>? _pending;
  bool _closed = false;

  static Future<TsSegmentWorker> start({
    Duration targetDuration = const Duration(seconds: 4),
    int maximumSegmentBytes = 32 * 1024 * 1024,
  }) async {
    final worker = TsSegmentWorker._();
    try {
      worker._isolate = await Isolate.spawn(
        _parse,
        (
          worker._events.sendPort,
          targetDuration.inMicroseconds,
          maximumSegmentBytes,
        ),
        onError: worker._events.sendPort,
        onExit: worker._events.sendPort,
        errorsAreFatal: true,
        debugName: 'dvr-ts-parser',
      );
      worker._commands = await worker._ready.future;
      return worker;
    } catch (_) {
      // Spawn failures have no isolate and therefore no exit notification.
      if (worker._isolate == null && !worker._exited.isCompleted) {
        worker._exited.complete();
      }
      await worker.close();
      rethrow;
    }
  }

  Future<List<TsSegment>> add(List<int> bytes) => _request(bytes);

  Future<List<TsSegment>> finish() => _request(null);

  Future<List<TsSegment>> _request(List<int>? bytes) {
    if (_closed) throw StateError('The DVR parser is closed.');
    if (_pending != null) {
      throw StateError('Await the previous DVR chunk first.');
    }
    final pending = _pending = Completer<List<TsSegment>>();
    _commands!.send(
      bytes == null
          ? null
          : TransferableTypedData.fromList([
              bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
            ]),
    );
    return pending.future;
  }

  void _receive(dynamic message) {
    if (message is SendPort) {
      _ready.complete(message);
    } else if (message == null) {
      _closed = true;
      _fail(const DvrException('The DVR parser stopped unexpectedly.'));
      if (!_exited.isCompleted) _exited.complete();
    } else if (message is List &&
        message.length == 2 &&
        message[0] == 'segments') {
      final pending = _pending;
      _pending = null;
      pending?.complete([
        for (final entry in message[1] as List)
          TsSegment(
            (entry[0] as TransferableTypedData).materialize().asUint8List(),
            Duration(microseconds: entry[1] as int),
            entry[2] as bool,
          ),
      ]);
    } else {
      // Do not relay arbitrary isolate errors, which may contain provider data.
      final reason =
          message is List && message.isNotEmpty && message.first == 'error'
          ? message[1] as String
          : 'The DVR parser failed.';
      _fail(DvrException(reason));
    }
  }

  void _fail(DvrException error) {
    if (!_ready.isCompleted) _ready.completeError(error);
    final pending = _pending;
    _pending = null;
    pending?.completeError(error);
  }

  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      _fail(const DvrException('The DVR parser was closed.'));
      _isolate?.kill(priority: Isolate.immediate);
    }
    await _exited.future;
    _events.close();
  }

  static void _parse((SendPort, int, int) configuration) {
    final (events, targetUs, maximumBytes) = configuration;
    final parser = MpegTsSegmenter(
      targetDuration: Duration(microseconds: targetUs),
      maximumSegmentBytes: maximumBytes,
      copyInput: false,
    );
    final commands = ReceivePort();
    events.send(commands.sendPort);
    commands.listen((dynamic message) {
      try {
        final segments = message == null
            ? [?parser.finish()]
            : parser.add(
                (message as TransferableTypedData).materialize().asUint8List(),
              );
        events.send([
          'segments',
          [
            for (final segment in segments)
              [
                TransferableTypedData.fromList([segment.bytes]),
                segment.duration.inMicroseconds,
                segment.discontinuity,
              ],
          ],
        ]);
      } catch (error) {
        events.send([
          'error',
          error is DvrException ? error.message : 'The DVR parser failed.',
        ]);
      }
    });
  }
}
