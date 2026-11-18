import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

const series = MediaItem(
  id: 'qa-series',
  title: 'QA Series',
  kind: ContentKind.series,
);
const season = MediaItem(
  id: 'qa-season',
  parentId: 'qa-series',
  title: 'QA Season',
  kind: ContentKind.season,
);
const episode = MediaItem(
  id: 'qa-episode',
  parentId: 'qa-season',
  title: 'Recovered episode',
  kind: ContentKind.episode,
);

void main() {
  testWidgets(
    'reopening a failed season loads episodes after the provider recovers',
    (tester) async {
      final repo = _RecoveringRepository();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaDetailsSheet(
              repo: repo,
              item: series,
              favorite: false,
              onToggleFavorite: () {},
              onPlay: null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final header = find.text('QA Season');
      await tester.ensureVisible(header);
      await tester.tap(header);
      await tester.pumpAndSettle();
      final error = find.textContaining('Could not load episodes');
      expect(error, findsOneWidget);
      expect(repo.episodeRequests, 1);

      repo.online = true;
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(error, findsNothing);
      await tester.tap(header);
      await tester.pumpAndSettle();

      expect(find.text('Recovered episode'), findsOneWidget);
      expect(repo.episodeRequests, 2);

      await tester.tap(header);
      await tester.pumpAndSettle();
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(find.text('Recovered episode'), findsOneWidget);
      expect(repo.episodeRequests, 2);
    },
  );
}

class _NoPlaybackDatabase extends Fake implements AppDatabase {
  @override
  Stream<void> get playbackPositionsChanged => const Stream.empty();

  @override
  Stream<void> get playbackPositionsReplaced => const Stream.empty();
}

class _RecoveringRepository extends LibraryRepository {
  _RecoveringRepository()
    : super(source: DemoSource(), db: _NoPlaybackDatabase());

  bool online = false;
  int episodeRequests = 0;

  @override
  Future<MediaLibrarySnapshot> loadMedia(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    bool forceRefresh = false,
    bool enrichChildren = true,
  }) async {
    if (kind == ContentKind.episode) {
      episodeRequests++;
      if (!online) throw StateError('Synthetic temporary outage');
    }
    return MediaLibrarySnapshot(
      kind: kind,
      parentId: parent?.id,
      categories: const [],
      items: kind == ContentKind.season ? const [season] : const [episode],
      fromCache: false,
      syncedAt: null,
    );
  }
}
