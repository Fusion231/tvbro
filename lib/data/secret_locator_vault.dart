import 'dart:convert';
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Encrypts provider-owned playback locators before they enter the SQLite
/// cache. The key is generated once per installation and never leaves secure
/// storage; losing it intentionally makes the regenerable cache unreadable.
class SecretLocatorVault {
  SecretLocatorVault({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const keyName = 'cache_secret_locator_key_v1';
  static final _algorithm = AesGcm.with256bits();
  static SecretKey? _fallbackKey;

  final FlutterSecureStorage _storage;
  SecretKey? _key;
  bool generatedNewKey = false;

  /// How many blobs this vault has actually decrypted. Reading the cache must
  /// not decrypt anything (locators stay sealed until the `Source` boundary),
  /// so tests assert this stays at 0 across a bulk read and steps by exactly
  /// one per reveal. Counting, not timing — no wall-clock assertions.
  @visibleForTesting
  int decryptCount = 0;

  Future<SecretKey> _secretKey() async {
    final cached = _key;
    if (cached != null) return cached;
    String? encoded;
    try {
      encoded = await _storage.read(key: keyName);
    } catch (_) {
      // Host-side FFI tests have no secure-storage plugin. Keep those tests
      // deterministic without weakening the real platform path.
      return _key = _fallbackKey ??= await _algorithm.newSecretKey();
    }
    if (encoded == null || encoded.isEmpty) {
      generatedNewKey = true;
      final generated = await _algorithm.newSecretKey();
      encoded = base64UrlEncode(await generated.extractBytes());
      try {
        await _storage.write(key: keyName, value: encoded);
      } catch (_) {
        return _key = _fallbackKey ??= generated;
      }
    }
    final bytes = base64Url.decode(encoded);
    if (bytes.length != 32) throw const FormatException('Invalid cache key');
    // `newSecretKeyFromBytes` — NOT the `SecretKey(bytes)` constructor. Both
    // wrap the identical key material (so ciphertext and every previously
    // written blob are unaffected), but the algorithm-built key is the private
    // `_DartAesSecretKeyData` subtype that AES round-key expansion memoizes
    // against; a bare `SecretKey` re-expands the key schedule on every single
    // encrypt/decrypt. The `_fallbackKey` branches above already get this for
    // free (they go through `newSecretKey()`), which is why host tests never
    // saw the cost the real platform path was paying.
    return _key = await _algorithm.newSecretKeyFromBytes(bytes);
  }

  Future<void> ensureKey() => _secretKey().then((_) {});

  /// Encrypts and encodes bounded cache batches away from the UI isolate.
  /// Only sealed rows leave the worker; the key never enters the spool file.
  Stream<Uint8List> encodeCacheRows(
    Stream<List<Map<String, Object?>>> batches,
  ) async* {
    final key = await (await _secretKey()).extractBytes();
    final replies = ReceivePort();
    final exits = ReceivePort();
    final terminated = Completer<void>();
    final exitSubscription = exits.listen((_) {
      if (!terminated.isCompleted) terminated.complete();
      replies.sendPort.send(null);
    });
    final messages = StreamIterator<Object?>(replies);
    Isolate? worker;
    try {
      worker = await Isolate.spawn(
        _encodeCacheRows,
        (replies.sendPort, key),
        onError: replies.sendPort,
        onExit: exits.sendPort,
      );
      if (!await messages.moveNext() || messages.current is! SendPort) {
        throw StateError('Cache encoder could not start');
      }
      final requests = messages.current as SendPort;
      await for (final batch in batches) {
        requests.send(batch);
        if (!await messages.moveNext() ||
            messages.current is! TransferableTypedData) {
          throw StateError('Cache encoder failed');
        }
        yield (messages.current as TransferableTypedData)
            .materialize()
            .asUint8List();
      }
    } finally {
      worker?.kill(priority: Isolate.immediate);
      if (worker != null) await terminated.future;
      await messages.cancel();
      await exitSubscription.cancel();
      exits.close();
      replies.close();
    }
  }

  Future<String> encrypt(Map<String, String> locators) async {
    if (locators.isEmpty) return '';
    final box = await _algorithm.encrypt(
      utf8.encode(jsonEncode(locators)),
      secretKey: await _secretKey(),
    );
    return base64UrlEncode(box.concatenation());
  }

  Future<Map<String, String>> decrypt(String encoded) async {
    if (encoded.isEmpty) return const {};
    decryptCount++;
    final box = SecretBox.fromConcatenation(
      base64Url.decode(encoded),
      nonceLength: 12,
      macLength: 16,
    );
    final clear = await _algorithm.decrypt(box, secretKey: await _secretKey());
    final value = jsonDecode(utf8.decode(Uint8List.fromList(clear)));
    if (value is! Map) throw const FormatException('Invalid secret locator');
    return {
      for (final entry in value.entries)
        entry.key.toString(): entry.value.toString(),
    };
  }
}

Future<void> _encodeCacheRows((SendPort, List<int>) init) async {
  final (replies, key) = init;
  final vault = SecretLocatorVault()
    .._key = await SecretLocatorVault._algorithm.newSecretKeyFromBytes(key);
  final requests = ReceivePort();
  replies.send(requests.sendPort);
  await for (final message in requests) {
    final rows = message as List<Map<String, Object?>>;
    for (final row in rows) {
      final extra = await protectSecretLocators(
        row['extra'] as Map<String, dynamic>,
        vault,
      );
      row['extra'] = extra.isEmpty ? null : jsonEncode(extra);
    }
    replies.send(
      TransferableTypedData.fromList([utf8.encode('${jsonEncode(rows)}\n')]),
    );
  }
}

const secretLocatorKey = 'secretLocator';

const _secretLocatorFields = {
  'url',
  'cmd',
  'streamUrl',
  'stream_url',
  'movieUrl',
  'movie_url',
  'episodeUrl',
  'episode_url',
  'link',
  'streamUserAgent',
  'streamReferer',
};

/// Whether [extra] still carries the *sealed* locator blob — i.e. it came
/// straight out of the SQLite cache and has not been revealed yet.
///
/// Cached [Channel]/[MediaItem] models deliberately stay sealed: reading a
/// 250k-channel library must not run 250k AES-GCM opens. `LibraryRepository`
/// reveals one model at a time at the `Source` boundary (see CLAUDE.md
/// "Sealed playback locators"), and the `Source` implementations that consume
/// a locator field `assert` on this so a missed reveal point fails loudly in
/// debug instead of silently making that content unplayable.
bool hasSealedLocator(Map<String, dynamic> extra) {
  final value = extra[secretLocatorKey];
  return value is String && value.isNotEmpty;
}

Future<Map<String, dynamic>> protectSecretLocators(
  Map<String, dynamic> extra,
  SecretLocatorVault vault,
) async {
  final locators = <String, String>{};
  final regular = <String, dynamic>{};
  final existingEncrypted = extra[secretLocatorKey]?.toString();
  for (final entry in extra.entries) {
    if (_secretLocatorFields.contains(entry.key) && entry.value is String) {
      locators[entry.key] = entry.value as String;
    } else if (entry.key != secretLocatorKey) {
      regular[entry.key] = entry.value;
    }
  }
  final encrypted = await vault.encrypt(locators);
  if (encrypted.isNotEmpty) {
    regular[secretLocatorKey] = encrypted;
  } else if (existingEncrypted != null && existingEncrypted.isNotEmpty) {
    regular[secretLocatorKey] = existingEncrypted;
  }
  return regular;
}

Future<Map<String, dynamic>> restoreSecretLocators(
  Map<String, dynamic> extra,
  SecretLocatorVault vault,
) async {
  final encoded = extra[secretLocatorKey]?.toString();
  if (encoded == null || encoded.isEmpty) return extra;
  final restored = await vault.decrypt(encoded);
  final result = <String, dynamic>{...extra}..remove(secretLocatorKey);
  result.addAll(restored);
  return result;
}
