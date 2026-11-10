import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'load_token.dart';

/// A provider refusal pauses all accounts, ports and source objects on its host.
/// No URL, credentials or response body may be included in this exception.
class ProviderRequestBlocked implements Exception {
  const ProviderRequestBlocked({required this.status, required this.retryAt});

  final int status;
  final DateTime retryAt;

  @override
  String toString() =>
      'HTTP $status: provider requests paused until ${retryAt.toIso8601String()}';
}

/// Process-wide admission for provider control traffic (catalogs, auth, EPG,
/// details and playback-link resolution). Media segments keep their own cadence
/// but check and record the same host cooldown.
class ProviderRequestGate {
  ProviderRequestGate({
    Duration minimumStartGap = const Duration(milliseconds: 250),
    this.maximumConcurrentRequests = 2,
    this.refusalCooldown = const Duration(minutes: 5),
    DateTime Function()? now,
    Future<void> Function(Duration)? wait,
  }) : _minimumStartGap = minimumStartGap,
       _now = now ?? DateTime.now,
       _wait = wait ?? Future<void>.delayed {
    if (minimumStartGap < Duration.zero ||
        maximumConcurrentRequests < 1 ||
        refusalCooldown <= Duration.zero) {
      throw ArgumentError('Invalid provider request limits');
    }
  }

  static final instance = ProviderRequestGate();

  Duration _minimumStartGap;
  final int maximumConcurrentRequests;
  final Duration refusalCooldown;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _wait;
  final Map<String, _ProviderHost> _hosts = {};
  File? _cooldownFile;
  Future<void> _persistence = Future<void>.value();

  String _key(Uri uri) => sha256
      .convert(
        utf8.encode(uri.host.toLowerCase().replaceFirst(RegExp(r'\.+$'), '')),
      )
      .toString();

  _ProviderHost _host(Uri uri) =>
      _hosts.putIfAbsent(_key(uri), _ProviderHost.new);

  /// Called before any provider traffic at startup. Only host hashes, status
  /// codes and deadlines are persisted; paths, accounts and URLs stay out.
  Future<void> restoreCooldowns(File file) async {
    _cooldownFile = file;
    final dynamic saved;
    try {
      if (!await file.exists()) return;
      saved = jsonDecode(await file.readAsString());
    } on FormatException {
      return;
    } on FileSystemException {
      // An unreadable cache must not prevent application startup.
      return;
    }
    if (saved is! Map) return;
    for (final entry in saved.entries) {
      if (entry.key is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.key as String)) {
        continue;
      }
      final value = entry.value;
      if (value is! Map || value['until'] is! int || value['status'] is! int) {
        continue;
      }
      final status = value['status'] as int;
      if (![401, 429, 503].contains(status)) continue;
      DateTime until;
      try {
        until = DateTime.fromMillisecondsSinceEpoch(
          value['until'] as int,
          isUtc: true,
        );
      } on ArgumentError {
        continue;
      }
      if (!until.isAfter(_now())) continue;
      final host = _hosts.putIfAbsent(entry.key as String, _ProviderHost.new);
      if (host.blockedUntil == null || until.isAfter(host.blockedUntil!)) {
        host.blockedUntil = until;
        host.status = status;
        host.signal();
      }
    }
  }

  /// Response handlers await this before surfacing a refusal, so an immediate
  /// application restart cannot bypass a server's longer Retry-After deadline.
  Future<void> flushCooldowns() => _persistence;

  void _saveCooldowns() {
    final file = _cooldownFile;
    if (file == null) return;
    final previous = _persistence;
    _persistence = (() async {
      // A subsequent refusal gets another chance after a temporary disk error.
      try {
        await previous;
      } catch (_) {}
      final now = _now();
      final saved = <String, Object>{
        for (final entry in _hosts.entries)
          if (entry.value.blockedUntil?.isAfter(now) ?? false)
            entry.key: {
              'until': entry.value.blockedUntil!.millisecondsSinceEpoch,
              'status': entry.value.status,
            },
      };
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(saved), flush: true);
      await temporary.rename(file.path);
    })();
    // Playback also records refusals from synchronous engine callbacks. Its
    // caller may not await persistence, but the failed write must stay observed.
    unawaited(_persistence.catchError((Object _) {}));
  }

  /// Throws immediately during a cooldown, including for manual refreshes and
  /// newly constructed sources. Waiting work never queues for the cooldown.
  void check(Uri uri) => _check(_host(uri));

  void _check(_ProviderHost host) {
    final until = host.blockedUntil;
    if (until != null && _now().isBefore(until)) {
      throw ProviderRequestBlocked(status: host.status!, retryAt: until);
    }
  }

  /// Call as soon as headers arrive, before reading or discarding a body.
  /// A successful concurrent response cannot clear another request's refusal.
  /// HTTP 403 is returned to the caller without pausing other host requests.
  /// Artwork opts out of auth pauses: one protected image says nothing about
  /// account access, while rate limits and Retry-After still pause the host.
  void recordResponse(
    Uri uri,
    int status, {
    String? retryAfter,
    bool pauseOnAuthenticationFailure = true,
  }) {
    final now = _now();
    final serverDeadline = _retryAfter(retryAfter, now);
    final authenticationFailure = status == HttpStatus.unauthorized;
    if (!(pauseOnAuthenticationFailure && authenticationFailure) &&
        status != HttpStatus.tooManyRequests &&
        !(status == HttpStatus.serviceUnavailable && serverDeadline != null)) {
      return;
    }
    final host = _host(uri);
    var until = now.add(refusalCooldown);
    if (serverDeadline != null && serverDeadline.isAfter(until)) {
      until = serverDeadline;
    }
    if (host.blockedUntil == null || until.isAfter(host.blockedUntil!)) {
      host.blockedUntil = until;
      host.status = status;
      _saveCooldowns();
    }
    host.signal();
  }

  static DateTime? _retryAfter(String? value, DateTime now) {
    if (value == null) return null;
    final text = value.trim();
    final seconds = int.tryParse(text);
    if (seconds != null) {
      if (seconds < 0) return null;
      try {
        return now.add(Duration(seconds: seconds));
      } on ArgumentError {
        return null;
      }
    }
    try {
      return HttpDate.parse(text);
    } on HttpException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// The callback owns a permit until its body has been consumed or cancelled.
  /// Admission is FIFO, separately from the two permitted in-flight requests,
  /// so a large guide cannot block every catalog or playback-link request.
  Future<T> run<T>(
    Uri uri,
    Future<T> Function() operation, {
    Duration? timeout,
    Future<void>? cancellation,
    void Function()? checkCancellation,
  }) async {
    final host = _host(uri);
    _check(host);
    final deadline = timeout == null ? null : _now().add(timeout);
    var cancelled = false;
    void checkAdmission() {
      checkCancellation?.call();
      if (cancelled) throw const LoadCancelledException();
      if (deadline != null && !deadline.isAfter(_now())) {
        throw TimeoutException(
          'Provider request exceeded total deadline',
          timeout,
        );
      }
      _check(host);
    }

    checkAdmission();
    final cancellationSignal = cancellation?.then<void>((_) {
      cancelled = true;
    });
    Future<void> waitForAdmission(Future<void> pending) {
      checkAdmission();
      final guarded = cancellationSignal == null
          ? pending
          : Future.any<void>([
              pending,
              cancellationSignal.then((_) {
                checkCancellation?.call();
                throw const LoadCancelledException();
              }),
            ]);
      return deadline == null
          ? guarded
          : guarded.timeout(
              deadline.difference(_now()),
              onTimeout: () => throw TimeoutException(
                'Provider request exceeded total deadline',
                timeout,
              ),
            );
    }

    final previous = host.admission;
    final admitted = Completer<void>();
    host.admission = admitted.future;
    var previousCompleted = false;
    try {
      await waitForAdmission(previous);
      previousCompleted = true;
      while (true) {
        checkAdmission();
        if (host.active >= maximumConcurrentRequests) {
          await waitForAdmission(host.changed.future);
          continue;
        }
        final next = host.nextStartAt;
        final delay = next?.difference(_now()) ?? Duration.zero;
        if (delay <= Duration.zero) break;
        await waitForAdmission(
          Future.any<void>([_wait(delay), host.changed.future]),
        );
      }
      checkAdmission();
      host.nextStartAt = _now().add(_minimumStartGap);
      host.active++;
    } finally {
      // Skipping a cancelled entry cannot let its successor overtake an older
      // entry that is still waiting for concurrency or the pacing deadline.
      if (previousCompleted) {
        admitted.complete();
      } else {
        unawaited(previous.then((_) => admitted.complete()));
      }
    }
    try {
      return await operation();
    } finally {
      host.active--;
      host.signal();
    }
  }

  /// Test isolation for loopback fixtures sharing a host but using fresh ports.
  void debugReset({Duration minimumStartGap = Duration.zero}) {
    _hosts.clear();
    _minimumStartGap = minimumStartGap;
    _cooldownFile = null;
    _persistence = Future<void>.value();
  }
}

class _ProviderHost {
  DateTime? nextStartAt;
  DateTime? blockedUntil;
  int? status;
  int active = 0;
  Future<void> admission = Future<void>.value();
  Completer<void> changed = Completer<void>();

  void signal() {
    final previous = changed;
    changed = Completer<void>();
    previous.complete();
  }
}
