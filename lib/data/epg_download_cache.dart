import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'diagnostics_log.dart';
import 'load_token.dart';
import 'net.dart';

/// A downloaded body becomes cacheable only after the XML parser accepts the
/// entire feed. A malformed 200 response must not displace a good validator.
class EpgDownloadReceipt {
  final Future<void> Function() commit;
  const EpgDownloadReceipt(this.commit);
}

/// A bounded, device-local HTTP body cache. Metadata contains only hashes,
/// validators and byte counts, never source URLs, credentials or headers.
class EpgDownloadCache {
  final Directory? directory;
  final int maximumBytes;
  final int maximumEntries;

  const EpgDownloadCache({
    this.directory,
    this.maximumBytes = 768 * 1024 * 1024,
    this.maximumEntries = 8,
  });

  Future<Directory> _directory() async {
    if (directory != null) return directory!.create(recursive: true);
    Directory base;
    try {
      base = await getTemporaryDirectory();
    } catch (_) {
      // Headless tests have no path-provider platform channel.
      base = Directory.systemTemp;
    }
    return Directory(p.join(base.path, 'iptvs_epg_http'))
        .create(recursive: true);
  }

  Future<EpgDownloadReceipt> fetch({
    required String sourceId,
    required Uri uri,
    required HttpClient client,
    required File destination,
    Map<String, String> headers = const {},
    LoadToken? token,
  }) async {
    final ordered = headers.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final key = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              sourceId,
              uri.toString(),
              for (final entry in ordered)
                [entry.key.toLowerCase(), entry.value],
            ]),
          ),
        )
        .toString();
    Directory? cacheDirectory;
    try {
      cacheDirectory = await _directory();
    } on FileSystemException {
      DiagnosticsLog.instance.add(
        'http:epg',
        'body cache unavailable; fetching directly',
      );
    }
    final dir = cacheDirectory;
    final metadata = dir == null ? null : File(p.join(dir.path, '$key.json'));
    final cached = dir == null ? null : await _readValid(dir, key);
    _checkCancellation(token);
    final operation = HttpOperation(kEpgWorkload);
    final request = await operation.wait(client.getUrl(uri));
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    if (cached != null) {
      if (cached.etag != null) {
        request.headers.set(HttpHeaders.ifNoneMatchHeader, cached.etag!);
      }
      if (cached.modified != null) {
        request.headers.set(
          HttpHeaders.ifModifiedSinceHeader,
          cached.modified!,
        );
      }
    }
    final response = await operation.wait(request.close());
    if (response.statusCode == HttpStatus.notModified && cached != null) {
      await operation.wait(response.drain<void>());
      _checkCancellation(token);
      await cached.file.copy(destination.path);
      DiagnosticsLog.instance.add(
        'http:epg',
        'not modified; reusing verified body',
      );
      return EpgDownloadReceipt(() async {
        await metadata!.setLastModified(DateTime.now());
      });
    }
    if (response.statusCode != HttpStatus.ok) {
      await operation.wait(response.drain<void>());
      throw StateError(
        'HTTP ${response.statusCode} fetching ${redactUrl(uri)}',
      );
    }
    final bytes = await operation.readToFile(
      response,
      destination,
      onChunk: (_, _) => _checkCancellation(token),
    );
    _checkCancellation(token);
    final etag = response.headers.value(HttpHeaders.etagHeader);
    final modified = response.headers.value(HttpHeaders.lastModifiedHeader);
    DiagnosticsLog.instance.add('http:epg', 'body_bytes=$bytes');
    return EpgDownloadReceipt(() async {
      _checkCancellation(token);
      if (dir == null) return;
      final record = metadata!;
      // Servers without validators cannot save a future transfer.
      if ((etag == null && modified == null) || bytes > maximumBytes) {
        if (await record.exists()) await record.delete();
        await _prune(dir, keep: key);
        return;
      }
      final digest = await _digest(destination.path);
      final bodyName = '$key-$digest.body';
      final body = File(p.join(dir.path, bodyName));
      final nextMetadata = File(p.join(dir.path, '$key.next'));
      try {
        if (cached == null ||
            cached.file.path != body.path ||
            !await body.exists()) {
          await destination.copy(body.path);
        }
        await nextMetadata.writeAsString(
          jsonEncode({
            'body': bodyName,
            'bytes': bytes,
            'sha256': digest,
            'etag': etag,
            'modified': modified,
          }),
          flush: true,
        );
        // Windows cannot rename over an existing file. The old body remains
        // valid until its metadata is replaced; an interrupted swap simply
        // causes the next request to fetch unconditionally.
        if (await record.exists()) await record.delete();
        await nextMetadata.rename(record.path);
        await _prune(dir, keep: key);
      } catch (_) {
        // Cache persistence is optional after a successful guide parse.
        if (await nextMetadata.exists()) await nextMetadata.delete();
      }
    });
  }

  Future<_CachedGuide?> _readValid(Directory dir, String key) async {
    final metadata = File(p.join(dir.path, '$key.json'));
    try {
      final decoded = jsonDecode(await metadata.readAsString()) as Map;
      final name = decoded['body'] as String;
      final digest = decoded['sha256'] as String;
      if (!RegExp('^$key-[a-f0-9]{64}\\.body\$').hasMatch(name)) return null;
      final file = File(p.join(dir.path, name));
      if (await file.length() != decoded['bytes'] ||
          await _digest(file.path) != digest) {
        return null;
      }
      return _CachedGuide(
        file,
        decoded['etag'] as String?,
        decoded['modified'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _prune(Directory dir, {required String keep}) async {
    final metadata = await dir
        .list()
        .where((item) => item.path.endsWith('.json'))
        .toList();
    final entries = <({File file, DateTime used})>[];
    for (final item in metadata.whereType<File>()) {
      entries.add((file: item, used: (await item.stat()).modified));
    }
    entries.sort((a, b) => b.used.compareTo(a.used));
    final retained = <String>{};
    var bytes = 0;
    var count = 0;
    // Put the newly validated body first, even if filesystem time resolution
    // makes several entries appear equally recent.
    entries.sort((a, b) {
      if (p.basenameWithoutExtension(a.file.path) == keep) return -1;
      if (p.basenameWithoutExtension(b.file.path) == keep) return 1;
      return b.used.compareTo(a.used);
    });
    for (final entry in entries) {
      try {
        final data = jsonDecode(await entry.file.readAsString()) as Map;
        final size = data['bytes'] as int;
        final body = data['body'] as String;
        if (count >= maximumEntries || bytes + size > maximumBytes) {
          await entry.file.delete();
          continue;
        }
        retained.add(body);
        bytes += size;
        count++;
      } catch (_) {
        if (await entry.file.exists()) await entry.file.delete();
      }
    }
    await for (final item in dir.list()) {
      if (item is File &&
          item.path.endsWith('.body') &&
          !retained.contains(p.basename(item.path))) {
        await item.delete();
      }
    }
  }
}

class _CachedGuide {
  final File file;
  final String? etag;
  final String? modified;
  const _CachedGuide(this.file, this.etag, this.modified);
}

void _checkCancellation(LoadToken? token) {
  if (token?.isCancelled ?? false) throw const LoadCancelledException();
}

Future<String> _digest(String path) => Isolate.run(
  () async => (await sha256.bind(File(path).openRead()).first).toString(),
);
