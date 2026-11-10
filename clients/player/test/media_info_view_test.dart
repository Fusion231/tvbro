import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/load_token.dart';
import 'package:iptvs/data/metadata_provider.dart';
import 'package:iptvs/l10n/app_localizations.dart';
import 'package:iptvs/screens/media_tab_view.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/theme.dart';
import 'package:iptvs/widgets/routed_focus_node.dart';

class _InfoRepository implements LibraryRepository {
  _InfoRepository({
    this.metadataProviders = const [],
    this.readMetadata,
    this.refreshMetadata,
  });

  @override
  final List<MetadataProvider> metadataProviders;
  final Future<ExternalMetadata?> Function(String provider)? readMetadata;
  final Future<ExternalMetadata?> Function()? refreshMetadata;
  final cacheReads = <String>[];

  @override
  LoadToken? loadToken;

  @override
  Future<ExternalMetadata?> cachedExternalMetadata(
    MediaItem item,
    String provider,
  ) async {
    cacheReads.add(provider);
    return readMetadata?.call(provider);
  }

  @override
  Future<ExternalMetadata?> refreshExternalMetadata(MediaItem item) async =>
      refreshMetadata?.call();

  @override
  MediaItem mergeExternalMetadata(MediaItem item, ExternalMetadata metadata) =>
      item.copyWith(description: metadata.overview);

  @override
  Future<MediaLibrarySnapshot> loadMedia(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    bool forceRefresh = false,
    bool enrichChildren = true,
  }) async => MediaLibrarySnapshot(
    kind: kind,
    categories: const [],
    items: kind == ContentKind.season
        ? const [
            MediaItem(
              id: 'season-1',
              title: 'Season 1',
              kind: ContentKind.season,
              seasonNumber: 1,
            ),
          ]
        : const [],
    fromCache: true,
    syncedAt: null,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _InfoMetadataProvider implements MetadataProvider {
  const _InfoMetadataProvider(this.provider, {this.ratingsOnly = false});

  @override
  final String provider;

  @override
  final bool ratingsOnly;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _providerMovie = MediaItem(
  id: 'provider-movie',
  title: 'Provider movie',
  kind: ContentKind.movie,
  description: 'A provider synopsis.',
  durationSeconds: 5400,
  extra: {
    'details': {
      'info': {
        'cast': 'Anna Kowalska, Jan Nowak',
        'director': 'Alicja Reżyser',
        'genre': 'Drama, Adventure',
        'country': 'Poland',
        'original_title': 'Original movie',
        'releasedate': '2024-06-12',
      },
    },
  },
);

void main() {
  setUp(() {
    AppLanguageController.instance.preview(AppLanguage.english);
  });

  tearDown(() {
    AppLanguageController.instance.preview(AppLanguage.english);
  });

  Future<void> openDetails(
    WidgetTester tester,
    MediaItem item, {
    Size size = const Size(960, 540),
    double textScale = 1,
    _InfoRepository? repo,
    bool settle = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => MediaDetailsSheet(
                  repo: repo ?? _InfoRepository(),
                  item: item,
                  favorite: false,
                  onToggleFavorite: () {},
                  onPlay: item.kind == ContentKind.movie ? () {} : null,
                  onPlayEpisode: (_) {},
                ),
              ),
              child: const Text('Open details'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open details'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  FocusNode informationFocus(WidgetTester tester, String routeKey) {
    final entry = find.byKey(ValueKey(routeKey));
    return tester
        .widget<Focus>(
          find.descendant(of: entry, matching: find.byType(Focus)).first,
        )
        .focusNode!;
  }

  testWidgets('provider movie shows cast and meaningful extra information', (
    tester,
  ) async {
    await openDetails(tester, _providerMovie);
    final information = find.byKey(const ValueKey('media.details.information'));
    for (final text in [
      'Original title',
      'Original movie',
      'Genres',
      'Drama, Adventure',
      'Director',
      'Alicja Reżyser',
      'Country',
      'Poland',
      'Release date',
      '2024-06-12',
      'Duration',
      '1 hr 30 min',
      'Cast',
      'Anna Kowalska',
      'Jan Nowak',
    ]) {
      expect(
        find.descendant(of: information, matching: find.text(text)),
        findsOneWidget,
      );
    }
    expect(find.text('Creators'), findsNothing);
    final play = tester.widget<FilledButton>(
      find.byKey(const ValueKey('media.details.play')),
    );
    expect(FocusManager.instance.primaryFocus, same(play.focusNode));
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote can reach a synopsis without any other metadata', (
    tester,
  ) async {
    await openDetails(
      tester,
      const MediaItem(
        id: 'synopsis-only',
        title: 'Movie with a long title that wraps onto multiple lines on TV',
        kind: ContentKind.movie,
        description: 'A synopsis that must be reachable using only the remote.',
      ),
      size: const Size(960, 540),
      textScale: 1.6,
    );
    final close = find.byKey(const ValueKey('media.details.close'));
    final closePosition = tester.getTopLeft(close);
    final favorite = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('media.details.favorite')),
    );
    favorite.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    expect(
      focusRouteKey(FocusManager.instance.primaryFocus),
      'media.details.synopsis',
    );
    final rect = tester.getRect(
      find.text('A synopsis that must be reachable using only the remote.'),
    );
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(540));
    expect(tester.getTopLeft(close), closePosition);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TMDB series cast roles wrap with large Polish text', (
    tester,
  ) async {
    AppLanguageController.instance.preview(AppLanguage.polish);
    await openDetails(
      tester,
      const MediaItem(
        id: 'tmdb-series',
        title: 'Przygody serialowe',
        kind: ContentKind.series,
        extra: {
          'metadata': {
            'tmdb': {
              'original_name': 'Original series',
              'created_by': [
                {'name': 'Maria Twórczyni'},
              ],
              'genres': [
                {'name': 'Dramat'},
              ],
              'production_countries': [
                {'name': 'Polska'},
              ],
              'first_air_date': '2025-01-17',
              'credits': {
                'cast': [
                  {
                    'name': 'Aleksandra o bardzo długim nazwisku',
                    'character': 'Bohaterka opowieści z długą nazwą roli',
                  },
                  {'name': 'Michał Aktor', 'character': 'Przyjaciel'},
                ],
              },
            },
          },
        },
      ),
      size: const Size(390, 844),
      textScale: 1.6,
    );
    for (final text in [
      'Obsada',
      'Tytuł oryginalny',
      'Twórcy',
      'Maria Twórczyni',
      'Aleksandra o bardzo długim nazwisku',
      'Bohaterka opowieści z długą nazwą roli',
      'Michał Aktor',
      'Przyjaciel',
    ]) {
      expect(find.text(text), findsOneWidget);
    }
    expect(find.text('Reżyseria'), findsNothing);
    final close = find.byKey(const ValueKey('media.details.close'));
    final closePosition = tester.getTopLeft(close);
    final actor = find.byKey(const ValueKey('media.details.cast.1'));
    await tester.ensureVisible(actor);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(close), closePosition);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cast shows TMDB photos and a fallback for missing photos', (
    tester,
  ) async {
    await openDetails(
      tester,
      _providerMovie.copyWith(
        extra: {
          'metadata': {
            'tmdb': {
              'credits': {
                'cast': [
                  {
                    'name': 'Anna Kowalska',
                    'character': 'Lead',
                    'profile_path': '/anna.jpg',
                  },
                  {'name': 'Jan Nowak', 'character': 'Friend'},
                ],
              },
            },
          },
        },
      ),
    );
    final photo = find.descendant(
      of: find.byKey(const ValueKey('media.details.cast.0')),
      matching: find.byType(CachedNetworkImage),
    );
    expect(photo, findsOneWidget);
    expect(
      tester.widget<CachedNetworkImage>(photo).imageUrl,
      'https://image.tmdb.org/t/p/w185/anna.jpg',
    );
    expect(tester.getSize(photo), const Size(48, 64));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('media.details.cast.1')),
        matching: find.byIcon(Icons.person_outline_rounded),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing information adds no empty section or labels', (
    tester,
  ) async {
    await openDetails(
      tester,
      const MediaItem(
        id: 'minimal',
        title: 'Minimal movie',
        kind: ContentKind.movie,
      ),
    );
    expect(
      find.byKey(const ValueKey('media.details.information')),
      findsNothing,
    );
    for (final label in ['Cast', 'Genres', 'Director', 'Duration']) {
      expect(find.text(label), findsNothing);
    }
    expect(
      find.text(
        'Showing IPTV provider details. Add TMDB or TVDB in Settings → Metadata for more information.',
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Refresh metadata'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ratings-only metadata does not offer an inactive refresh', (
    tester,
  ) async {
    final repo = _InfoRepository(
      metadataProviders: const [
        _InfoMetadataProvider('mdblist', ratingsOnly: true),
      ],
    );
    await openDetails(tester, _providerMovie, repo: repo);
    expect(
      find.text(
        'Showing IPTV provider details. Add TMDB or TVDB in Settings → Metadata for more information.',
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Refresh metadata'), findsNothing);
    expect(repo.cacheReads, isEmpty);
  });

  testWidgets('the free series provider does not offer movie refresh', (
    tester,
  ) async {
    await openDetails(
      tester,
      _providerMovie,
      repo: _InfoRepository(
        metadataProviders: const [_InfoMetadataProvider('tvmaze')],
      ),
    );
    expect(find.byTooltip('Refresh metadata'), findsNothing);
    expect(
      find.text(
        'Showing IPTV provider details. Add TMDB or TVDB in Settings → Metadata for more information.',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'TVmaze series show source and license links without credentials',
    (tester) async {
      final metadata = ExternalMetadata(
        provider: 'tvmaze',
        providerKey: '42',
        refreshedAt: DateTime.now(),
      );
      await openDetails(
        tester,
        const MediaItem(
          id: 'free-series',
          title: 'Free series',
          kind: ContentKind.series,
          description: 'Free series synopsis.',
          extra: {
            'metadata': {
              'tvmaze': {'id': 42},
            },
          },
        ),
        repo: _InfoRepository(
          metadataProviders: const [_InfoMetadataProvider('tvmaze')],
          readMetadata: (_) async => metadata,
        ),
      );
      expect(find.text('TVMAZE · just now'), findsOneWidget);
      expect(
        find.widgetWithText(TextButton, 'TVmaze metadata (formatting adapted)'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, 'CC BY-SA 4.0'), findsOneWidget);
      expect(find.byTooltip('Refresh metadata'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('TVDB movie details identify their metadata source', (
    tester,
  ) async {
    await openDetails(
      tester,
      _providerMovie.copyWith(
        extra: {
          'metadata': {
            'tvdb': {'id': 42},
          },
        },
      ),
    );
    expect(
      find.widgetWithText(TextButton, 'Metadata provided by TheTVDB'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final withFallback in [false, true]) {
    testWidgets(
      'shows TVDB metadata ${withFallback ? 'after a TMDB cache miss' : 'without TMDB configured'}',
      (tester) async {
        final repo = _InfoRepository(
          metadataProviders: [
            if (withFallback) const _InfoMetadataProvider('tmdb'),
            const _InfoMetadataProvider('tvdb'),
          ],
          readMetadata: (provider) async => provider == 'tvdb'
              ? ExternalMetadata(
                  provider: 'tvdb',
                  providerKey: '42',
                  refreshedAt: DateTime.now(),
                )
              : null,
        );
        await openDetails(tester, _providerMovie, repo: repo);
        expect(find.text('TVDB · just now'), findsOneWidget);
        expect(repo.cacheReads, [if (withFallback) 'tmdb', 'tvdb']);
        expect(find.byTooltip('Refresh metadata'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('pending metadata read shows loading and disables refresh', (
    tester,
  ) async {
    final pending = Completer<ExternalMetadata?>();
    final repo = _InfoRepository(
      metadataProviders: const [_InfoMetadataProvider('tmdb')],
      readMetadata: (_) => pending.future,
    );
    await openDetails(tester, _providerMovie, repo: repo, settle: false);
    expect(find.text('Loading metadata…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh))
          .onPressed,
      isNull,
    );
    pending.complete(null);
    await tester.pumpAndSettle();
    expect(
      find.text('No additional metadata. Showing IPTV provider details.'),
      findsOneWidget,
    );
  });

  testWidgets('metadata read failure keeps provider details and offers retry', (
    tester,
  ) async {
    final repo = _InfoRepository(
      metadataProviders: const [_InfoMetadataProvider('tmdb')],
      readMetadata: (_) async => throw StateError('cache unavailable'),
    );
    await openDetails(tester, _providerMovie, repo: repo);
    expect(
      find.text(
        'Could not load additional metadata. Showing IPTV provider details.',
      ),
      findsOneWidget,
    );
    expect(find.text('A provider synopsis.'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh shows progress and reports no matching metadata', (
    tester,
  ) async {
    final pending = Completer<ExternalMetadata?>();
    final repo = _InfoRepository(
      metadataProviders: const [_InfoMetadataProvider('tmdb')],
      refreshMetadata: () => pending.future,
    );
    await openDetails(tester, _providerMovie, repo: repo);
    final refresh = find.widgetWithIcon(IconButton, Icons.refresh);
    await tester.ensureVisible(refresh);
    await tester.pumpAndSettle();
    await tester.tap(refresh);
    await tester.pump();
    expect(find.text('Loading metadata…'), findsOneWidget);
    expect(tester.widget<IconButton>(refresh).onPressed, isNull);
    pending.complete(null);
    await tester.pumpAndSettle();
    expect(find.text('No matching metadata found.'), findsOneWidget);
    expect(tester.widget<IconButton>(refresh).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed refresh reports the error and keeps provider details', (
    tester,
  ) async {
    final repo = _InfoRepository(
      metadataProviders: const [_InfoMetadataProvider('tmdb')],
      refreshMetadata: () async => throw StateError('offline'),
    );
    await openDetails(tester, _providerMovie, repo: repo);
    final refresh = find.widgetWithIcon(IconButton, Icons.refresh);
    await tester.ensureVisible(refresh);
    await tester.pumpAndSettle();
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    expect(
      find.text('Metadata refresh failed: Bad state: offline'),
      findsOneWidget,
    );
    expect(find.text('A provider synopsis.'), findsOneWidget);
    expect(tester.widget<IconButton>(refresh).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('successful fallback refresh remains visible after reopening', (
    tester,
  ) async {
    final oldTmdb = ExternalMetadata(
      provider: 'tmdb',
      providerKey: '11',
      refreshedAt: DateTime(2020),
    );
    final newTvdb = ExternalMetadata(
      provider: 'tvdb',
      providerKey: '42',
      overview: 'New TVDB synopsis.',
      refreshedAt: DateTime.now(),
    );
    var refreshed = false;
    final repo = _InfoRepository(
      metadataProviders: const [
        _InfoMetadataProvider('tmdb'),
        _InfoMetadataProvider('tvdb'),
      ],
      readMetadata: (provider) async => provider == 'tmdb'
          ? oldTmdb
          : refreshed
          ? newTvdb
          : null,
      refreshMetadata: () async {
        refreshed = true;
        return newTvdb;
      },
    );
    await openDetails(tester, _providerMovie, repo: repo);
    expect(find.textContaining('TMDB ·'), findsOneWidget);
    final refresh = find.widgetWithIcon(IconButton, Icons.refresh);
    await tester.ensureVisible(refresh);
    await tester.pumpAndSettle();
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    expect(find.text('TVDB · just now'), findsOneWidget);
    expect(find.textContaining('TMDB ·'), findsNothing);
    expect(find.text('New TVDB synopsis.'), findsOneWidget);
    expect(repo.cacheReads, ['tmdb', 'tvdb']);
    await tester.tap(find.byTooltip('Close details'));
    await tester.pumpAndSettle();
    await openDetails(tester, _providerMovie, repo: repo);
    expect(find.text('TVDB · just now'), findsOneWidget);
    expect(find.textContaining('TMDB ·'), findsNothing);
    expect(repo.cacheReads, ['tmdb', 'tvdb', 'tmdb', 'tvdb']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote reading reveals rows and every actor with fixed Close', (
    tester,
  ) async {
    await openDetails(
      tester,
      _providerMovie.copyWith(
        extra: {
          'cast': [for (var i = 0; i < 35; i++) 'Actor $i'],
          'original_title': 'Original movie',
          'genres': ['Drama'],
        },
      ),
    );
    final close = find.byKey(const ValueKey('media.details.close'));
    final closePosition = tester.getTopLeft(close);
    informationFocus(tester, 'media.details.info.originalTitle').requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      focusRouteKey(FocusManager.instance.primaryFocus),
      'media.details.info.genres',
    );
    final lastActor = informationFocus(tester, 'media.details.cast.34');
    lastActor.requestFocus();
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, same(lastActor));
    final rect = tester.getRect(find.text('Actor 34'));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(540));
    expect(tester.getTopLeft(close), closePosition);
    expect(find.text('Actor 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
