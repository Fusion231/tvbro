import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:media_kit/media_kit.dart';

import '../data/net.dart';
import 'mpv_http_response_parser.dart';

/// One private log client per physical mpv engine. The public media_kit client
/// remains at warn, so raw curl trace never enters Player.stream.log, terminal
/// output, DiagnosticsLog or Flutter's error stream.
class MpvHttpResponseMonitor {
  MpvHttpResponseMonitor._(this._client, this._onRefusal);
  static final _clients = Expando<Future<_HttpClient?>>();
  final _HttpClient _client;
  final void Function(int) _onRefusal;
  bool _disposed = false;
  int get observedEventCount => _client.eventCount;

  static Future<MpvHttpResponseMonitor?> attach(
    NativePlayer player, {
    required void Function(int status) onRefusal,
  }) async {
    // Android's separate JNI player has its own logging boundary. Never turn
    // up its global log verbosity from this Windows implementation.
    if (!Platform.isWindows) return null;
    final client = await (_clients[player] ??= _HttpClient.create(player));
    if (client == null || client.closed) return null;
    final monitor = MpvHttpResponseMonitor._(client, onRefusal);
    client.listeners.add(monitor);
    return monitor;
  }

  void begin(String url) {
    _client.drain();
    final uri = Uri.tryParse(url);
    _client.origin =
        uri == null ||
            uri.host.isEmpty ||
            !const ['http', 'https'].contains(uri.scheme)
        ? null
        : Uri(
            scheme: uri.scheme,
            host: uri.host,
            port: uri.hasPort ? uri.port : null,
          );
    _client.parser.reset();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _client.listeners.remove(this);
    if (_client.listeners.isEmpty) {
      _clients[_client.player] = null;
      _client.dispose();
    }
  }
}

/// Layout is the stable mpv_event_log_message from libmpv client.h.
final class _LogMessage extends Struct {
  external Pointer<Char> prefix;
  external Pointer<Char> level;
  external Pointer<Char> text;
  @Int32()
  external int logLevel;
}

class _HttpClient {
  _HttpClient(this.player);
  final NativePlayer player;
  final listeners = <MpvHttpResponseMonitor>{};
  final parser = MpvHttpResponseParser();
  Pointer<Void> handle = nullptr;
  NativeCallable<Void Function(Pointer<Void>)>? wakeup;
  Uri? origin;
  bool closed = false;
  bool draining = false;
  int eventCount = 0;
  String? previousMessageLevel;
  bool traceEnabled = false;

  static Future<_HttpClient?> create(NativePlayer player) async {
    final client = _HttpClient(player);
    try {
      await player.waitForPlayerInitialization;
      await player.setProperty('terminal', 'no');
      if (player.disposed) return null;
      client.previousMessageLevel = await player.getProperty('msg-level');
      if (player.disposed) return null;
      final name = 'tvbro_http_response'.toNativeUtf8();
      try {
        client.handle = player.mpv
            .mpv_create_weak_client(player.ctx, name.cast())
            .cast();
      } finally {
        malloc.free(name);
      }
      if (client.handle == nullptr) return null;
      final level = 'terminal-default'.toNativeUtf8();
      try {
        if (player.mpv.mpv_request_log_messages(
              client.handle.cast(),
              level.cast(),
            ) <
            0) {
          client.dispose();
          return null;
        }
      } finally {
        malloc.free(level);
      }
      client.wakeup = NativeCallable<Void Function(Pointer<Void>)>.listener((
        Pointer<Void> _,
      ) {
        client.drain();
      });
      client.wakeup!.keepIsolateAlive = false;
      player.mpv.mpv_set_wakeup_callback(
        client.handle.cast(),
        client.wakeup!.nativeFunction,
        nullptr,
      );
      // Only curl's HTTP diagnostics are enabled. Decoder/demuxer per-frame
      // trace stays disabled. terminal-default respects this module filter.
      await player.setProperty('msg-level', 'all=warn,curl=trace');
      client.traceEnabled = true;
      return client;
    } catch (_) {
      client.dispose();
      return null;
    }
  }

  static String? incomingHeader(Pointer<Char> text) {
    final bytes = text.cast<Uint8>();
    // Drop outbound headers (including Authorization/Cookie) before decoding.
    if (bytes[0] != 60) return null;
    bool starts(String prefix) {
      for (var i = 0; i < prefix.length; i++) {
        final actual = bytes[i];
        if (actual == 0 || (actual | 32) != (prefix.codeUnitAt(i) | 32)) {
          return false;
        }
      }
      return true;
    }

    final blank =
        bytes[1] == 0 ||
        bytes[1] == 10 ||
        bytes[1] == 13 ||
        (bytes[1] == 32 && (bytes[2] == 0 || bytes[2] == 10 || bytes[2] == 13));
    // Set-Cookie, Location and arbitrary response fields are discarded too.
    if (!blank && !starts('< HTTP/') && !starts('< retry-after:')) return null;
    var length = 0;
    while (length < 4096 && bytes[length] != 0) {
      length++;
    }
    if (length == 4096) return null;
    return String.fromCharCodes(bytes.asTypedList(length));
  }

  void drain() {
    if (closed || draining) return;
    draining = true;
    try {
      for (var count = 0; count < 256 && !closed; count++) {
        final event = player.mpv.mpv_wait_event(handle.cast(), 0.0).ref;
        if (event.event_id == 0) return;
        eventCount++;
        if (event.event_id == 1) {
          dispose();
          return;
        }
        if (event.event_id == 24) {
          parser.reset();
          continue;
        } // queue overflow
        if (event.event_id != 2 || event.data == nullptr) continue;
        final message = event.data.cast<_LogMessage>().ref;
        if (message.prefix.cast<Utf8>().toDartString() != 'curl') continue;
        final text = incomingHeader(message.text);
        if (text == null) continue;
        final refusal = parser.addCurlResponseLine(text);
        final uri = origin;
        if (refusal == null || uri == null) continue;
        ProviderRequestGate.instance.recordResponse(
          uri,
          refusal.status,
          retryAfter: refusal.retryAfter,
        );
        unawaited(
          ProviderRequestGate.instance.flushCooldowns().catchError(
            (Object _) {},
          ),
        );
        for (final listener in listeners.toList()) {
          if (!listener._disposed) listener._onRefusal(refusal.status);
        }
      }
      // Continue only a known nonempty event batch, yielding the UI event loop.
      Timer.run(drain);
    } finally {
      draining = false;
    }
  }

  void dispose() {
    if (closed) return;
    closed = true;
    parser.reset();
    if (handle != nullptr) {
      player.mpv.mpv_set_wakeup_callback(handle.cast(), nullptr, nullptr);
      final previous = previousMessageLevel;
      if (traceEnabled && previous != null && !player.disposed) {
        // Synchronous restore precedes the owner's Player.dispose(), including
        // callers that keep an adopted preview engine alive after this lease.
        final name = 'msg-level'.toNativeUtf8();
        final value = previous.toNativeUtf8();
        try {
          player.mpv.mpv_set_property_string(
            player.ctx,
            name.cast(),
            value.cast(),
          );
        } finally {
          malloc.free(name);
          malloc.free(value);
        }
      }
      player.mpv.mpv_destroy(handle.cast());
      handle = nullptr;
    }
    wakeup?.close();
    wakeup = null;
  }
}
