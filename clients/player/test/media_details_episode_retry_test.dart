import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    'M3U upgrade keeps old seasons visible and refreshes the open sheet on retry',
    (tester) async {
      final repo = _BackfillRepository();
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
      await tester.pump();
      final loading = find.text('Loading episodes from the playlist…');
      expect(loading, findsOneWidget);
      expect(find.text('QA Season'), findsOneWidget);

      repo.status.value = M3uSeriesBackfillStatus.failed;
      await tester.pumpAndSettle();
      final retry = find.byKey(const ValueKey('media.m3u.backfill.retry'));
      expect(retry, findsOneWidget);
      expect(find.text('QA Season'), findsOneWidget);
      await tester.ensureVisible(retry);
      final retryFocus = tester.widget<OutlinedButton>(retry).focusNode!;
      retryFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(repo.retryCalls, 1);
      expect(retryFocus.hasFocus, isTrue);
      expect(loading, findsOneWidget);
      expect(find.text('QA Season'), findsOneWidget);

      repo.release.complete();
      await tester.pumpAndSettle();
      expect(loading, findsNothing);
      expect(retry, findsNothing);
      expect(find.text('Updated season'), findsOneWidget);
      final episodeHeader = find.byKey(const ValueKey('media.details.play'));
      expect(tester.widget<FilledButton>(episodeHeader).focusNode!.hasFocus, isTrue);
    },
  );

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

class _BackfillRepository extends _RecoveringRepository {
  final status = ValueNotifier(M3uSeriesBackfillStatus.loading);
  final release = Completer<void>();
  int retryCalls = 0;

  @override
  ValueNotifier<M3uSeriesBackfillStatus> get m3uSeriesBackfill => status;

  @override
  Future<bool> backfillM3uSeriesCache({bool retry = false}) async {
    if (!retry) return false;
    retryCalls++;
    status.value = M3uSeriesBackfillStatus.loading;
    await release.future;
    status.value = M3uSeriesBackfillStatus.complete;
    return true;
  }

  @override
  Future<MediaLibrarySnapshot> loadMedia(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    bool forceRefresh = false,
    bool enrichChildren = true,
  }) async {
    final snapshot = await super.loadMedia(
      kind,
      categoryId: categoryId,
      parent: parent,
      forceRefresh: forceRefresh,
      enrichChildren: enrichChildren,
    );
    return kind == ContentKind.season && release.isCompleted
        ? snapshot.copyWith(items: [season.copyWith(title: 'Updated season')])
        : snapshot;
  }
}
