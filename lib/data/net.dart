import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../l10n/app_localizations.dart';
import 'load_token.dart';
import 'provider_request_gate.dart';

export 'provider_request_gate.dart';

/// Native media engines often report HTTP failures only in their log stream.
/// Require an HTTP/status marker: a channel or codec number is not a refusal.
int? providerHttpRefusalStatus(Object error) {
  if (error is ProviderRequestBlocked) return error.status;
  final message = '$error';
  final match = RegExp(
    r'(?:\bHTTP(?:/\d(?:\.\d)?)?\s*(?:error\s*)?|\bstatus(?:\s+code)?\s*[:=]?\s*|\bserver returned\s+)(401|403|429)\b',
    caseSensitive: false,
  ).firstMatch(message);
  if (match != null) return int.parse(match.group(1)!);
  for (final entry in const {
    401: 'Unauthorized',
    403: 'Forbidden',
    429: 'Too Many Requests',
  }.entries) {
    if (RegExp('\\b${entry.key} ${entry.value}\\b', caseSensitive: false)
        .hasMatch(message)) {
      return entry.key;
    }
  }
  return null;
}

/// Named limits for one HTTP workload. The wire/body ceiling is separate from
/// the decoded ceiling so compressed responses cannot become decompression
/// bombs. [totalTimeout] never resets; [idleTimeout] resets for each chunk.
class HttpWorkloadPolicy {
  const HttpWorkloadPolicy({
    required this.name,
    required this.maximumBodyBytes,
    required this.maximumDecodedBytes,
    required this.totalTimeout,
    this.idleTimeout = const Duration(seconds: 20),
  });

  final String name;
  final int maximumBodyBytes;
  final int maximumDecodedBytes;
  final Duration idleTimeout;
  final Duration totalTimeout;

  HttpWorkloadPolicy copyWith({
    String? name,
    int? maximumBodyBytes,
    int? maximumDecodedBytes,
    Duration? idleTimeout,
    Duration? totalTimeout,
  }) => HttpWorkloadPolicy(
    name: name ?? this.name,
    maximumBodyBytes: maximumBodyBytes ?? this.maximumBodyBytes,
    maximumDecodedBytes: maximumDecodedBytes ?? this.maximumDecodedBytes,
    idleTimeout: idleTimeout ?? this.idleTimeout,
    totalTimeout: totalTimeout ?? this.totalTimeout,
  );
}

class HttpReadMetrics {
  final int compressedBytes;
  final int decodedBytes;
  const HttpReadMetrics({
    required this.compressedBytes,
    required this.decodedBytes,
  });
}

const int _mib = 1024 * 1024;

/// Provider payload limits are deliberately generous relative to normal API
/// responses. They stop hostile/unconfigured endpoints without rejecting the
/// large catalogs represented by the PR 0 fixtures.
const kPlaylistWorkload = HttpWorkloadPolicy(
  name: 'playlist',
  maximumBodyBytes: 128 * _mib,
  maximumDecodedBytes: 256 * _mib,
  totalTimeout: Duration(minutes: 5),
);

/// XMLTV guides are streamed to disk and parsed from there with the gzip
/// inflated on the fly (`xmltvGuideFeed`, `parseXmltvFileBatched`), so neither
/// number below is a memory budget any more — the body ceiling is disk, and the
/// decoded ceiling is parse *time*, the one cost that still grows with a guide.
/// Sized to take a combined "all countries" guide (~200 MB compressed, ~1.7 GB
/// decompressed) with headroom. The total timeout covers the download only; a
/// stalled server is still cut off by the 20 s idle timeout.
const kEpgWorkload = HttpWorkloadPolicy(
  name: 'epg',
  maximumBodyBytes: 512 * _mib,
  maximumDecodedBytes: 4096 * _mib,
  totalTimeout: Duration(minutes: 30),
);
const kProviderJsonWorkload = HttpWorkloadPolicy(
  name: 'provider JSON',
  maximumBodyBytes: 128 * _mib,
  maximumDecodedBytes: 256 * _mib,
  totalTimeout: Duration(minutes: 3),
);
const kStalkerJsonWorkload = HttpWorkloadPolicy(
  name: 'Stalker JSON',
  // Real portals can return the entire live catalog from get_all_channels in
  // one response. The PR 0 50k-row fixture is ~11 MiB and a user-validated
  // portal exceeds 16 MiB, so retain a meaningful ceiling without rejecting
  // legitimate large catalogs.
  maximumBodyBytes: 64 * _mib,
  maximumDecodedBytes: 128 * _mib,
  totalTimeout: Duration(minutes: 1),
);
const kMetadataJsonWorkload = HttpWorkloadPolicy(
  name: 'metadata JSON',
  maximumBodyBytes: 4 * _mib,
  maximumDecodedBytes: 8 * _mib,
  totalTimeout: Duration(seconds: 45),
);
const kUpdateDiscoveryWorkload = HttpWorkloadPolicy(
  name: 'update discovery',
  maximumBodyBytes: 1024 * 1024,
  maximumDecodedBytes: 2 * 1024 * 1024,
  totalTimeout: Duration(seconds: 45),
);
const kUpdateArtifactWorkload = HttpWorkloadPolicy(
  name: 'update artifact',
  maximumBodyBytes: 1024 * _mib,
  maximumDecodedBytes: 1024 * _mib,
  totalTimeout: Duration(minutes: 30),
);

/// Retained for native/update call sites that only need an idle timeout.
const Duration kHttpReadTimeout = Duration(seconds: 20);

/// HTTP failures that can recover when a provider is briefly busy or offline.
bool isTransientHttpStatus(int status) =>
    status == HttpStatus.requestTimeout ||
    status == HttpStatus.internalServerError ||
    status == HttpStatus.badGateway ||
    status == HttpStatus.serviceUnavailable ||
    status == HttpStatus.gatewayTimeout;

class HttpWorkloadException implements Exception {
  const HttpWorkloadException(this.message, {this.isSizeLimit = false});
  final String message;
  final bool isSizeLimit;

  @override
  String toString() => 'HttpWorkloadException: $message';
}

/// Whether a provider operation is worth retrying automatically.
///
/// Some provider implementations preserve the original dart:io exception,
/// while older Stalker endpoint discovery wraps it in a provider exception.
/// Keep the textual fallback deliberately narrow: size/policy failures and
/// authentication failures must fail immediately rather than repeating an
/// expensive catalog request.
bool isTransientNetworkError(Object error) {
  if (error is HttpWorkloadException || error is ProviderRequestBlocked) {
    return false;
  }
  if (error is TimeoutException ||
      error is SocketException ||
      error is HttpException) {
    return true;
  }
  final message = error.toString().toLowerCase();
  return message.contains('timed out') ||
      message.contains('timeoutexception') ||
      message.contains('connection reset') ||
      message.contains('connection closed') ||
      message.contains('connection refused') ||
      message.contains('network is unreachable') ||
      message.contains('temporary failure in name resolution');
}

/// Retries one transient provider failure, while leaving policy, parsing, and
/// authentication failures untouched.
Future<T> retryTransientNetworkOperation<T>(
  Future<T> Function() operation, {
  int maximumAttempts = 2,
  Duration retryDelay = const Duration(milliseconds: 600),
  void Function(Object error, int nextAttempt)? onRetry,
}) async {
  if (maximumAttempts < 1) {
    throw ArgumentError.value(maximumAttempts, 'maximumAttempts');
  }
  for (var attempt = 1; ; attempt++) {
    try {
      return await operation();
    } catch (error) {
      if (attempt >= maximumAttempts || !isTransientNetworkError(error)) {
        rethrow;
      }
      onRetry?.call(error, attempt + 1);
      if (retryDelay > Duration.zero) await Future<void>.delayed(retryDelay);
    }
  }
}

/// Short text suitable for a source-loading page. Provider exceptions can
/// contain request URLs, response bodies, or nested stack-like messages, so
/// those details stay in redacted diagnostics rather than the widget tree.
String sourceLoadErrorMessage(Object error) =>
    _providerErrorMessage(error) ??
    tr('The source could not be loaded. Check its details and try again.');

/// Lets playback retain device/decoder errors while sharing provider guidance.
bool isProviderConnectionError(Object error) =>
    _providerErrorMessage(error) != null;

String? _providerErrorMessage(Object error) {
  if (error is ProviderRequestBlocked) {
    final at = error.retryAt.toLocal();
    final pause = tr(
      'Requests to this provider are paused until {time} (HTTP {status}).',
      {
        'time':
            '${at.hour.toString().padLeft(2, '0')}:'
            '${at.minute.toString().padLeft(2, '0')}',
        'status': error.status,
      },
    );
    return '${_httpStatusMessage(error.status)} $pause';
  }
  final raw = error.toString();
  final message = raw.toLowerCase();
  final socketCode = error is SocketException ? error.osError?.errorCode : null;
  // Inspect statuses before generic HttpException/network wording. Native
  // engines and wrapped Stalker errors use several different status markers.
  final status = int.tryParse(
    RegExp(
          r'(?:\bHTTP(?:/\d(?:\.\d)?)?(?:\s+error)?(?:\s*[:=]\s*|\s+)|\bstatus(?:\s+code)?(?:\s*[:=]\s*|\s+)|\bserver returned\s+)(\d{3,})\b',
          caseSensitive: false,
        ).firstMatch(raw)?.group(1) ??
        '',
  );
  if (status != null && status >= 400) return _httpStatusMessage(status);
  if (error is HandshakeException ||
      error is TlsException ||
      message.contains('handshakeexception') ||
      message.contains('tlsexception') ||
      message.contains('certificateexception') ||
      message.contains('certificate_verify_failed') ||
      message.contains('certificate verify failed') ||
      message.contains('ssl handshake') ||
      message.contains('tls handshake')) {
    return tr(
      'A secure connection to the provider could not be established. Check the device date and time and the source HTTPS address. If they are correct, contact your provider about its certificate.',
    );
  }
  if (const {-2, -3, 7, 8, 11001, 11002, 11004}.contains(socketCode) ||
      message.contains('failed host lookup') ||
      message.contains('name or service not known') ||
      message.contains('nodename nor servname') ||
      message.contains('no such host') ||
      message.contains('unable to resolve host') ||
      message.contains('could not resolve host') ||
      message.contains('temporary failure in name resolution')) {
    return tr(
      'The provider address could not be found (DNS). Check your internet connection and the source address, then try again.',
    );
  }
  if (const {
        50,
        51,
        64,
        65,
        100,
        101,
        113,
        10050,
        10051,
        10065,
      }.contains(socketCode) ||
      message.contains('network is unreachable') ||
      message.contains('network is down') ||
      message.contains('no route to host') ||
      message.contains('host is unreachable') ||
      message.contains('network unreachable')) {
    return tr(
      'There is no network route to the provider. Check your Wi-Fi or cable connection and internet access, then try again.',
    );
  }
  // Socket messages can be localized; these are the Android/Linux, Apple,
  // and Windows refusal codes. Older provider wrappers retain only the text.
  if (const {111, 61, 10061}.contains(socketCode) ||
      message.contains('connection refused')) {
    return tr(
      'The connection to the source was refused. Check the source address, HTTP/HTTPS protocol and port, or try another network.',
    );
  }
  if (const {32, 54, 104, 10053, 10054}.contains(socketCode) ||
      message.contains('connection reset') ||
      message.contains('connection closed') ||
      message.contains('connection aborted') ||
      message.contains('connection lost') ||
      message.contains('broken pipe') ||
      message.contains('connection terminated') ||
      message.contains('connection timed out during data transfer')) {
    return tr(
      'The connection to the provider was interrupted. Check your internet connection and try again. If it keeps happening, contact your provider.',
    );
  }
  if (error is TimeoutException ||
      const {60, 110, 10060}.contains(socketCode) ||
      message.contains('timed out') ||
      message.contains('timeoutexception') ||
      message.contains('timeout') ||
      message.contains('deadline exceeded')) {
    return tr(
      'The provider did not respond in time. Check your internet connection and try again. Its server may be busy or unavailable.',
    );
  }
  if (error is HttpWorkloadException) {
    return tr('The source returned more data than the app can safely load.');
  }
  if (error is FormatException ||
      message.contains('non-json response') ||
      message.contains('unexpected response shape') ||
      message.contains('no working api endpoint')) {
    return tr(
      'The provider returned an invalid response. Check that the source address and type are correct. If they are correct, try again later or contact your provider.',
    );
  }
  if (message.contains('unauthorized') ||
      message.contains('forbidden') ||
      message.contains('invalid credential') ||
      message.contains('authentication')) {
    return tr(
      'The source rejected the saved credentials. Check the source details.',
    );
  }
  if (isTransientNetworkError(error)) {
    return tr(
      'The provider could not be reached. Check your internet connection and source address, then try again.',
    );
  }
  return null;
}

/// The user-facing half of [sourceLoadErrorMessage] for a provider that
/// answered with an HTTP status.
///
/// The status is printed deliberately: it is not a secret (the URL beside it is
/// already redacted), it is the single most useful thing a support report can
/// carry, and providers return codes outside the standard range — a real field
/// report arrived as `HTTP 884` — which no wording can anticipate. Anything
/// unrecognised is therefore attributed to the provider rather than to the
/// user's settings, because a response *came back*: the host resolved, the
/// connection succeeded, and the server chose to refuse.
String _httpStatusMessage(int status) {
  switch (status) {
    case 401:
    case 407:
      return tr(
        'The provider rejected these credentials (HTTP {status}). Check the source details.',
        {'status': status},
      );
    case 403:
      return tr(
        'The provider denied access (HTTP {status}). Check that your subscription is active and this device or network is allowed, or contact your provider.',
        {'status': status},
      );
    case 408:
    case 504:
      return tr(
        'The provider did not respond in time (HTTP {status}). Try again shortly; its server may be busy or unavailable.',
        {'status': status},
      );
    case 500:
    case 502:
    case 503:
      return tr(
        'The provider server is temporarily unavailable (HTTP {status}). Try again shortly. If the problem persists, contact your provider.',
        {'status': status},
      );
    case 404:
      return tr(
        'The provider could not find the requested data (HTTP {status}). Try again; if the error persists, check the source URL.',
        {'status': status},
      );
    case 410:
      return tr(
        'The provider has no such address (HTTP {status}). Check the URL in the source details.',
        {'status': status},
      );
    case 429:
      return tr(
        'The provider is rate-limiting this device (HTTP {status}). Wait a moment and try again.',
        {'status': status},
      );
    default:
      return tr(
        'The provider refused this request (HTTP {status}). That came from their server, not your settings — try again shortly.',
        {'status': status},
      );
  }
}

/// One non-resetting deadline spanning request creation, headers, redirects,
/// body transfer, and optional decoding.
class HttpOperation {
  HttpOperation(this.policy, {this.onReadMetrics})
    : _stopwatch = Stopwatch()..start();

  final HttpWorkloadPolicy policy;
  final Stopwatch _stopwatch;
  HttpReadMetrics? lastReadMetrics;
  final void Function(HttpReadMetrics metrics)? onReadMetrics;

  Duration get remaining {
    final value = policy.totalTimeout - _stopwatch.elapsed;
    if (value <= Duration.zero) {
      throw TimeoutException('${policy.name} exceeded total deadline');
    }
    return value;
  }

  Future<T> wait<T>(Future<T> future) => future.timeout(
    remaining,
    onTimeout: () => throw TimeoutException(
      '${policy.name} exceeded total deadline',
      policy.totalTimeout,
    ),
  );

  Future<Uint8List> readBytes(HttpClientResponse response) async {
    final encoded = await readBoundedBytes(
      response,
      contentLength: response.contentLength,
      maximumBytes: policy.maximumBodyBytes,
      idleTimeout: policy.idleTimeout,
      totalTimeout: remaining,
      workloadName: policy.name,
    );
    if (!_isGzip(response, encoded)) {
      _checkLimit(encoded.length, policy.maximumDecodedBytes, policy.name);
      lastReadMetrics = HttpReadMetrics(
        compressedBytes: encoded.length,
        decodedBytes: encoded.length,
      );
      onReadMetrics?.call(lastReadMetrics!);
      return encoded;
    }
    final decoded = await wait(
      Isolate.run(() => decodeGzipBounded(encoded, policy.maximumDecodedBytes)),
    );
    lastReadMetrics = HttpReadMetrics(
      compressedBytes: encoded.length,
      decodedBytes: decoded.length,
    );
    onReadMetrics?.call(lastReadMetrics!);
    return decoded;
  }

  /// Streams a response directly to [destination], bounding both a declared
  /// Content-Length and actual chunks. The partial file is deleted on every
  /// failure, including idle/total timeout and a consumer callback exception.
  Future<int> readToFile(
    HttpClientResponse response,
    File destination, {
    int? maximumBytes,
    void Function(List<int> chunk, int received)? onChunk,
  }) async {
    final ceiling = maximumBytes ?? policy.maximumBodyBytes;
    return writeBoundedStreamToFile(
      response,
      destination,
      contentLength: response.contentLength,
      maximumBytes: ceiling,
      idleTimeout: policy.idleTimeout,
      totalTimeout: remaining,
      workloadName: policy.name,
      onChunk: onChunk,
    );
  }
}

/// Provider GET with one admission per physical request, including redirects.
/// The callback consumes the final response while its concurrency permit is
/// held. Timeouts abort the actual request as well as completing its Future.
/// An optional admission gate changes throughput but retains shared cooldowns.
Future<T> providerHttpGet<T>(
  Uri uri, {
  required HttpClient client,
  required HttpOperation operation,
  Map<String, String> headers = const {},
  ProviderRequestGate? admissionGate,
  LoadToken? token,
  void Function()? checkCancellation,
  bool pauseOnAuthenticationFailure = true,
  void Function(Uri)? onResponseUri,
  required Future<T> Function(HttpClientResponse response) readResponse,
}) async {
  final gate = ProviderRequestGate.instance;
  final admission = admissionGate ?? gate;
  var target = uri;
  var forwardedHeaders = Map<String, String>.of(headers);
  for (var redirects = 0; ; redirects++) {
    void checkCancelled() {
      if (token?.isCancelled ?? false) throw const LoadCancelledException();
      checkCancellation?.call();
      gate.check(uri);
      gate.check(target);
      admission.check(uri);
    }

    checkCancelled();
    gate.check(uri);
    final current = target;
    final result = await admission.run<({Uri? redirect, T? value})>(
      current,
      () async {
        checkCancelled();
        // Evaluate the deadline before getUrl can start a new connection.
        await operation.wait(Future<void>.value());
        HttpClientRequest? request;
        var finished = false;
        Future<R> waitForRequest<R>(Future<R> pending) {
          final guarded = token == null
              ? pending
              : Future.any<R>([
                  pending,
                  token.whenCancelled.then<R>((_) {
                    request?.abort();
                    throw const LoadCancelledException();
                  }),
                ]);
          return operation.wait(guarded);
        }

        try {
          final openedRequest = await waitForRequest<HttpClientRequest>(
            client.getUrl(current).then((opened) {
              if (finished) opened.abort();
              return opened;
            }),
          );
          request = openedRequest;
          openedRequest.followRedirects = false;
          for (final entry in forwardedHeaders.entries) {
            openedRequest.headers.set(entry.key, entry.value);
          }
          final response = await waitForRequest(openedRequest.close());
          final retryAfter = response.headers.value(
            HttpHeaders.retryAfterHeader,
          );
          gate.recordResponse(
            current,
            response.statusCode,
            retryAfter: retryAfter,
            pauseOnAuthenticationFailure: pauseOnAuthenticationFailure,
          );
          // Also pause the configured origin, otherwise a redirecting source
          // would keep probing its first hop throughout the destination's ban.
          gate.recordResponse(
            uri,
            response.statusCode,
            retryAfter: retryAfter,
            pauseOnAuthenticationFailure: pauseOnAuthenticationFailure,
          );
          if (!identical(admission, gate)) {
            // Wake this queue too when a response pauses the shared host.
            for (final address in [current, uri]) {
              admission.recordResponse(
                address,
                response.statusCode,
                retryAfter: retryAfter,
                pauseOnAuthenticationFailure: pauseOnAuthenticationFailure,
              );
            }
          }
          try {
            gate.check(current);
            gate.check(uri);
            admission.check(current);
            admission.check(uri);
          } on ProviderRequestBlocked {
            try {
              await gate.flushCooldowns();
            } catch (_) {
              // Keep the in-memory refusal even when the device cannot persist it.
            }
            try {
              await response.take(0).drain<void>();
            } catch (_) {
              // Keep the refusal even if the rejected body is truncated.
            }
            rethrow;
          }
          if (response.isRedirect) {
            final location = response.headers.value(HttpHeaders.locationHeader);
            await waitForRequest(response.take(0).drain<void>());
            if (location == null || redirects >= 5) {
              throw StateError('Invalid or excessive provider redirects');
            }
            final next = current.resolve(location);
            if ((next.scheme != 'http' && next.scheme != 'https') ||
                next.host.isEmpty ||
                next.userInfo.isNotEmpty) {
              throw StateError('Invalid provider redirect');
            }
            return (redirect: next, value: null);
          }
          onResponseUri?.call(current);
          return (
            redirect: null,
            value: await waitForRequest(readResponse(response)),
          );
        } finally {
          finished = true;
          request?.abort();
        }
      },
      timeout: operation.remaining,
      cancellation: token?.whenCancelled,
      checkCancellation: checkCancelled,
    );
    if (result.redirect case final next?) {
      if (current.host.toLowerCase() != next.host.toLowerCase()) {
        forwardedHeaders = Map.of(forwardedHeaders)
          ..removeWhere(
            (name, _) =>
                name.toLowerCase() == HttpHeaders.authorizationHeader ||
                name.toLowerCase() == HttpHeaders.cookieHeader,
          );
      }
      target = next;
      continue;
    }
    return result.value as T;
  }
}

Future<Uint8List> readBoundedBytes(
  Stream<List<int>> stream, {
  required int contentLength,
  required int maximumBytes,
  required Duration idleTimeout,
  Duration? totalTimeout,
  required String workloadName,
}) async {
  _checkContentLength(contentLength, maximumBytes, workloadName);
  final builder = BytesBuilder(copy: false);
  var received = 0;
  await _consumeWithTimeouts(
    stream,
    idleTimeout: idleTimeout,
    totalTimeout: totalTimeout,
    workloadName: workloadName,
    onChunk: (chunk) {
      received += chunk.length;
      _checkLimit(received, maximumBytes, workloadName);
      builder.add(chunk);
    },
  );
  return builder.takeBytes();
}

Future<int> writeBoundedStreamToFile(
  Stream<List<int>> stream,
  File destination, {
  required int contentLength,
  required int maximumBytes,
  required Duration idleTimeout,
  Duration? totalTimeout,
  required String workloadName,
  void Function(List<int> chunk, int received)? onChunk,
}) async {
  _checkContentLength(contentLength, maximumBytes, workloadName);
  if (await destination.exists()) await destination.delete();
  final sink = destination.openWrite();
  var received = 0;
  try {
    await _consumeWithTimeouts(
      stream,
      idleTimeout: idleTimeout,
      totalTimeout: totalTimeout,
      workloadName: workloadName,
      onChunk: (chunk) {
        received += chunk.length;
        _checkLimit(received, maximumBytes, workloadName);
        sink.add(chunk);
        onChunk?.call(chunk, received);
      },
    );
    await sink.flush();
    await sink.close();
    return received;
  } catch (_) {
    await sink.close();
    if (await destination.exists()) await destination.delete();
    rethrow;
  }
}

Future<void> _consumeWithTimeouts(
  Stream<List<int>> stream, {
  required Duration idleTimeout,
  required Duration? totalTimeout,
  required String workloadName,
  required void Function(List<int>) onChunk,
}) {
  final completer = Completer<void>();
  StreamSubscription<List<int>>? subscription;
  Timer? idleTimer;
  Timer? totalTimer;
  var finished = false;

  Future<void> fail(Object error, [StackTrace? stackTrace]) async {
    if (finished) return;
    finished = true;
    idleTimer?.cancel();
    totalTimer?.cancel();
    await subscription?.cancel();
    if (!completer.isCompleted) {
      completer.completeError(error, stackTrace ?? StackTrace.current);
    }
  }

  void armIdleTimer() {
    idleTimer?.cancel();
    idleTimer = Timer(
      idleTimeout,
      () => fail(
        TimeoutException('$workloadName stalled while reading response'),
      ),
    );
  }

  if (totalTimeout != null) {
    totalTimer = Timer(
      totalTimeout,
      () => fail(TimeoutException('$workloadName exceeded total deadline')),
    );
  }
  armIdleTimer();
  subscription = stream.listen(
    (chunk) {
      if (finished) return;
      try {
        onChunk(chunk);
        armIdleTimer();
      } catch (error, stackTrace) {
        fail(error, stackTrace);
      }
    },
    onError: (Object error, StackTrace stackTrace) => fail(error, stackTrace),
    onDone: () {
      if (finished) return;
      finished = true;
      idleTimer?.cancel();
      totalTimer?.cancel();
      completer.complete();
    },
    cancelOnError: true,
  );
  return completer.future;
}

/// Byte counts as a human reads them.
///
/// These numbers reach the user — a rejected download surfaces its exception
/// text in the source error body and the exportable log — and "exceeds
/// 134217728 bytes" tells someone nothing about how far over they are or what
/// to do. `192 MB` against `128 MB` is immediately actionable.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final rounded = value >= 100 || value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(1);
  return '$rounded ${units[unit]}';
}

void _checkContentLength(int contentLength, int maximum, String name) {
  if (contentLength >= 0 && contentLength > maximum) {
    throw HttpWorkloadException(
      '$name download is ${formatBytes(contentLength)}, over the '
      '${formatBytes(maximum)} limit',
      isSizeLimit: true,
    );
  }
}

void _checkLimit(int actual, int maximum, String name) {
  if (actual > maximum) {
    throw HttpWorkloadException(
      '$name is ${formatBytes(actual)}, over the ${formatBytes(maximum)} limit',
      isSizeLimit: true,
    );
  }
}

bool _isGzip(HttpClientResponse response, Uint8List bytes) {
  final encoding = response.headers
      .value(HttpHeaders.contentEncodingHeader)
      ?.toLowerCase();
  return encoding?.split(',').any((value) => value.trim() == 'gzip') == true ||
      isGzipBytes(bytes);
}

bool isGzipBytes(List<int> bytes) =>
    bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;

/// Synchronous bounded gzip decoding. Call this inside an isolate for large or
/// attacker-controlled input; [HttpOperation.readBytes] already does so.
Uint8List decodeGzipBounded(Uint8List encoded, int maximumDecodedBytes) {
  final sink = _BoundedByteSink(maximumDecodedBytes, 'decoded gzip');
  final decoder = gzip.decoder.startChunkedConversion(sink);
  decoder.add(encoded);
  decoder.close();
  return sink.takeBytes();
}

class _BoundedByteSink implements Sink<List<int>> {
  _BoundedByteSink(this.maximumBytes, this.workloadName);

  final int maximumBytes;
  final String workloadName;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  var _length = 0;

  @override
  void add(List<int> data) {
    _length += data.length;
    _checkLimit(_length, maximumBytes, workloadName);
    _builder.add(data);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _builder.takeBytes();
}

/// Redacts secret-looking material from free-form [text] (an exception
/// message, an mpv log line) so it is safe to log or show on screen. Finds an
/// embedded http(s) URL and redacts its path segments that look like
/// credentials (long or token-shaped) — IPTV providers put username/password
/// in the *path* (`/live/user/pass/123.ts`), which [redactUrl]'s query-focused
/// redaction wouldn't touch.
String redactText(String text) {
  final urlMatch = RegExp(
    r'https?://\S+',
    caseSensitive: false,
  ).firstMatch(text);
  if (urlMatch != null) {
    final redactedUrl = _redactUrlPath(redactUrl(urlMatch.group(0)!));
    return text.replaceRange(urlMatch.start, urlMatch.end, redactedUrl);
  }
  return _redactUrlPath(text);
}

/// Path segments that introduce IPTV credential/route material. Xtream-style
/// stream URLs put the username and password in the two segments immediately
/// after one of these keywords (`/live/<user>/<pass>/<id>.ts`), and those creds
/// are frequently too short to trip the length/token heuristic below — so the
/// segments right after a keyword are redacted structurally, regardless of
/// length.
const _kCredentialPathKeywords = {
  'live',
  'movie',
  'movies',
  'series',
  'timeshift',
  'play',
};

String _redactUrlPath(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null) return value;
  if (!uri.hasAuthority && !value.contains('/')) return value;
  final segments = uri.pathSegments;
  // Structural redaction: after a credential keyword, redact the next two
  // segments (the user/pass pair) regardless of length, but never the final
  // segment — that's the stream id / filename, which carries no secret.
  final redactByStructure = List<bool>.filled(segments.length, false);
  for (var i = 0; i < segments.length; i++) {
    if (_kCredentialPathKeywords.contains(segments[i].toLowerCase())) {
      for (var j = i + 1; j <= i + 2 && j < segments.length - 1; j++) {
        redactByStructure[j] = true;
      }
    }
  }
  final cleanSegments = <String>[];
  for (var i = 0; i < segments.length; i++) {
    final segment = segments[i];
    final looksSecret =
        segment.length > 18 ||
        RegExp(r'^[A-Za-z0-9_-]{12,}$').hasMatch(segment);
    cleanSegments.add(
      (looksSecret || redactByStructure[i]) ? '<redacted>' : segment,
    );
  }
  final path = cleanSegments.join('/');
  final authority = uri.hasAuthority
      ? '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}'
      : '';
  final prefix = authority.isNotEmpty
      ? authority
      : (uri.scheme.isNotEmpty ? '${uri.scheme}:' : '');
  return '$prefix/${path.replaceAll(RegExp(r'/+'), '/')}';
}

/// Whether [value] is usable as a provider/guide URL: parseable, http(s), with
/// a non-empty host.
///
/// [requireScheme] decides how much this actually rejects, and the difference
/// is larger than it looks. Without it the check is deliberately **very**
/// lenient — prepending `http://` means `Uri` accepts almost any single token
/// as a host (`nonsense` parses; so does `not a url`, whose spaces are
/// percent-encoded into the authority). That is the correct trade for a
/// *host/portal* field, where scheme-less input is supported syntax and a false
/// rejection locks the owner out of saving an edit. It is the wrong trade for a
/// full URL the user is expected to paste — an EPG guide locator — where
/// there is no scheme-less convention to protect and accepting `nonsense`
/// merely defers the failure to the next guide refresh.
///
/// **Normalises exactly the way the sources do before judging.** Both
/// `XtreamSource._base` and `StalkerSource._base()` prepend `http://` when the
/// user omitted a scheme, so `panel.example.com:8080` and `1.2.3.4:8080` are
/// supported input, not mistakes. Validating the raw string rejected both:
/// `Uri.tryParse` reads `panel.example.com` as the *scheme* (dots are legal
/// there) and gives `1.2.3.4:8080` an empty host. That turned every
/// scheme-less source into one the owner could no longer save an edit to —
/// change the password, press Save, and the Host field they never touched
/// errors out while the source itself still plays fine.
bool looksLikeValidUrl(String value, {bool requireScheme = false}) {
  final hasScheme = value.startsWith('http://') || value.startsWith('https://');
  if (requireScheme && !hasScheme) return false;
  final normalised = hasScheme ? value : 'http://$value';
  final uri = Uri.tryParse(normalised);
  if (uri == null) return false;
  return (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;
}

/// Removes credentials from [url] so it is safe to surface in error messages,
/// logs, and exported diagnostics.
String redactUrl(Object url) {
  final text = url.toString();
  final uri = Uri.tryParse(text);
  if (uri == null || uri.scheme.isEmpty) {
    return text.split('?').first;
  }
  final out = StringBuffer()
    ..write(uri.scheme)
    ..write('://')
    ..write(uri.host);
  if (uri.hasPort) out.write(':${uri.port}');
  out.write(uri.path);
  if (uri.hasQuery) out.write('?<redacted>');
  return out.toString();
}
