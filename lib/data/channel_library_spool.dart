import 'dart:convert';
import 'dart:io';

import '../sources/source.dart';
import 'diagnostics_log.dart';
import 'secret_locator_vault.dart';

/// Stages encrypted channel rows before taking the shared database lock.
/// A worker and its file each process one bounded batch at a time.
class ChannelLibrarySpool {
  ChannelLibrarySpool._(this._directory, this._file, this._count);

  final Directory _directory;
  final File _file;
  final int _count;
  static const batchSize = 500;

  static Future<ChannelLibrarySpool> create(
    List<Channel> channels,
    SecretLocatorVault vault,
  ) async {
    final directory = await Directory.systemTemp.createTemp('tvbro_channels_');
    final file = File('${directory.path}${Platform.pathSeparator}sealed.rows');
    try {
      final output = await file.open(mode: FileMode.write);
      try {
        await for (final bytes in vault.encodeCacheRows(_rows(channels))) {
          await output.writeFrom(bytes);
        }
      } finally {
        await output.close();
      }
      return ChannelLibrarySpool._(directory, file, channels.length);
    } catch (_) {
      await _delete(directory);
      rethrow;
    }
  }

  static Stream<List<Map<String, Object?>>> _rows(
    List<Channel> channels,
  ) async* {
    for (var start = 0; start < channels.length; start += batchSize) {
      final end = (start + batchSize).clamp(0, channels.length);
      yield [
        for (var i = start; i < end; i++)
          {
            'id': channels[i].id,
            'name': channels[i].name,
            'number': channels[i].number,
            'logo': channels[i].logo,
            'category_id': channels[i].categoryId,
            'archive_days': channels[i].archiveDays,
            'extra': channels[i].extra,
          },
      ];
    }
  }

  Stream<List<Map<String, Object?>>> read() async* {
    var count = 0;
    await for (final line
        in _file
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      final rows = [
        for (final row in jsonDecode(line) as List)
          Map<String, Object?>.from(row as Map),
      ];
      count += rows.length;
      yield rows;
    }
    if (count != _count) throw StateError('Channel spool truncated');
  }

  Future<void> dispose() => _delete(_directory);

  static Future<void> _delete(Directory directory) async {
    try {
      await directory.delete(recursive: true);
    } catch (error) {
      DiagnosticsLog.instance.add(
        'library',
        'could not remove channel spool: ${error.runtimeType}',
      );
    }
  }
}
