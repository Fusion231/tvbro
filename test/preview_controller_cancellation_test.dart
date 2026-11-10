import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/player/buffer_preset.dart';
import 'package:iptvs/screens/live_preview_controller.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

class _PendingPreviewRepository implements LibraryRepository {
  @override
  final Source source = DemoSource();

  final resolution = Completer<StreamInfo>();
  var resolveCalls = 0;

  @override
  Future<StreamInfo> resolve(Channel channel) {
    resolveCalls++;
    return resolution.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final discard in [false, true]) {
    test(
      '${discard ? 'discarding' : 'stopping'} a pending preview prevents a late open',
      () async {
        final repo = _PendingPreviewRepository();
        final errors = <String>[];
        final preview = LivePreviewController(repo: repo, onError: errors.add);
        addTearDown(preview.dispose);

        final opening = preview.start(
          const Channel(id: 'a', name: 'Channel A'),
          bufferPreset: BufferPreset.normal,
        );
        expect(repo.resolveCalls, 1);
        expect(preview.loading, isTrue);

        if (discard) {
          await preview.discardPlayer();
        } else {
          await preview.stop(clearSelection: true);
        }
        repo.resolution.complete(
          const StreamInfo(url: 'https://example.test/channel-a.m3u8'),
        );
        await opening;

        expect(preview.channelId, isNull);
        expect(preview.stream, isNull);
        expect(preview.loading, isFalse);
        expect(preview.error, isNull);
        expect(preview.nativeActive, isFalse);
        expect(preview.hasEmbeddedPlayer, isFalse);
        expect(errors, isEmpty);
      },
    );
  }
}
